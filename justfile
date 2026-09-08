# illogical — task runner. Everything assumes you are inside `nix develop`
# (or have direnv active).

# xcodebuild and swiftpm read environment variables as build-setting overrides,
# so the devshell's stdenv hands them a toolchain they must not use: LD=ld
# replaces Xcode's clang driver with the raw linker, and SDKROOT points Xcode's
# Swift 6 compiler at nix's macOS 14.4 SDK. zig still needs all of it, so strip
# them per-recipe instead of dropping them from the devshell.
xcenv := "env -u LD -u CC -u CXX -u AR -u NM -u RANLIB -u STRIP -u SDKROOT -u DEVELOPER_DIR -u MACOSX_DEPLOYMENT_TARGET -u LD_DYLD_PATH"

# The vendor/ghostty revision the binaries are built against, stamped into
# `--version` and into the `server` field of every `welcome` frame. It is what
# decides whether two builds agree about a snapshot -- format v1 promises
# nothing across pins -- so the Mac client can only notice a mismatched daemon
# if the pin is in the string. `unknown` on a tree whose submodule is not
# checked out, where the compile is about to fail for a better reason anyway.
ghostty_pin := `git -C vendor/ghostty rev-parse --short=12 HEAD 2>/dev/null || echo unknown`

# What a build calls itself. The same rule scripts/dist-daemon.sh uses, so the
# app's CFBundleShortVersionString and the daemon's `--version` agree: a tag
# when there is one, the short sha when there is not. The leading `v` is
# stripped because a `v` in the middle of a version string is a thing every
# tool that parses one has to be told about.
#
# The fallback is inside the parentheses on purpose: with `git ... | sed || echo`
# the `||` binds to sed, which succeeds on empty input, so a tree with no git
# produced an empty version rather than the default.
repo_version := `(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev) | sed 's/^v//'`

# CFBundleVersion: commits on this branch. Monotonic across every release,
# which is the one property Sparkle needs to decide that an update is newer
# (#47). A sha is not orderable and a date is not either once two land in a
# minute.
build_number := `git rev-list --count HEAD 2>/dev/null || echo 0`

default:
    @just --list

# --- server -----------------------------------------------------------------

# Build illogicald + illogical.
build:
    zig build -Dghostty-pin={{ghostty_pin}}

# Build with optimizations.
build-release:
    zig build -Doptimize=ReleaseFast -Dghostty-pin={{ghostty_pin}}

# Run the whole Zig test suite.
test:
    zig build test

# The G1 proof, at the level the unit tests cannot reach: a daemon started by
# `--ensure` survives its starter's whole process group being SIGKILLed.
smoke-ensure: build
    ./scripts/smoke-ensure.sh

# --- releasing the server ---------------------------------------------------

# Build one release tarball into dist/. See scripts/dist-daemon.sh for why musl
# and why the Linux legs are built natively in CI rather than crossed.
#
#   just dist-daemon                     this machine
#   just dist-daemon universal           both macOS arches, lipo'd
#   just dist-daemon x86_64-linux-musl   a Linux box
dist-daemon target="native" version="":
    ./scripts/dist-daemon.sh {{target}} {{version}}

# Every target the release ships, from a Mac. Cross-compiling to Linux works at
# the current ghostty pin and fails loudly if a pin bump breaks it; CI builds
# those two natively, which is also where they get smoke-run.
dist version="": (dist-daemon "universal" version) (dist-daemon "x86_64-linux-musl" version) (dist-daemon "aarch64-linux-musl" version)

# --- releasing the app ------------------------------------------------------

# Sign, notarize and package Illogical.app into dist/Illogical.dmg.
#
# Signing and notarization happen only when the Developer ID secrets are in the
# environment; without them this still produces a DMG, ad-hoc signed, which
# Gatekeeper will refuse on any machine that did not build it. See
# scripts/dist-app.sh for the variables and for what each step buys.
#
# Through `xcenv` for the same reason xcodebuild is: the script drives codesign
# and `xcrun notarytool`, and the devshell's DEVELOPER_DIR and SDKROOT point
# xcrun at nix's SDK rather than at Xcode's.
dist-app version=repo_version: (app-release version)
    {{xcenv}} ./scripts/dist-app.sh {{version}}

clean-dist:
    rm -rf dist

# Run illogicald in the foreground.
serve *ARGS:
    zig build run -- --foreground {{ARGS}}

fmt:
    zig fmt build.zig src
    alejandra --quiet .
    just fmt-swift

fmt-check:
    zig fmt --check build.zig src
    alejandra --check .
    swift-format lint --strict --recursive clients/macos/Illogical clients/macos/Tests clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

# Measure memory per terminal, live vs parked. Reads phys_footprint, not RSS —
# with RSS the parking win is invisible on macOS.
bench-memory count="20" lines="10000": build
    ./scripts/bench-memory.sh {{count}} {{lines}}

# What the two PTY IO regimes cost: throughput hot vs polled, and thread count
# against terminal count, which must flatten rather than track.
bench-pty lines="100000" count="32" repeats="3": build
    ./scripts/bench-pty.sh {{lines}} {{count}} {{repeats}}

# --- macOS client -----------------------------------------------------------

# Build ghostty-vt.xcframework from vendor/ghostty and stage it for the client.
# Pass `universal` for a shippable multi-arch build.
xcframework MODE="native":
    ./scripts/build-xcframework.sh {{MODE}}

# Regenerate Illogical.xcodeproj from project.yml.
#
# Depends on `stage-daemon` because project.yml names the staged directory as a
# source, and xcodegen refuses to generate against a path that is not there.
# Cheap after the first time: `zig build` is a no-op and the copy is two files.
xcodeproj: stage-daemon
    cd clients/macos && xcodegen generate

# Put illogicald and illogical where Xcode will copy them into the bundle.
#
# A prebuilt artifact, staged here and copied by a build phase, rather than a
# phase that shells out to zig. Three reasons, all concrete:
# ENABLE_USER_SCRIPT_SANDBOXING (project.yml) gives a script phase only its
# declared inputs and no network, while zig wants .zig-cache and may fetch; zig
# is not on Xcode's PATH outside the devshell; and the devshell variables zig
# needs -- SDKROOT, LD, CC -- are exactly the ones xcodebuild must not see,
# which is what `xcenv` above exists to strip. A build phase would have to undo
# that per phase.
#
# `just xcframework` sets the precedent: built by zig, staged into the client
# tree, gitignored, consumed by Xcode.
#
# The daemon only, and not the `illogical` CLI beside it. `Contents/MacOS/`
# already holds the app's own executable, `Illogical`, and the default macOS
# volume is case-insensitive -- so copying a file named `illogical` in there
# *overwrites the app*. Measured, not guessed: same inode, and the bundle then
# failed `codesign --verify --deep` with "invalid Info.plist". The CLI ships in
# the standalone tarball instead.
#
# ILLOGICAL_DAEMON_BIN names a prebuilt illogicald to stage instead of building
# one, and is what the release sets. Without it the app would carry a second
# build of the same source -- `zig build` is Debug and host-arch, while the
# tarball is ReleaseFast, stripped and lipo'd -- so an Intel Mac got a bundle
# whose daemon could not run, and every release app reported version skew
# against its own tarball. One build, both places -- not byte-identical, because
# Xcode re-signs it on the way into the bundle, but the same compile.
stage-daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p clients/macos/Illogical/Supporting/bin
    if [ -n "${ILLOGICAL_DAEMON_BIN:-}" ]; then
        echo "==> staging prebuilt $ILLOGICAL_DAEMON_BIN"
        cp "$ILLOGICAL_DAEMON_BIN" clients/macos/Illogical/Supporting/bin/illogicald
    else
        zig build -Dghostty-pin={{ghostty_pin}}
        cp zig-out/bin/illogicald clients/macos/Illogical/Supporting/bin/illogicald
    fi
    chmod +x clients/macos/Illogical/Supporting/bin/illogicald
    # The terminfo database beside it, into Contents/Resources/terminfo. The
    # daemon points every child's TERMINFO here, which is what makes
    # TERM=xterm-ghostty a name the shell can look up -- without it a shell has
    # no terminfo at all and cannot move its own cursor. See src/core/pty.zig.
    #
    # ILLOGICAL_TERMINFO_DIR names a prebuilt database for the same reason
    # ILLOGICAL_DAEMON_BIN names a prebuilt daemon: a release stages what the
    # tarball already built rather than building a second copy.
    terminfo="${ILLOGICAL_TERMINFO_DIR:-zig-out/share/terminfo}"
    if [ ! -d "$terminfo" ]; then
        echo "no terminfo database at $terminfo (did zig build run?)" >&2
        exit 1
    fi
    rm -rf clients/macos/Illogical/Supporting/terminfo
    cp -R "$terminfo" clients/macos/Illogical/Supporting/terminfo

# Test the pure-Swift client core. Needs no XCFramework.
test-swift:
    cd clients/macos/Packages/IllogicalKit && {{xcenv}} swift test

# Build the Mac app. Requires `just xcframework` and `just xcodeproj` first.
# DerivedData is pinned so `just run-app` always launches what was just built.
app: stage-daemon
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' build

# The app as it ships: Release, and carrying a version rather than the 0.0.0
# placeholder project.yml holds.
#
# DerivedData of its own, so a release build never overwrites the Debug bundle
# `just run-app` and the benchmarks launch. Signing is not here -- it needs
# secrets and a keychain, which is scripts/dist-app.sh's problem.
#
# ONLY_ACTIVE_ARCH=NO because Xcode defaults it to YES and would give an Apple
# Silicon runner an arm64-only app. The daemon inside it is universal; the app
# around it has to be too, or an Intel Mac cannot launch what it downloaded.
app-release version=repo_version: stage-daemon
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Release -derivedDataPath .build/xcode-release -destination 'platform=macOS' ONLY_ACTIVE_ARCH=NO MARKETING_VERSION={{version}} CURRENT_PROJECT_VERSION={{build_number}} build

# Run the renderer tests. Needs `just xcframework` and `just xcodeproj` first.
test-renderer:
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' test

# The M3 gate: launch to window, and first frame against 0 vs N lines of
# scrollback. Needs `zig build` and `just app` first.
bench-launch runs="5" lines="20000":
    ./scripts/bench-launch.sh {{runs}} {{lines}}

# The M2 gate: attach to `snapshot_ready` across scrollback sizes, which must
# not differ. Needs `zig build` and `just app` first.
bench-attach runs="5" *lines="200 20000 200000":
    ./scripts/bench-attach.sh {{runs}} {{lines}}

# The M5 gate: what `illogicald --stdio` costs against a direct unix socket.
# Stands something in for ssh, so it bounds the bridge, not a network.
# Needs `zig build` and `just app` first.
bench-remote runs="5" lines="20000":
    ./scripts/bench-remote.sh {{runs}} {{lines}}

# Renderer benchmarks. Only meaningful with optimization, so Release.
bench-renderer:
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Release -derivedDataPath .build/xcode-rel -destination 'platform=macOS' test

# Build and launch the Mac app.
run-app: app
    open clients/macos/.build/xcode/Build/Products/Debug/Illogical.app

# Launch the app and give it a couple of terminals to show.
#
# No daemon is started here any more: the app starts one itself when nothing is
# listening, which is the whole point of the embedded server. So this waits for
# *the app's* daemon rather than racing it -- `illogical list` answering is the
# same event the app is waiting for.
demo: run-app
    for i in $(seq 1 100); do ./zig-out/bin/illogical list >/dev/null 2>&1 && break; sleep 0.1; done
    ./zig-out/bin/illogical new -s Demo -n shell
    ./zig-out/bin/illogical new -s Demo -n logs

fmt-swift:
    swift-format format --in-place --recursive clients/macos/Illogical clients/macos/Tests clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

# --- housekeeping -----------------------------------------------------------

# Everything CI runs.
ci: fmt-check test smoke-ensure test-swift

clean:
    rm -rf zig-out .zig-cache zig-pkg dist
    rm -rf clients/macos/.build clients/macos/Frameworks clients/macos/Illogical.xcodeproj
    rm -rf clients/macos/Illogical/Supporting/bin
