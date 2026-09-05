# illogical — task runner. Everything assumes you are inside `nix develop`
# (or have direnv active).

# xcodebuild and swiftpm read environment variables as build-setting overrides,
# so the devshell's stdenv hands them a toolchain they must not use: LD=ld
# replaces Xcode's clang driver with the raw linker, and SDKROOT points Xcode's
# Swift 6 compiler at nix's macOS 14.4 SDK. zig still needs all of it, so strip
# them per-recipe instead of dropping them from the devshell.
xcenv := "env -u LD -u CC -u CXX -u AR -u NM -u RANLIB -u STRIP -u SDKROOT -u DEVELOPER_DIR -u MACOSX_DEPLOYMENT_TARGET -u LD_DYLD_PATH"

default:
    @just --list

# --- server -----------------------------------------------------------------

# Build illogicald + illogical.
build:
    zig build

# Build with optimizations.
build-release:
    zig build -Doptimize=ReleaseFast

# Run the whole Zig test suite.
test:
    zig build test

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

# --- macOS client -----------------------------------------------------------

# Build ghostty-vt.xcframework from vendor/ghostty and stage it for the client.
# Pass `universal` for a shippable multi-arch build.
xcframework MODE="native":
    ./scripts/build-xcframework.sh {{MODE}}

# Regenerate Illogical.xcodeproj from project.yml.
xcodeproj:
    cd clients/macos && xcodegen generate

# Test the pure-Swift client core. Needs no XCFramework.
test-swift:
    cd clients/macos/Packages/IllogicalKit && {{xcenv}} swift test

# Build the Mac app. Requires `just xcframework` and `just xcodeproj` first.
# DerivedData is pinned so `just run-app` always launches what was just built.
app:
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' build

# Run the renderer tests. Needs `just xcframework` and `just xcodeproj` first.
test-renderer:
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' test

# The M3 gate: launch to window, and first frame against 0 vs N lines of
# scrollback. Needs `zig build` and `just app` first.
bench-launch runs="5" lines="20000":
    ./scripts/bench-launch.sh {{runs}} {{lines}}

# The M2 gate: attach to `snapshot_ready` across scrollback sizes, which must
# not differ. Needs `zig build` and `just app` first.
bench-attach runs="5" *LINES="200 20000 200000":
    ./scripts/bench-attach.sh {{runs}} {{LINES}}

# Renderer benchmarks. Only meaningful with optimization, so Release.
bench-renderer:
    cd clients/macos && {{xcenv}} xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Release -derivedDataPath .build/xcode-rel -destination 'platform=macOS' test

# Build and launch the Mac app.
run-app: app
    open clients/macos/.build/xcode/Build/Products/Debug/Illogical.app

# Start a daemon and a couple of terminals, then launch the app against them.
demo: build app
    ./zig-out/bin/illogicald & sleep 1
    ./zig-out/bin/illogical new -s Demo -n shell
    ./zig-out/bin/illogical new -s Demo -n logs
    open clients/macos/.build/xcode/Build/Products/Debug/Illogical.app

fmt-swift:
    swift-format format --in-place --recursive clients/macos/Illogical clients/macos/Tests clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

# --- housekeeping -----------------------------------------------------------

# Everything CI runs.
ci: fmt-check test test-swift

clean:
    rm -rf zig-out .zig-cache zig-pkg
    rm -rf clients/macos/.build clients/macos/Frameworks clients/macos/Illogical.xcodeproj
