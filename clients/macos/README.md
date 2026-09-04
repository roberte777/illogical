# Illogical — macOS client

Native Mac client for `illogicald`. SwiftUI + AppKit shell, libghostty-vt for
terminal state, Metal for drawing (M3 — see [../../docs/ROADMAP.md](../../docs/ROADMAP.md)).

## Prerequisites

Xcode. It is **not** provided by the nix devshell — Swift 6 and `xcodebuild` are
not packaged in nixpkgs — so install it from the App Store or developer.apple.com.
Everything else (`xcodegen`, `swift-format`, `swiftlint`) comes from the shell.

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
| `Illogical/Supporting/` | `Info.plist`, entitlements |
| `Packages/IllogicalKit/` | pure-Swift protocol core; `swift test` needs no XCFramework |
| `Frameworks/` | staged `ghostty-vt.xcframework` (generated, gitignored) |

## Tests

```bash
just test-swift        # IllogicalProtocol — fast, no Xcode project needed
```

`IllogicalProtocol` deliberately has no libghostty-vt dependency so the wire
format stays testable in isolation. Its tests mirror the Zig ones in
[`src/core/protocol.zig`](../../src/core/protocol.zig) — change one, change both.

## Not sandboxed

The client talks to a unix socket outside a container and shells out to `ssh`
for remote hosts, so `com.apple.security.app-sandbox` is off. Revisit if this
ever ships through the App Store.
