# illogical — task runner. Everything assumes you are inside `nix develop`
# (or have direnv active).

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
    swift-format lint --strict --recursive clients/macos/Illogical clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

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
    cd clients/macos/Packages/IllogicalKit && swift test

# Build the Mac app. Requires `just xcframework` and `just xcodeproj` first.
# DerivedData is pinned so `just run-app` always launches what was just built.
app:
    cd clients/macos && xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' build

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
    swift-format format --in-place --recursive clients/macos/Illogical clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

# --- housekeeping -----------------------------------------------------------

# Everything CI runs.
ci: fmt-check test test-swift

clean:
    rm -rf zig-out .zig-cache zig-pkg
    rm -rf clients/macos/.build clients/macos/Frameworks clients/macos/Illogical.xcodeproj
