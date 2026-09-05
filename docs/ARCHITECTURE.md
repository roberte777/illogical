# Architecture

> **Revised 2026-09-04** against primary sources — see [RESEARCH.md](RESEARCH.md).
> The first draft's IO model was wrong in a way that mattered. Corrections
> marked ⚠.

## The one-page version

```
   child process              illogicald                          client
   ─────────────              ──────────                          ──────

   $ cargo build
        │
        │ writes bytes
        ▼
   ┌──────────┐  raw bytes  ┌───────────────────┐
   │   PTY    │────────────►│ ghostty-vt        │  authoritative state,
   │  master  │             │ Terminal          │  never rendered
   └──────────┘             └───────────────────┘
        │                            │
        │                            │ 60s no PTY reads
        │                            ▼
        │                   ┌───────────────────┐
        │                   │ snapshot.gsnp     │  park store (disk)
        │                   └───────────────────┘
        │                            │
        │                            │ attach to a PARKED terminal
        │                            │ is served straight from here
        │                            ▼
        │  the same raw bytes, teed unmodified
        └──────────────────────────────────────────►  ┌──────────────────┐
                                                      │ ghostty-vt       │
        on attach, first:                             │ Terminal         │
        snapshot through READY ─────────────────────► │       +          │
        then: history, newest→oldest ───────────────► │ CoreText renderer│
                                                      │       +          │
        input ◄─────────────────────────────────────  │ own viewport     │
        (serialized to the server)                    └──────────────────┘
```

Two copies of the same terminal implementation, fed the same bytes. Mitchell
calls this *"a distributed system of synchronized finite state machines"*
[ARCH t=273]. The server's copy is authoritative and exists so attach is
O(screen). The client's copy exists so it can draw, at full speed, regardless of
what the server is doing.

## The session model

⚠ A **session** is a named container of **terminals**. Each terminal is 1:1 with
a PTY and has its own protocol connection [ARCH t=440].

```
session "api-work"            ← named, shared, reconnected to
├── terminal 1  → PTY → zsh   ← has state, is parked/unparked independently
├── terminal 2  → PTY → cargo watch
└── terminal 3  → PTY → agent
```

The client decides layout. Splits, tabs and windows are native OS widgets; each
holds one connection to one terminal. The server never divides a grid and never
draws a status bar.

## Server IO: two regimes per PTY

⚠ **This is the part the first draft got wrong.** It proposed a single libxev
loop owning every PTY master. That is precisely the configuration Mitchell says
he measured and rejected:

> "the fastest way to get IO performance is to put each PTY in its own dedicated
> OS thread blocked on the read syscall … if you throw multiple PTY FDs into
> kqueue or epoll or io_uring, there is a very noticeable hit to latency, to IO
> throughput. You cannot put these all into an evented system."
> — [MEM t=399]

But a thread per PTY does not survive ten thousand terminals [MEM t=443]. So each
PTY sits in one of two regimes and migrates between them:

| | **Hot** | **Parked** |
| --- | --- | --- |
| Mechanism | dedicated OS thread blocked on `read()` | fd in one shared kqueue/epoll poller |
| Latency / throughput | baseline | 5–10% worse [MEM t=504] |
| Cost per PTY | a kernel thread + stack | an fd registration |
| When | a client is watching **and** it is producing output | terminal parked, **or** nobody watching |

The migration rule, verbatim: *"if the terminal gets parked, we throw that into
the centralized poller. Two, if there's no clients observing the terminal at that
moment, we also move it because you get about a 5 to 10% hit in IO throughput,
but that's worth it when you're not looking at it"* [MEM t=504].

So libxev's role is the **parked** poller, the control socket, and timers — not
the hot path. A hot PTY is a blocking `read()` on a dedicated thread.

## Components

### `illogicald` — the session server (Zig)

| Responsibility | Notes |
| --- | --- |
| PTY lifecycle | one master fd per terminal, in one of the two regimes above |
| Terminal state | one `ghostty-vt` terminal per *resident* terminal |
| Output fan-out | raw bytes to every attached client, unmodified |
| Input serialization | one writer; all client input funnels to the PTY |
| Terminal queries | answered by the server, always — see below |
| Parking | three levels ([PARKING.md](PARKING.md)) |
| Attach | snapshot then live output ([PROTOCOL.md](PROTOCOL.md)) |
| Control socket | unix socket; also speaks the protocol over stdio for SSH |

Zig, because the terminal core is Zig. `ghostty-vt` is imported as a native Zig
module, so the server uses it with no FFI boundary.

**Threading.** A terminal is never touched by two threads at once — libghostty-vt
requires this. Each terminal has a lock; its hot PTY thread holds it while
writing. Snapshot encode/decode and scrollback compression run on a pool and take
the same lock, which is why both are incremental or bounded.

### `illogical` — the control CLI (Zig)

`list`, `new`, `kill`, `attach`, `doctor`. Shares `src/core` with the daemon.

`illogical attach` is a terminal client for when you are already in a terminal.
It is **not** the fast path — it has to re-emit VT into whatever terminal it is
running inside, which is architecturally the compatibility mode Mitchell
describes: *"the same trade-off as other multiplexers"* [ARCH t=507].

### `Illogical.app` — the macOS client (Swift)

| Layer | Technology |
| --- | --- |
| Shell, windows, splits, session dropdown | SwiftUI + AppKit, native widgets |
| Terminal state | libghostty-vt via `ghostty-vt.xcframework` |
| Rendering | CoreText, one `CTLine` per style run ([why not Metal](ROADMAP.md#why-there-is-no-metal-renderer)) |
| Scrollback | native scroll views over the VT scrollback |
| Transport | unix socket locally; `ssh <host> illogicald --stdio` remotely |

One connection per terminal, per [ARCH t=440]. See [CLIENT.md](CLIENT.md).

### `vendor/ghostty` — the pin

A submodule at a fixed commit. The server's Zig module, the client's XCFramework,
and the snapshot format all derive from it. Bumping it is a protocol change.

## Terminal queries

⚠ **Ours, not researched** — no source covers it.

The child writes `DA`, `DSR`, `XTWINOPS` to the PTY and expects a reply. In our
model the **server always answers**, whether zero or fifty clients are attached.
Clients never do.

This differs from [boo](https://github.com/coder/boo), where the attached
client's real terminal answers and the daemon only covers the detached case. boo
needs that split because its client is a passthrough TTY. Ours is a real terminal
emulator that is not in the byte path back to the PTY, so letting clients answer
would race them against each other and produce duplicate replies.

Open: which size to report when attached clients disagree. Provisionally the
session's configured size, not any client's.

## Data flow: attach

1. Client sends `attach{terminal, cols, rows}`.
2. **Server pauses PTY processing** for that terminal and marks the output
   stream at offset *N* [ARCH t=118].
3. Server encodes the terminal at *N* and streams it as `snapshot_chunk` frames.
   `snapshot_ready` follows the snapshot's READY marker.
4. **Client paints.** It has the active screen and any unfinished parser state,
   and the user can type, select and scroll immediately [ARCH t=185].
5. Server **unpauses** and sends `output` frames for bytes ≥ *N*.
6. History pages stream underneath, newest→oldest, interleaved with (5). Gaps
   the user scrolls into show a loading state [ARCH t=308].
7. `snapshot_end` at FINISH.

Steps 5 and 6 interleave safely: libghostty-vt explicitly permits rendering,
resizing and live writes between history-page restores.

**If the terminal is parked, none of this wakes it.** The park file *is* the
attach payload, so the server streams it from disk and the terminal stays parked
[MEM t=660].

## Data flow: input

Input is serialized. A client sends `input`; the server writes it to the PTY.
One writer, many readers [ARCH t=273]. There is no client-side echo and no
reconciliation — a client that believes something wrong simply renders something
wrong, and the authoritative state is unaffected.

Recovery is not a protocol: a desynced client tears down and replays the attach
handshake [ARCH t=356].

## Remote hosts

`ssh host illogicald --stdio` puts the same frame stream on stdin/stdout. The
user's existing SSH config, keys, jump hosts and agent forwarding work, and there
is no listening socket to secure.

Superlogical's deployment story is the same shape — self-hosted, embedded in the
app, runnable anywhere, *"on every Kubernetes pod potentially"* [MEM t=46].

## Repository layout

```
build.zig, build.zig.zon    Zig workspace: illogicald + illogical
flake.nix                   dev environment (Zig 0.16 via zig-overlay)
justfile                    task runner

src/core/                   shared: protocol, session, pty, park
src/daemon/                 illogicald
src/cli/                    illogical

clients/macos/
  project.yml               XcodeGen source of truth
  Illogical/                app target
  Packages/IllogicalKit/    pure-Swift protocol core
  Frameworks/               staged ghostty-vt.xcframework (generated)

scripts/build-xcframework.sh
vendor/ghostty              submodule; the pin
docs/
```

## Further reading

| | |
| --- | --- |
| [RESEARCH.md](RESEARCH.md) | what Superlogical actually does, with citations |
| [OPTIMIZATIONS.md](OPTIMIZATIONS.md) | every performance technique, and whether we adopt it |
| [PROTOCOL.md](PROTOCOL.md) | wire format and the attach handshake |
| [PARKING.md](PARKING.md) | the three levels of parking |
| [CLIENT.md](CLIENT.md) | macOS client design |
| [ROADMAP.md](ROADMAP.md) | milestones |
