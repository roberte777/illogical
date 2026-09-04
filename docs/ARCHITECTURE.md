# Architecture

## The one-page version

```
   child process                illogicald                        client
   ─────────────                ──────────                        ──────

   $ cargo build
        │
        │ writes bytes
        ▼
   ┌──────────┐   raw bytes  ┌───────────────────┐
   │   PTY    │─────────────►│ ghostty-vt        │   the server's own
   │  master  │              │ Terminal (state)  │   terminal state,
   └──────────┘              └───────────────────┘   never rendered
        │                             │
        │                             │ idle 60s
        │                             ▼
        │                    ┌───────────────────┐
        │                    │ snapshot.gsnp     │  park store (disk)
        │                    └───────────────────┘
        │
        │ same raw bytes, fanned out
        └───────────────────────────────────────────►  ┌──────────────────┐
                                                       │ ghostty-vt       │
        on attach, first:                              │ Terminal (state) │
        snapshot READY prefix ───────────────────────► │        +         │
        then: history pages ─────────────────────────► │ Metal renderer   │
                                                       └──────────────────┘
```

Two copies of the same terminal implementation, fed the same bytes. The server's
copy exists so a newly attaching client does not have to replay history. The
client's copy exists so it can draw.

## Components

### `illogicald` — the session server (Zig)

| Responsibility | Notes |
| --- | --- |
| PTY lifecycle | `posix_openpt` + spawn, one master fd per session |
| Terminal state | one `ghostty-vt` terminal per *live* session |
| Output fan-out | raw bytes to every attached client, unmodified |
| Parking | snapshot to disk after idle, free the terminal ([PARKING.md](PARKING.md)) |
| Attach handshake | snapshot stream then live output ([PROTOCOL.md](PROTOCOL.md)) |
| Control socket | unix socket; also speaks the protocol over stdio for SSH |

Written in Zig because the terminal core is Zig. `ghostty-vt` is imported as a
native Zig module (`vendor/ghostty` → `dep.module("ghostty-vt")`), so the server
uses it with no FFI boundary, no C ABI marshalling, and no separate build.

**Event loop.** [libxev](https://github.com/mitchellh/libxev) — kqueue on macOS,
io_uring on Linux. It is what ghostty itself uses, and its completion model maps
cleanly onto "PTY readable ⇒ deliver output *and* unpark". Not yet wired up; see
[ROADMAP.md](ROADMAP.md) M1.

**Threading.** One loop thread owns all PTYs and all terminal state. Snapshot
encode/decode for parking happens on a small thread pool, because it is the only
operation whose cost scales with scrollback size. A terminal is never touched by
two threads at once — libghostty-vt requires this.

### `illogical` — the control CLI (Zig)

`list`, `new`, `kill`, `attach`, `doctor`. Shares `src/core` with the daemon, so
there is exactly one implementation of the wire format on the server side.

`illogical attach` is a terminal client for when you are already in a terminal.
It is *not* the primary interface — it does not get the fast path, because it
has to re-emit VT into whatever terminal it happens to be running inside.

### `Illogical.app` — the macOS client (Swift)

| Layer | Technology |
| --- | --- |
| Shell, window, session dropdown | SwiftUI + AppKit |
| Terminal state | libghostty-vt via `ghostty-vt.xcframework` |
| Rendering | Metal, with a CoreText-rasterized glyph atlas |
| Scrollback | native `NSScrollView` semantics over the VT scrollback |
| Transport | unix socket locally; `ssh <host> illogicald --stdio` remotely |

The client imports the XCFramework built from the *same* `vendor/ghostty`
revision as the server, so both sides are guaranteed to agree on the snapshot
format — which is not versioned for compatibility yet (`snapshot.h`: "format
version 1 is a work in progress").

### `vendor/ghostty` — the pin

A git submodule at a specific ghostty commit. Everything else derives from it:

- the server's `ghostty-vt` Zig module,
- the client's `ghostty-vt.xcframework` (`scripts/build-xcframework.sh`),
- the snapshot format both sides speak.

Bumping the submodule is therefore a protocol change. Treat it as one.

## Why the server keeps terminal state at all

It would be simpler for the server to be a dumb byte pipe with a ring buffer.
That fails goal G3: a client attaching to a session with 100 MB of scrollback
would have to replay all of it to know what is on screen, or accept a wrong
screen. Keeping a real terminal server-side means:

- attach is O(screen), not O(history);
- parking is possible at all — you cannot snapshot a byte pipe into something
  that answers "what is on screen?" in 200 µs;
- the server can answer questions (size, title, working directory, exit status)
  without a client attached.

The cost is memory per live session, which is exactly what parking buys back.

## Data flow: attach

1. Client sends `attach{session, cols, rows}`.
2. Server marks the session's output stream at offset *N*.
3. Server encodes the terminal at offset *N* and streams it as `snapshot_chunk`
   frames; `snapshot_ready` is sent once `READY` has gone out.
4. **Client paints.** It has the active screen and any unfinished VT parser
   state.
5. Server continues streaming history pages; client prepends them.
6. Server sends `output` frames for bytes ≥ *N*, interleaved with (5). The
   client applies them to the same terminal.
7. `snapshot_end` when `FINISH` has been sent. Scrollback is complete.

Steps 5 and 6 interleave safely because libghostty-vt explicitly permits
rendering, resizing and live writes between history-page restores.

## Data flow: park and unpark

See [PARKING.md](PARKING.md).

## Remote hosts

No custom network protocol, no TLS, no auth system. `ssh host illogicald --stdio`
puts the same frame stream on stdin/stdout. The user's existing SSH config,
keys, jump hosts and agent forwarding all just work, and there is no listening
socket to secure.

## Repository layout

```
build.zig, build.zig.zon    Zig workspace: illogicald + illogical
flake.nix                   dev environment (Zig 0.16 via zig-overlay)
justfile                    task runner

src/core/                   shared: protocol, session, pty, park
src/daemon/                 illogicald
src/cli/                    illogical

clients/macos/
  project.yml               XcodeGen source of truth (.xcodeproj is generated)
  Illogical/                app target
  Packages/IllogicalKit/    pure-Swift protocol core, `swift test`-able
  Frameworks/               staged ghostty-vt.xcframework (generated)

scripts/build-xcframework.sh
vendor/ghostty              submodule; the pin
docs/
```
