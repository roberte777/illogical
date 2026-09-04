#!/usr/bin/env bash
# Build ghostty-vt.xcframework from the vendored ghostty checkout and stage it
# where the macOS client's Package.swift expects it.
#
# Usage: scripts/build-xcframework.sh [native|universal]
#
#   native     macOS only, host arch. Fast. Use for day-to-day development.
#   universal  macOS arm64+x86_64 (plus iOS slices when those SDKs are present).
#              Use for anything you intend to ship.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty="$root/vendor/ghostty"
staged="$root/clients/macos/Frameworks"
mode="${1:-native}"
optimize="${ILLOGICAL_VT_OPTIMIZE:-ReleaseFast}"

if [ ! -f "$ghostty/build.zig" ]; then
  echo "error: vendor/ghostty is empty." >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Xcode is required to produce an XCFramework" >&2
  echo "       and is not provided by the nix devshell — install it from the App Store." >&2
  exit 1
fi

echo "==> building libghostty-vt ($mode, $optimize) from $(git -C "$ghostty" rev-parse --short HEAD)"
(
  cd "$ghostty"
  zig build \
    -Demit-lib-vt \
    -Dxcframework-target="$mode" \
    -Doptimize="$optimize"
)

src="$ghostty/zig-out/lib/ghostty-vt.xcframework"
if [ ! -d "$src" ]; then
  echo "error: expected $src to exist after the build" >&2
  exit 1
fi

mkdir -p "$staged"
rm -rf "${staged:?}/ghostty-vt.xcframework"
cp -R "$src" "$staged/"

echo "==> staged $staged/ghostty-vt.xcframework"
