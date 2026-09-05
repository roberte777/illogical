# Wire protocol

Version 1. Implemented by [`src/core/protocol.zig`](../src/core/protocol.zig)
and [`IllogicalProtocol/Frame.swift`](../clients/macos/Packages/IllogicalKit/Sources/IllogicalProtocol/Frame.swift).
Those two files must stay byte-for-byte in step; both carry the same tests.

## Framing

One connection multiplexes every session a client cares about.

```
byte  0      1                9              13          13 + len
      +------+----------------+--------------+--------------+
      | type | session        | len          | payload      |
      | u8   | u64 LE         | u32 LE       | len bytes    |
      +------+----------------+--------------+--------------+
```

- Session id `0` is reserved for connection-level control frames.
- `len` must not exceed 1 MiB. Senders chunk larger payloads.
- The high bit of `type` marks direction: `< 0x80` is client→server.

Thirteen bytes of header on every frame is deliberate. Output frames are by far
the most common, and decoding one must cost a bounds check and two loads —
nothing that needs an allocator or a parser.

## Frames

### Client → server

| Type | Name | Payload |
| --- | --- | --- |
| `0x01` | `hello` | protocol version, client name, capabilities |
| `0x02` | `list` | — |
| `0x03` | `create` | name, argv, env overrides, cwd, initial size |
| `0x04` | `attach` | size, scrollback budget |
| `0x05` | `detach` | — |
| `0x06` | `kill` | signal |
| `0x07` | `input` | raw bytes for the PTY |
| `0x08` | `resize` | cols, rows, cell px |
| `0x09` | `ping` | opaque token |

### Server → client

| Type | Name | Payload |
| --- | --- | --- |
| `0x81` | `welcome` | protocol version, server version, session list |
| `0x82` | `session_list` | session summaries |
| `0x83` | `created` | new session id |
| `0x84` | `snapshot_begin` | snapshot format version |
| `0x85` | `snapshot_chunk` | verbatim `GHOSTSNP` bytes |
| `0x86` | `snapshot_ready` | — |
| `0x87` | `snapshot_end` | — |
| `0x88` | `output` | unprocessed PTY bytes |
| `0x89` | `exited` | exit status |
| `0x8a` | `sessions_changed` | — (client re-issues `list`) |
| `0x8b` | `err` | code, message |
| `0x8c` | `pong` | echoed token |

`input` and `output` payloads are opaque. The server never inspects `input`
beyond forwarding it, and never rewrites `output`. That is goal G2.

## The attach handshake

This is the part that matters.

```
client                                                  server
  │                                                       │
  ├── attach{session=7, cols=120, rows=40} ──────────────►│
  │                                                       │  mark output offset N
  │                                                       │  encode terminal @ N
  │◄── snapshot_begin{format=1} ──────────────────────────┤
  │◄── snapshot_chunk (TERMINAL, SCREEN, PAGE…, CONT) ────┤
  │◄── snapshot_ready ────────────────────────────────────┤
  │                                                       │
  │  ★ PAINT. The screen is correct and complete.         │
  │                                                       │
  │◄── output (bytes ≥ N) ────────────────────────────────┤   ┐
  │◄── snapshot_chunk (HISTORY PAGE, newest first) ───────┤   │ interleaved
  │◄── output ────────────────────────────────────────────┤   │
  │◄── snapshot_chunk (HISTORY PAGE) ─────────────────────┤   ┘
  │◄── snapshot_end ──────────────────────────────────────┤
  │                                                       │
  │  scrollback is now complete                           │
```

The client drives this with libghostty-vt directly:

| Wire | libghostty-vt |
| --- | --- |
| `snapshot_chunk` before ready | bytes into `GhosttyReader` |
| `snapshot_ready` | `ghostty_snapshot_decoder_ready()` → a renderable terminal |
| `snapshot_chunk` after ready | `ghostty_snapshot_decoder_next()`, one page each |
| `output` | `ghostty_terminal_vt_write()` on that same terminal |
| `snapshot_end` | `next()` returns `GHOSTTY_NO_VALUE` |

Interleaving `output` with `next()` is explicitly supported: the snapshot
decoder applies history to the caller-owned terminal, and the terminal "may be
rendered, resized, and fed live PTY input between calls". A history page that
can no longer be applied safely is consumed, validated, and reported as zero
rows — so a busy session degrades to *less scrollback*, never to a wrong screen.

### Why the offset mark matters

The snapshot is encoded from the terminal's state at a specific point in the
output stream. If the server sent live output that predated the snapshot, the
client would apply those bytes twice. If it dropped output produced *during*
encoding, the client would miss them. So: mark at *N*, encode at *N*, send
everything from *N* onward as `output`.

## Version negotiation

`hello` carries the client's protocol version. A mismatch gets `err` with
`version_mismatch` and the connection closes. There is no compatibility window
yet — and note that the *snapshot* format has no compatibility guarantee at all
in libghostty-vt right now, which is why client and server are built from one
pinned ghostty revision.

## Transport

| | |
| --- | --- |
| Local | unix domain socket at `$XDG_STATE_HOME/illogical/server.sock` |
| Remote | `ssh <dest> illogicald --stdio`, same frames on stdin/stdout |

There is no listening TCP socket, no TLS, and no authentication of our own.
Access to the unix socket is filesystem permissions; access to a remote server
is whatever SSH already decided.

## Flow control

Not designed yet. The problem: a session producing output faster than a slow
client can drain it must not stall the PTY for *other* clients, and must not
grow an unbounded buffer.

The intended shape is a per-client bounded queue where overflow drops the client
back to a fresh attach — a client that has fallen far enough behind is better
served by a new snapshot than by a long replay. See [ROADMAP.md](ROADMAP.md) M4.
