# Wire protocol

Version 1. Implemented by [`src/core/protocol.zig`](../src/core/protocol.zig) and
[`IllogicalProtocol/Frame.swift`](../clients/macos/Packages/IllogicalKit/Sources/IllogicalProtocol/Frame.swift).
Those two must stay byte-for-byte in step; both carry the same tests.

> **Revised 2026-09-04.** Superlogical's own framing has never been published, so
> ours is invented — but the *semantics* below are taken from
> [RESEARCH.md](RESEARCH.md). Corrections from the first draft marked ⚠.

## Design rules

Three rules, all from [ARCH t=203–356]. Everything else is mechanism.

1. **Raw bytes, never diffs.** The payload of `output` is exactly what the child
   wrote. tmux and zellij track a screen and ship diffs; we tee PTY bytes "like
   SSH" to every client and assume each one is a correct, fast terminal.
2. **One writer, many readers.** Input is serialized through the server, which
   owns authoritative state. Clients are replicas — "synchronized finite state
   machines". A wrong client renders wrongly and affects nothing else.
3. **Recovery is re-attach, not reconciliation.** A desynced client tears down
   and replays the handshake. There is no merge protocol to get wrong.

## Framing

⚠ **One connection per terminal**, not per session [ARCH t=440]. A client showing
four splits holds four connections. Session-level operations use a separate
control connection.

```
byte  0      1                9              13          13 + len
      +------+----------------+--------------+--------------+
      | type | terminal       | len          | payload      |
      | u8   | u64 LE         | u32 LE       | len bytes    |
      +------+----------------+--------------+--------------+
```

- Terminal id `0` is the connection-level control channel.
- `len` ≤ 1 MiB; senders chunk.
- High bit of `type` marks direction: `< 0x80` is client→server.

Thirteen bytes on every frame is deliberate. Decoding an `output` frame — by far
the most common — must cost a bounds check and two loads, with no allocator and
no parser.

## Frames

### Client → server

| Type | Name | Payload |
| --- | --- | --- |
| `0x01` | `hello` | protocol version, client name, capabilities |
| `0x02` | `list` | — |
| `0x03` | `create` | session id, name, argv, env, cwd, initial size |
| `0x04` | `attach` | size, scrollback budget |
| `0x05` | `detach` | — |
| `0x06` | `kill` | signal |
| `0x07` | `input` | raw bytes for the PTY |
| `0x08` | `resize` | cols, rows, cell px |
| `0x09` | `ping` | opaque token |
| `0x0a` | `peek` | include scrollback? |

### Server → client

| Type | Name | Payload |
| --- | --- | --- |
| `0x81` | `welcome` | protocol version, server version, session list |
| `0x82` | `session_list` | sessions and their terminals |
| `0x83` | `created` | new terminal id |
| `0x84` | `snapshot_begin` | snapshot format version |
| `0x85` | `snapshot_chunk` | verbatim `GHOSTSNP` bytes |
| `0x86` | `snapshot_ready` | — |
| `0x87` | `snapshot_end` | — |
| `0x88` | `output` | unprocessed PTY bytes |
| `0x89` | `exited` | exit status |
| `0x8a` | `sessions_changed` | — (client re-issues `list`) |
| `0x8b` | `err` | code, message |
| `0x8c` | `pong` | echoed token |
| `0x8d` | `screen` | plain-text rendering, in reply to `peek` |

`peek` is the automation primitive: it returns what the server's own terminal
currently shows, as plain text, without attaching. Scripts and agents can read a
terminal without pretending to be a client — the same idea as
[boo](https://github.com/coder/boo)'s `peek`.

`input` and `output` payloads are opaque. The server never inspects `input`
beyond forwarding it, and never rewrites `output`.

## The attach handshake

```
client                                                  server
  │                                                       │
  ├── attach{terminal=7, cols=120, rows=40} ─────────────►│
  │                                                       │  PAUSE PTY processing
  │                                                       │  mark output offset N
  │                                                       │  encode terminal @ N
  │◄── snapshot_begin{format=1} ──────────────────────────┤
  │◄── snapshot_chunk (TERMINAL, SCREEN, PAGE…, CONT) ────┤
  │◄── snapshot_ready ────────────────────────────────────┤
  │                                                       │  UNPAUSE
  │  ★ PAINT. Screen correct. User can type/select/scroll │
  │                                                       │
  │◄── output (bytes ≥ N) ────────────────────────────────┤   ┐
  │◄── snapshot_chunk (HISTORY PAGE, newest first) ───────┤   │ interleaved
  │◄── output ────────────────────────────────────────────┤   │
  │◄── snapshot_chunk (HISTORY PAGE) ─────────────────────┤   ┘
  │◄── snapshot_end ──────────────────────────────────────┤
  │                                                       │
  │  scrollback complete                                  │
```

The pause is real and is stated directly: the server *"pauses processing at that
moment when a client is connecting of the current PTY bytes"*, sends enough state
to render, sends the ready frame, and *"then the core server part unpauses"*
[ARCH t=118–203]. It is what makes offset *N* well defined.

⚠ **The server does not unpause at READY.** `Terminal.attach` holds the terminal
lock across the whole encode, history included, so `snapshot_ready` goes out
early — the client paints after O(screen) bytes, which is the point — but no
`output` frame can interleave with the history chunks that follow it. The
diagram above is the intended shape, not the current one. Splitting the encode
needs a two-phase encoder libghostty-vt does not expose: `snapshot.encode` is
one call. Offset *N* is unaffected either way, because the subscribe and the
encode happen under the same lock.

The client drives this with libghostty-vt:

| Wire | libghostty-vt |
| --- | --- |
| `snapshot_chunk` before ready | bytes into a `GhosttyReader` |
| `snapshot_ready` | `ghostty_snapshot_decoder_ready()` → renderable terminal |
| `snapshot_chunk` after ready | bytes into that same `GhosttyReader` |
| `output` | `ghostty_terminal_vt_write()` on that same terminal |
| `snapshot_end` | `ghostty_snapshot_decoder_next()`, one page each, to `GHOSTTY_NO_VALUE` |

Interleaving `output` with `next()` is explicitly supported. A history page that
can no longer be applied is consumed, validated and reported as zero rows — so a
busy terminal degrades to *less scrollback*, never to a wrong screen.

⚠ **The Mac client does not call `next()` as history arrives**, either; it waits
for `snapshot_end` and decodes the pages then. Nothing in the protocol requires
that. `next()` reads inside the engine's lock, so a decoder starved mid-page
would stall the renderer for as long as the transport took — the reasoning is
in [CLIENT.md](CLIENT.md#the-attach-path-and-the-launch-budget).

⚠ **Attaching to a parked terminal does not unpark it.** The server streams the
park file from disk as `snapshot_chunk` frames and the terminal stays parked
[MEM t=660]. The client cannot tell the difference, which is the point.

### Why the offset mark matters

The snapshot is encoded at a specific point in the output stream. Send live
output that predates it and the client applies bytes twice; drop output produced
*during* encoding and the client misses them. So: pause, mark at *N*, encode at
*N*, resume, and send everything from *N* onward as `output`.

## Viewport and selection are client-side

⚠ The server stores **no** viewport state. Scroll position and selection live
entirely in the client [ARCH t=323]. Two clients on one terminal scroll
independently — unlike tmux, where *"when one of them scrolls, it scrolls
everybody's window"*.

Consequences:

- `output` is identical for every attached client. Fan-out is one `write` per
  subscriber, no per-client rendering.
- Scrolling into history that has not arrived yet is a **client-side loading
  state** [ARCH t=308], not a server round trip.
- Resize is per-terminal, not per-client. See the open question below.

## Desync

There is no reconciliation. If a client detects it is wrong — CRC failure, a
snapshot it cannot decode, a gap in the stream — it discards its terminal and
re-attaches from scratch [ARCH t=356]. Cheap, because attach is O(screen).

This is also the flow-control escape hatch: a client too far behind is dropped
back to a fresh attach rather than served an unbounded replay.

## Version negotiation

`hello` carries the client's protocol version; a mismatch gets `err` with
`version_mismatch` and the connection closes.

Note the *snapshot* format has **no compatibility guarantee** in libghostty-vt
right now, which is why client and server are built from one pinned ghostty
revision. Superlogical intends its protocol to be open and shipped as part of
libghostty [ARCH t=524]; if that lands, we should adopt it and delete this
document.

## Transport

| | |
| --- | --- |
| Local | unix domain socket at `$XDG_STATE_HOME/illogical/server.sock` |
| Remote | `ssh <dest> illogicald --stdio`, same frames on stdin/stdout |

No listening TCP socket, no TLS, no authentication of our own. Access to the
socket is filesystem permissions; remote access is whatever SSH decided.

## Open questions

- **Resize with disagreeing clients.** The terminal has one size; clients may
  have different window sizes. Provisionally the session's configured size wins
  and clients letterbox. Superlogical has never said.
- **Flow control.** Bounded per-client queue, overflow ⇒ forced re-attach. Never
  addressed in any source; see [OPTIMIZATIONS.md §F2](OPTIMIZATIONS.md#f2-flow-control).
- **Terminal queries.** The server always answers; see
  [ARCHITECTURE.md](ARCHITECTURE.md#terminal-queries).
- **Session sharing.** Superlogical ships live sharing from day one [ANN]. Our
  protocol permits it — many readers is already the model — but nothing above
  addresses identity or permissions.
