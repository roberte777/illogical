# Illogical — macOS client

Native Mac client for `illogicald`. SwiftUI + AppKit shell, libghostty-vt for
terminal state, Metal for drawing. See
[../../docs/CLIENT.md](../../docs/CLIENT.md) for how the renderer works.

## Prerequisites

Xcode. It is **not** provided by the nix devshell — Swift 6 and `xcodebuild` are
not packaged in nixpkgs — so install it from the App Store or developer.apple.com.
Everything else (`xcodegen`, `swift-format`, `swiftlint`) comes from the shell.

Xcode's **Metal toolchain**, which since Xcode 16 is a separate download and is
what compiles `Shaders.metal` into the app's `default.metallib`:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Without it the build fails at the shader with a clear error.

## Building

From the repository root:

```bash
just xcframework       # builds ghostty-vt.xcframework from vendor/ghostty
just xcodeproj         # generates Illogical.xcodeproj from project.yml
just app               # xcodebuild
```

`just xcframework universal` produces an arm64 + x86_64 build; the default
`native` slice is faster and fine for development.

`Illogical.xcodeproj` is generated and gitignored — **edit `project.yml`, not
the project file.** Regenerate after adding source directories or dependencies.

## Layout

| Path | |
| --- | --- |
| `project.yml` | XcodeGen project definition — the source of truth |
| `Illogical/App/` | app entry point and window |
| `Illogical/Sessions/` | session list, dropdown, connection state |
| `Illogical/Terminal/` | libghostty-vt wrapper and the terminal surface |
| `Illogical/Terminal/Renderer/` | Metal renderer: shaders, atlases, fonts, sprites |
| `Illogical/Supporting/` | `Info.plist`, entitlements |
| `Tests/` | renderer tests — pixels, sprite geometry, benchmarks |
| `Packages/IllogicalKit/` | pure-Swift protocol core; `swift test` needs no XCFramework |
| `Frameworks/` | staged `ghostty-vt.xcframework` (generated, gitignored) |

## Tests

```bash
just test-swift        # IllogicalProtocol — fast, no Xcode project needed
just test-renderer     # the renderer, through Xcode
```

`IllogicalProtocol` deliberately has no libghostty-vt dependency so the wire
format stays testable in isolation. Its tests mirror the Zig ones in
[`src/core/protocol.zig`](../../src/core/protocol.zig) — change one, change both.

The renderer tests build a screen, render it to an IOSurface and read the
pixels back, so they can assert things like "the box drawing line has no gap at
the cell boundary" without a window. Some drive a real `TerminalEngine`, so
they cover the libghostty extraction too.

Rendering bugs are often things you have to *look* at — a glyph half a pixel
high, an underline one row too low. Set `ILLOGICAL_RENDER_DUMP` to a directory
and the showcase tests write their frames there as PNGs:

```bash
ILLOGICAL_RENDER_DUMP=/tmp/frames \
  xcrun xctest -XCTest SpriteShowcaseTests \
  .build/xcode/Build/Products/Debug/IllogicalRendererTests.xctest
```

The benchmarks skip themselves unless built with optimization; run them with
`-configuration Release`.

## Not sandboxed

The client talks to a unix socket outside a container and shells out to `ssh`
for remote hosts, so `com.apple.security.app-sandbox` is off. Revisit if this
ever ships through the App Store.
