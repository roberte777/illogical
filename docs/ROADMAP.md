# Roadmap

Milestones are ordered by what unblocks what. Each one ends somewhere you can
actually use the thing.

## M0 — Scaffold ✅

- Nix devshell pinning Zig 0.16 (`zig-overlay`), matching `vendor/ghostty`.
- `vendor/ghostty` submodule; server and client build from one pinned revision.
- Zig workspace: `illogicald` + `illogical`, both linking the `ghostty-vt`
  module.
- `ghostty-vt.xcframework` build script, verified end to end.
- macOS app target (XcodeGen + SwiftUI) building against libghostty-vt.
- Wire protocol defined and implemented twice — Zig and Swift — with matching
  tests.
- Goals, architecture, protocol and parking written down.

## M1 — The session server

Ends at: `illogical new`, `illogical list`, and a session that keeps running
after the CLI exits.

- libxev loop over PTY masters and the control socket.
- PTY allocation and child spawn (`src/core/pty.zig` is a stub today).
- One `ghostty-vt` terminal per session, fed raw PTY output, continuation
  tracking on from creation.
- Frame reader/writer over unix sockets.
- `hello` / `list` / `create` / `kill` / `input` / `resize`.
- Session registry + `meta.json` persistence.

## M2 — Attach

Ends at: `illogical attach` shows the correct screen instantly, then fills in
scrollback.

- `snapshot_encode` at a marked output offset.
- The `snapshot_begin` → `ready` → history → `end` sequence.
- Output fan-out to N attached clients.
- Client-side `SnapshotRestore` driven from the wire (streaming `GhosttyReader`,
  not the buffered form in the scaffold).
- The Mac client's transport and session dropdown, live.

## M3 — The renderer

Ends at: the Mac app is a terminal you would actually use.

- Metal renderer fed by `ghostty_render_state_*`, with the dirty tracking the
  API already exposes.
- CoreText glyph rasterization into an atlas; ligatures, box drawing, emoji.
- Native scrollback — real scroll views over the VT scrollback, not synthesized
  wheel sequences.
- Key and mouse encoding via `ghostty_encode_key` / `ghostty_encode_mouse`.
- Selection and copy via `selection.h` / `formatter.h`.
- Launch-time budget enforced with `os_signpost`.

## M4 — Parking

Ends at: 500 idle sessions on a laptop, and you cannot tell.

- Idle detection and the park timer.
- Snapshot to disk, atomic rename, terminal release.
- Unpark on PTY readability; two-phase restore.
- Background history restore.
- Flow control and slow-client policy (see PROTOCOL.md).
- The benchmark suite from GOALS.md, run in CI.

## M5 — Remote

Ends at: the dropdown lists sessions on other machines.

- `illogicald --stdio`.
- SSH transport in the client, reusing the user's SSH config.
- Multiple simultaneous hosts in one window.
- Reconnect-and-reattach on network loss.

## M6 — Polish

- Session rename, reorder, and per-session working directory in the UI.
- Config file.
- Notifications on session exit.
- Daemon restart survival for live children (fd handoff — see PARKING.md).
- Second native client to prove the protocol is not accidentally Mac-shaped.

## Open questions

- **Snapshot format churn.** libghostty-vt says format version 1 has no
  compatibility guarantee. Pinning one revision for both sides works now, but
  breaks the moment a client and server are upgraded separately. Do we vendor a
  frozen copy of the format, or accept lockstep upgrades?
- **Flow control policy.** Is "drop the slow client back to a fresh attach"
  actually right, or is it surprising when a client is only briefly stalled?
- **Scrollback budget.** Who decides how much history a client gets — the
  server's policy, or the client's `attach` request?
- **Alternate screen and parking.** A session sitting in a full-screen TUI is
  idle by our definition but has expensive-to-restore state. Does it need a
  different threshold?
