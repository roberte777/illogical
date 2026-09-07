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
| `0x81` | `welcome` | protocol version, and the server's own build |
| `0x82` | `session_list` | sessions and their terminals |
| `0x83` | `created` | new terminal id |
| `0x84` | `snapshot_begin` | snapshot format version |
| `0x85` | `snapshot_chunk` | verbatim `GHOSTSNP` bytes |
| `0x86` | `snapshot_ready` | — |
| `0x87` | `snapshot_end` | — |
| `0x88` | `output` | unprocessed PTY bytes |
| `0x89` | `exited` | exit status |
| `0x8a` | `sessions_changed` | — (client re-issues `list`) |
| `0x8b` | `err` | code, message. Code 7, `desync`, means "re-attach" — see below |
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

This is also the flow-control escape hatch, and the server uses it.

**And it is the whole of network-loss recovery.** A connection that goes away is
a client that has missed output — the case above with a longer gap. The terminal
on the far side never stopped, so reconnecting is a new socket, the same
`attach`, and nothing else. Nothing in the protocol distinguishes the two and
nothing needs to; the client's part is only deciding *when* to try again. See
[CLIENT.md](CLIENT.md#losing-the-network-and-getting-it-back).

## Flow control

Every client has a bounded queue of framed bytes waiting for its socket,
drained by a thread of its own. Fan-out never writes to a socket: it copies
into that queue and returns.

That indirection is the whole mechanism, and it exists because of who runs the
fan-out. Output is teed on the terminal's own reader thread, under the terminal's
lock. A `write` to a client that has stopped reading blocks until the kernel
buffer drains, so one wedged client used to stall the terminal itself — its PTY,
its state, and every other client attached to it.

When the queue would overflow:

1. Everything queued is dropped. It is a prefix of a stream the client is about
   to throw away with its terminal, and dropping it makes room for step 2.
2. `err` with code `desync` goes out in its place.
3. The **terminal** unsubscribes the client, from inside its own fan-out loop.
   Not the writer thread: that would take the terminal's lock from the far side
   of the lock order and deadlock against an attach in flight.
4. The client re-attaches. Nothing else is coming until it does.

| | |
| --- | --- |
| Queue bound | 1 MiB, sixteen PTY reads |
| Fan-out (`output`, `exited`, `sessions_changed`) | never blocks; overflow ⇒ desync |
| The client's own replies and snapshot chunks | wait for room; backpressure, not loss |

The second row is the one that matters for the architecture. The third is
ordinary blocking on the client's own thread, and it is bounded by that client
alone: a frame larger than the whole queue still goes out, because the wait is
only ever for a queue with something in it to drain.

⚠ One case is not covered. `attach` holds the terminal's lock across the encode,
so a client that stops reading *mid-attach* still stalls that terminal until it
resumes or disconnects. It is the same lock the encode has always held —
splitting it needs the two-phase encoder libghostty-vt does not expose (see the
attach handshake above) — so F2 leaves it exactly where it was and fixes the
live path, which is the one a client reaches by being slow rather than by being
broken.

## Version negotiation

`hello` carries the client's protocol version; a mismatch gets `err` with
`version_mismatch` and the connection closes.

The close is the refusal, and it is not decoration. Clients pipeline — `hello`
and `list` go out back to back — so a daemon that sent the `err` and kept
serving would answer the `list` too, and a client that reads a `session_list` as
"connected" would go on to drive a daemon whose protocol it does not speak. So
after a refused `hello` the daemon flushes the `err`, shuts the socket down in
both directions, and answers nothing that was already in flight behind it.

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

**Who starts the local daemon.** Whoever needs it and finds none. A person runs
`illogicald`; the Mac app runs `illogicald --ensure --socket <path>` and then
connects over the socket as usual. Nothing on the local fast path is a bridge or
a child — `--ensure` starts a detached daemon and exits, so the daemon it leaves
behind belongs to no one and outlives everyone. Whatever is already listening
always wins: `--ensure` connects first and starts nothing if that succeeds, and
`Server.listen` refuses to unlink a live daemon's socket if two of them race.

### `--stdio` is a bridge, not a server

⚠ The process SSH starts owns **no terminals**. It connects to the host's own
long-lived daemon — starting one, detached, if there is none — and splices bytes
between that socket and the pipe SSH gave it
([`src/daemon/stdio.zig`](../src/daemon/stdio.zig)).

```
         ssh dest illogicald --stdio
client ────────────────────────────► bridge ──────► illogicald
                                  one per session   one per host
```

It has to be this way round. A server started by SSH would die with the SSH
session and take every terminal in it, which is the one thing this project
exists to prevent.

Nothing in the bridge parses a frame. The protocol is a byte stream over a
reliable, ordered transport and a splice preserves it exactly, so the bridge
cannot desynchronize a client no matter what the two ends say to each other —
and a `snapshot_chunk` crossing it costs one copy rather than a decode and a
re-encode. The test pushes a maximum-size frame through and compares it byte for
byte.

Two consequences worth stating:

- **The remote daemon prints nothing on stdout.** That descriptor is the client's
  frame stream. A daemon the bridge starts gets `/dev/null` for all three
  standard streams and refuses to exec if it cannot get it — injected text would
  reach the client as a malformed frame. Diagnostics go to stderr, which SSH
  keeps on a channel of its own.
- **Two bridges arriving together do not start two daemons.** `Server.listen`
  probes the socket first and returns `AlreadyRunning` rather than unlinking a
  live daemon's socket out from under it, which would have left every terminal
  behind that daemon alive and unreachable.

### `welcome.server`, and what a client does with it

The `server` field is the daemon's `--version` string: a release version and the
`vendor/ghostty` revision it was built against, `0.0.0-dev+g492300cad104`. The
pin is in it because the pin is what decides whether two builds agree about a
snapshot — format v1 makes no promise across pins, so two builds differing only
in pin must compare unequal.

It is a *notice*, not a gate. The Mac app compares it against the daemon it
shipped and marks the host in the session dropdown when they differ; it blocks
nothing, because a daemon from another checkout usually works, whatever is
listening owns the terminals behind it, and a snapshot that genuinely does not
match already fails at `snapshot_begin.format`. Skew is checked at three levels
and this is the softest of them:

| Level | Where | What happens |
| --- | --- | --- |
| Protocol version | `hello` → `err(version_mismatch)` | the client stops and says so |
| Snapshot format | `snapshot_begin.format` | the attach fails loudly |
| Server build | `welcome.server` | a marker and a tooltip |

`illogicald --ensure` is this same dial-or-start with the bridge left off: it
makes sure a daemon is listening, prints one line saying which of the two
happened, and exits. `--no-spawn` composes with both, and turns either into a
probe. The Mac app uses `--ensure` rather than `--stdio` locally on purpose — a
bridge would put a process and a copy on every local connection, and a window
with four splits opens five of them.

### Multiplexing SSH

One connection per terminal means a window with four splits opens five SSH
connections to that host. So the client asks for `ControlMaster=auto` with a
`ControlPath` under `~/.ssh`: the four after the first cost a channel rather than
a handshake, and `ControlPersist` keeps the master briefly after the last one
closes. If the rendered path would not fit in a unix socket name the option is
dropped rather than passed and warned about on every connection.

`ServerAliveInterval=15` with `ServerAliveCountMax=3` is what turns a dead
network into a *closed connection*, in about forty-five seconds. Without it a
client on a laptop that changed networks waits indefinitely on a socket nobody
is on the other end of. The client turns the close into a reconnect, which is
the same path as any other desync.

## Open questions

- **Resize with disagreeing clients.** The terminal has one size; clients may
  have different window sizes. Provisionally the session's configured size wins
  and clients letterbox. Superlogical has never said.
- **Terminal queries.** The server always answers; see
  [ARCHITECTURE.md](ARCHITECTURE.md#terminal-queries).
- **Session sharing.** Superlogical ships live sharing from day one [ANN]. Our
  protocol permits it — many readers is already the model — but nothing above
  addresses identity or permissions.
