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
        then: history, newest→oldest ───────────────► │ Metal renderer   │
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
| When | a client is watching | terminal parked, **or** nobody watching |

The migration rule, verbatim: *"if the terminal gets parked, we throw that into
the centralized poller. Two, if there's no clients observing the terminal at that
moment, we also move it because you get about a 5 to 10% hit in IO throughput,
but that's worth it when you're not looking at it"* [MEM t=504].

So an event loop's role is the **parked** poller, the control socket, and
timers — not the hot path. A hot PTY is a blocking `read()` on a dedicated
thread.

Both regimes and the migration between them are implemented, in
`src/core/poller.zig` and `Terminal.setRegime`. Three details decide whether it
works at all:

- **Getting the descriptor back.** A hot reader is inside `read()`, and closing
  the descriptor to wake it is wrong — it is being handed over, not discarded —
  and on macOS deadlocks, because `close` does not return while another thread
  holds that same descriptor in a blocking call. That was issue #28. A signal
  with an empty handler makes the read return `EINTR` and leaves the descriptor
  and its queued bytes untouched.
- **Hysteresis, one-sided.** Promotion is synchronous with the attach that
  caused it; demotion waits out `pty_park_unobserved_after` (5 s). Clicking
  between tabs must not spawn and join a thread each time.
- **Nothing is dropped.** The poller is level-triggered, so bytes that arrived
  mid-handover are reported the moment the descriptor is registered.

`illogical list` reports which regime each terminal is in, and
`scripts/bench-pty.sh` measures what the polled one costs.

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

**A terminal with no command of its own runs `$SHELL -l`** — a login shell, the
way Terminal.app and Ghostty do it. The daemon's own environment is whoever
started it: from a terminal that is a full interactive `PATH`, but from the Mac
app it is launchd's, which is `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else.
A non-login shell reads no `zprofile`, so `path_helper` never runs and no
terminal would find brew or anything else the user installed. Same class of
repair as the child locale in `pty.zig`, for the same reason. A client that
wants something else says so in `create.argv`.

Two things follow that are worth saying out loud rather than rediscovering.
`illogical new` from a shell that is *itself* a login shell re-runs
`/etc/zprofile` — where `path_helper` may reorder `PATH` — and `~/.zprofile`, so
a `PATH` carefully arranged in the outer shell can come back rearranged. That is
the well-known tmux-on-macOS behaviour, and it is accepted here for the reason
Terminal.app and Ghostty accept it: a terminal whose `PATH` is complete is worth
more than one whose `PATH` is untouched, and the daemon cannot tell which of its
clients started from where. And a `$SHELL` with no `-l` at all — elvish is the
one in circulation — opens a terminal that exits immediately on a usage error;
`create.argv` is the way to say otherwise.

**`TERM` names something the child can look up.** The client draws with
libghostty-vt, so `xterm-ghostty` is the truthful answer — but that entry is not
part of ncurses. It ships with ghostty, and on a machine that has never had
ghostty on it the name resolves to nothing at all. A child in that position has
no terminfo whatever: no `cuu1`, so zsh cannot repaint its prompt where it
stands, and answers every `SIGWINCH` by printing a fresh prompt on a new line
and leaving the old one on the screen. One split, two prompts.

So the daemon does what ghostty does (`src/termio/Exec.zig`): `zig build`
compiles ghostty's own terminfo source into `share/terminfo`, the app bundle
carries it as `Contents/Resources/terminfo` and the tarball carries it beside
the binaries, and `pty.zig` points the child's `TERMINFO` at whichever it finds.
Where the entry is already installed on the machine, `TERM` alone is enough and
nothing is pointed anywhere. Where there is no database to be found — a daemon
installed by some other means, on a host with no ghostty — the child is told
`xterm-256color`, which is a smaller terminal but a real one.

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

It follows `SIGWINCH`, so resizing the terminal it runs in resizes the session's
PTY — step 1 of [Data flow: resize](#data-flow-resize). A handler may do almost
nothing: no allocation, no lock, certainly no frames. So it raises an atomic
flag and writes one byte into a pipe, and a thread blocked on the other end
re-reads `TIOCGWINSZ` and sends the `resize`. The byte is what makes a resize
land with no further input — a thread that only checked a flag would check it
and *then* block, and a signal arriving in between would sit unnoticed until the
user typed. The flag is the other half: it collapses a drag's worth of signals
into one frame.

Step 3 is where it parts company with a real client. It has no mirror to reflow,
so it ignores `resized`: the terminal it is running inside is the only grid
there is, and that one reflowed itself when its window moved.

### `Illogical.app` — the macOS client (Swift)

| Layer | Technology |
| --- | --- |
| Shell, windows, splits, session dropdown | SwiftUI + AppKit, native widgets |
| Terminal state | libghostty-vt via `ghostty-vt.xcframework` |
| Rendering | Metal, CoreText-rasterized glyph atlas |
| Scrollback | native scroll views over the VT scrollback |
| Transport | unix socket locally; `ssh <host> illogicald --stdio` remotely |
| Server | `Contents/MacOS/illogicald` — the same binary as the standalone release |

One connection per terminal, per [ARCH t=440]. See [CLIENT.md](CLIENT.md).

The server is *in* the bundle, staged by `just stage-daemon` and copied in by a
build phase, so a machine with the app on it has a server on it. Only the
daemon: `Contents/MacOS/` also holds the app's own executable `Illogical`, and
the default macOS volume is case-insensitive, so a second file named
`illogical` in there is the same file. The CLI ships in the standalone tarball.

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

**A resize is a reply too.** Not every program learns its size from the kernel.
DEC mode 2048 asks the terminal to *push* one — `CSI 48 ; rows ; cols ; height ;
width t` on every change — and Neovim, which asks for it, stops handling
`SIGWINCH` once it is on. So a terminal that resizes the PTY and says nothing in
band leaves Neovim painting the grid it started with: shrink the window and the
screen is chopped, grow it again and the chop stays. `Terminal.resize` therefore
goes through the stream handler rather than resizing the VT directly, which is
what puts the report on the PTY beside the signal.

**Resizes are coalesced, not queued.** Ghostty's rule, and ghostty's 25ms
(`termio/Thread.zig`): the first resize arms a window, later ones replace the
size inside it without pushing the deadline back, and when it expires the
newest wins. A drag then costs one resize per window rather than one per frame.

The window is arithmetic, not politeness. The VT reflow is cheap — 5ms with a
child that ignores it — but a full-screen program answers *every* size with a
full repaint, and the daemon parses that repaint under the same lock the next
resize needs. Measured against Neovim: 27ms a step, so a one-second drag ran
half a second behind and walked visibly through sizes the window had already
left. Coalescing took the same drag to settling 14ms after the last frame.

Anything that is not a resize flushes the pending one first, so a keystroke is
never handled at a size that was asked for after it.

That report quotes a text area in *pixels*, and the server has no font. So the
cell travels on the wire — `resize` and `attach` both carry `cell_width` and
`cell_height` in device pixels — and the daemon quotes back whatever the client
that last sized the terminal said. Zero until one does, which is the value the
spec reserves for "unknown" and the honest answer for a client with no metrics
of its own (the CLI).

Open: which size to report when attached clients disagree. Provisionally the
session's configured size, not any client's. The same open question decides
whose cell is quoted; today it is simply the last one to speak.

## Data flow: resize

1. The window changes. The client sends `resize{cols, rows, cell px}` and
   **does not touch its own terminal.**
2. The server coalesces (25ms, ghostty's rule), then under the terminal lock:
   reflows its VT, writes the mode 2048 report to the PTY, sets the `winsize`
   (which raises SIGWINCH), and queues `resized{cols, rows}` to every attached
   client — through the same queue as `output`, so it lands at exactly the
   byte where the size changed.
3. The client reflows its terminal when it dequeues `resized`, in stream order
   with the output around it.
4. The program repaints for the new size; those bytes are parsed by a client
   terminal that is already that size.

Two details that are easy to get wrong. The report in step 2 is written to the
PTY *after* the terminal lock is released, never under it: the master is a
blocking descriptor, a child that has stopped reading fills the kernel's input
queue in about a kilobyte, and a write blocked there with the lock held would
park the reader thread — and with it every client of that terminal — behind a
program that is not listening.

And the reflow is the only part of step 2 that ever waits. It waits when there
is no VT to reflow (the terminal is parked) and when one is being restored under
(it is rehydrating); the winsize, the marker and the report go out either way —
the report from the `in_band_size_reports` bit `park` kept, so a program that
stopped handling `SIGWINCH` in a parked pane still hears about the drag — and
the VT is reflowed once the last history page has landed. Reflowing it sooner is
the obvious fix and the wrong one: libghostty's decoder discards every page
whose width no longer matches, so a drag across an idle pane emptied its
scrollback. An attach in between is served the snapshot at the size it is on
disk, with a `resized` marker behind it: the client adopts the one and reflows
to the other, holding that reflow until its own restore ends, for the same
reason. See docs/PARKING.md and
[#82](https://github.com/roberte777/illogical/issues/82).

Step 1 is the one that matters. Ghostty has no step 3 because it has no second
terminal: the resize sits at one point in one byte stream by construction. A
client that reflowed on its own cue would be a size ahead of what it is parsing
for a coalesce window plus a round trip — and during a drag that is every
repaint, which is what garbled lines and colour flashes on a fast resize were.
The cost is that the grid lags the window by that same interval, drawn into
the new frame with background around it: ~30ms on this machine, the SSH round
trip elsewhere.

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

⚠ That is the design, and steps 5 and 6 are only partly there. The server
unpauses after FINISH rather than after READY, so history precedes all `output`,
and the Mac client decodes the pages at `snapshot_end` rather than as they
arrive. Step 4 — the one the M2 gate measures — is real, and so is the loading
state in step 6: the snapshot declares its history extent at READY, so the
client draws the undelivered part rather than growing the scrollbar to meet it.
See [PROTOCOL.md](PROTOCOL.md#the-attach-handshake) for why the first two hold,
and [CLIENT.md](CLIENT.md#the-loading-state) for how the third works.

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

```
   Mac client                    ssh                    host
  ┌──────────┐          ┌──────────────────┐    ┌──────────────────┐
  │ terminal ├─ pipe ──►│ illogicald       ├───►│ illogicald       │
  │ terminal ├─ pipe ──►│   --stdio        │    │  (unix socket)   │
  └──────────┘          │  one per session │    │  one per host    │
                        └──────────────────┘    └──────────────────┘
```

**`--stdio` is a bridge, not a server.** The process SSH starts owns no
terminals: it connects to the host's own daemon, starting one detached if there
is none, and splices bytes between that socket and the SSH pipe. A server
started by SSH would die with the session and take its terminals with it. The
mechanism, and what it means for the daemon's standard streams, is in
[PROTOCOL.md](PROTOCOL.md#stdio-is-a-bridge-not-a-server).

Both clients speak it. `illogical --host <dest>` is the same transport from the
CLI — useful because it makes the whole remote path testable from a shell,
without a window.

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
