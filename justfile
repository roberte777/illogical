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
app:
    cd clients/macos && xcodebuild -project Illogical.xcodeproj -scheme Illogical -configuration Debug build

fmt-swift:
    swift-format format --in-place --recursive clients/macos/Illogical clients/macos/Packages/IllogicalKit/Sources clients/macos/Packages/IllogicalKit/Tests

# --- housekeeping -----------------------------------------------------------

# Everything CI runs.
ci: fmt-check test test-swift

clean:
    rm -rf zig-out .zig-cache zig-pkg
    rm -rf clients/macos/.build clients/macos/Frameworks clients/macos/Illogical.xcodeproj
