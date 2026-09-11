# Wire protocol

Version 2 — `resize` and `attach` carry the cell in pixels, the server sends
`resized`, and a body key a peer does not know is read past rather than
refused; a version-1 client is turned away at `hello`. Implemented by [`src/core/protocol.zig`](../src/core/protocol.zig) and
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
| `0x01` | `hello` | protocol version, client name |
| `0x02` | `list` | — |
| `0x03` | `create` | session name (validated — see [Names](#names)), terminal name, argv, env, cwd, initial size |
| `0x04` | `attach` | size (cols, rows, cell px), scrollback budget |
| `0x05` | `detach` | — |
| `0x06` | `kill` | signal |
| `0x07` | `input` | raw bytes for the PTY |
| `0x08` | `resize` | cols, rows, cell px |
| `0x09` | `ping` | opaque token |
| `0x0a` | `peek` | include scrollback? |
| `0x0b` | `rename_session` | session id, new name |
| `0x0c` | `delete_session` | session id, `only_if_empty` |

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
| `0x8e` | `resized` | cols, rows — the server's terminal changed size *here* in the stream |

`peek` is the automation primitive: it returns what the server's own terminal
currently shows, as plain text, without attaching. Scripts and agents can read a
terminal without pretending to be a client — the same idea as
[boo](https://github.com/coder/boo)'s `peek`.

`input` and `output` payloads are opaque. The server never inspects `input`
beyond forwarding it, and never rewrites `output`.

`resize` and `attach` both carry the client's **cell size in device pixels**,
and both default it to zero. The server has no font, so those are the only
numbers it can give a program that asks for its size in pixels — DEC mode 2048's
in-band report, or the pixel fields of a `winsize`. Zero means "unknown", which
is what a client with no metrics of its own sends: the CLI. See [ARCHITECTURE.md](ARCHITECTURE.md#terminal-queries) for why
the report matters — without it Neovim never learns that the window changed.

`resized` is the size half of rule 2. A client's terminal is a replica of the
server's, and its *size* is part of that state, so the client does not reflow
its copy when its window changes — it asks (`resize`) and reflows when told.
The marker is queued through the same path as `output`, under the same lock,
so it sits at exactly the byte where the server's own terminal changed: every
byte before it was written for the old size and every byte after for the new.
A client that reflowed on its own cue would be a size ahead of the bytes it is
parsing for the length of a round trip, and during a drag that is every
repaint. Every attached client is sent it; that is the frame that made this
version 2, since a client that predates it cannot decode the header, and the
version check at `hello` is what keeps such a client from ever seeing one. See
[ARCHITECTURE.md](ARCHITECTURE.md#data-flow-resize).

One `resized` is not a change of size but a statement of one. An attach whose
snapshot is at a size the terminal has since left is followed by a marker
saying where it went, queued under the same lock as the snapshot so no real
resize can overtake it. That is the ordinary case for a *parked* terminal: its
park file stays at the park size on purpose, because serving it untouched is
what keeps attach latency independent of scrollback, so the client decodes the
snapshot at the size it was written at and reflows to the current one in stream
order — the same thing it does for a resize another window made. A client that
is restoring history should hold that reflow until the last page has landed;
see [PARKING.md](PARKING.md).

### `err` codes

| Code | Name | Meaning |
| --- | --- | --- |
| `0` | `unknown` | anything without a code of its own |
| `1` | `version_mismatch` | refused `hello`; the connection closes behind it |
| `2` | `no_such_session` | no terminal, or no session, with that id |
| `3` | `session_busy` | `delete_session` asked to be careful and the session still has a running child |
| `4` | `spawn_failed` | *reserved* — defined since v1, not currently sent |
| `5` | `unpark_failed` | *reserved* — defined since v1, not currently sent |
| `6` | `malformed_frame` | *reserved* — defined since v1, not currently sent |
| `7` | `desync` | the output queue overflowed; re-attach — see below |
| `8` | `invalid_name` | a `create` or `rename_session` carried a name `validateName` refuses: 1–64 bytes of `[A-Za-z0-9._-]` |
| `9` | `name_in_use` | a rename to a name another session already holds |

The three reserved codes are in the enum on both sides and nothing sends them
today. Every failure without a code of its own — a spawn that failed, a park
file that would not read back, a body that would not parse — comes back as
`unknown` with the Zig error's name as the message: a `create` carrying
`{this is not json` is answered `err(0) {"code":0,"message":"SyntaxError"}` and
the connection carries on serving. A malformed **header** is the one thing not
answered at all — the stream is a byte stream, so one wrong length makes every
later offset wrong — and the server closes the connection instead of guessing.
The three codes are documented so their numbers stay allocated.

The enum is non-exhaustive on both sides: a client that meets a code it does not
know reports it as a number rather than failing to decode the frame.

### Names

`create` and `rename_session` both carry a session name, and both are refused
with `invalid_name` if it is not 1–64 bytes of `[A-Za-z0-9._-]`. **A refused
`create` creates nothing** — no session, no terminal, no `created` frame — so a
client that offers a free-text session field must validate before it sends, or
the create silently does nothing. `IllogicalProtocol.SessionName.isValid` is
that rule, client-side.

The rule is deliberately boring because a session name is part of a path in the
park store and part of a JSON document written to it. The *terminal* name in
`create` is **not** validated: it never reaches disk, so `illogical new -n "my
name"` keeps working.

### Where a created terminal starts

`create.cwd` is a directory on the server's machine. Absent, the terminal starts
in the daemon's `$HOME`. A `cwd` that is not there is treated as absent, rather
than handed to a `chdir` that fails silently in the child and leaves the shell
wherever the daemon itself stands — Ghostty's rule for a working directory it
cannot access. The Mac client sends the directory of the terminal a new one is
made from, and only within one session; see [CLIENT.md](CLIENT.md), "Where a
new terminal starts".

### Session-scoped frames

Everything above addresses a *terminal*: the header's u64 is a terminal id, and
`0` is the control channel. `rename_session` and `delete_session` do not name a
terminal at all, so they carry the session id **in their JSON body** and are
sent on the control channel.

Neither has a reply of its own.

- **Success** is the `sessions_changed` broadcast, which every client — the
  requester included — answers with `list`. That is the frame whose own
  description has always read "created/killed/**renamed** elsewhere"; this is
  the request half of it. A `delete_session` broadcasts nothing at the moment it
  is accepted, because nothing has left the list yet: its terminals are hung up
  and go through the ordinary retirement path, which announces itself *once* —
  on the maintenance tick that retires the last of them and drops the emptied
  session together. Expect the session's row to outlive the click by a tick or
  two.
- **Failure** is an `err` on the control channel: `invalid_name`, `name_in_use`,
  `no_such_session`, or `session_busy`.

A rename to the name the session already has succeeds and does nothing. Session
ids are stable across a rename — the name is a label, and everything that holds a
session holds its id — so no client loses a tab to one.

`delete_session` cascades by default: it closes every terminal in the session.
`only_if_empty` makes it refuse instead, which is there so a script can be
careful; the Mac app always cascades, behind a confirmation.

**"Empty" means "would kill nothing", not "lists no terminals".** A terminal
leaves its session's list when the maintenance tick retires it, not when its
child exits, so a session whose last child has already exited still lists it for
up to a tick — and a session that lists nothing is swept out of existence on
that same tick. `only_if_empty` therefore refuses only while some terminal's
child is *still running*; exited-but-not-yet-retired terminals do not count.

A session's name is persisted to `sessions/<sid>/meta.json` when the session is
created and again on every rename, and the file is discarded exactly when the
session leaves the registry — which is the retirement sweep, not the moment a
`delete_session` is accepted. A session that survives a delete (a child that
ignores SIGHUP) keeps a truthful name until it actually goes. See
[PARKING.md](PARKING.md#on-disk-layout).

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
