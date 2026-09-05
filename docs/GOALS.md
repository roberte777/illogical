# Goals

`illogical` is a terminal multiplexer built around one bet: **the server should
never render, and the client should never parse a byte it did not have to.**

Everything below follows from that.

> **Revised 2026-09-04** against primary sources — see [RESEARCH.md](RESEARCH.md).
> The first draft of this document got the session model and the non-goals
> materially wrong. Corrections are marked ⚠.

## What it is

A session server (`illogicald`) owns PTYs and terminal state. Native clients
attach to it, get the current screen essentially instantly, then get scrollback
streamed in behind that. The clients are real terminal emulators — not TUIs
drawing inside somebody else's terminal.

This is a clean-room build against the public description of Superlogical
(Mitchell Hashimoto / superlogical). We are not reading their source — none is
public. We are building the same architecture from the same public foundation,
libghostty-vt, guided by what Mitchell has said publicly about how theirs works.

## The model

⚠ **A session is a container of terminals, not a single terminal.**

```
session "api-work"
├── terminal 1   →  PTY  →  zsh
├── terminal 2   →  PTY  →  cargo watch
└── terminal 3   →  PTY  →  an agent
```

Superlogical's own framing is "multiple terminal blocks organized inside a
long-lived session" ([ANN]). Each terminal is 1:1 with a PTY and gets **its own
protocol connection** [ARCH t=440]. The session is the unit you name, reconnect
to, and share; the terminal is the unit that has state.

Layout — which terminal is in which split, tab or window — belongs to the client
and is drawn with native widgets. The server never divides a grid.

## Goals

### G1 — Sessions outlive clients

Close the laptop, quit the app, lose the network: the session keeps running.
Reattaching is the normal case, not recovery.

### G2 — The server ships unprocessed output

The wire carries the exact bytes the child process wrote, teed to every client
"like SSH" [ARCH t=203]. The server does not re-render a screen into a diff, does
not normalize escape sequences, and does not decide what the client can display.

This is where the performance comes from. tmux and zellij put a second, slower
terminal emulator in front of your fast one — "double parsing, double state
processing, just duplicated work" [ARCH t=50]. We do not. And because the client
parses independently, a slow server never slows the client down [ARCH t=255].

### G3 — Attach paints the current screen immediately

Attaching must not replay history to reconstruct the screen. The server pauses
PTY processing, encodes the terminal, streams enough state to render, sends a
READY frame, and unpauses [ARCH t=118].

Budget: **first frame within one round trip plus decode**, independent of how
much scrollback the session has.

### G4 — Scrollback arrives after, without blocking anything

History pages follow READY, **newest first**, and are prepended to the
already-rendered terminal. Live output keeps applying while they arrive.
Scrolling into history that has not landed yet shows a loading state rather than
blocking [ARCH t=308].

### G5 — Idle terminals cost nothing

Three independent mechanisms, all of which we adopt (see
[PARKING.md](PARKING.md)):

1. **Terminal parking** — 60 s without PTY *read* activity ⇒ snapshot to disk,
   free the terminal. Unpark on the next read.
2. **PTY parking** — move the fd from its dedicated OS thread into a shared
   poller when nobody is watching.
3. **Client buffer parking** — free per-client buffers for idle clients.

⚠ "Idle" means **no PTY reads**. Typing does not count. A terminal that is
attached, focused, and being typed into is still parked if it is producing no
output [MEM t=296].

### G6 — Scale to agent workloads

The design target is not one person with ten terminals. It is *"dozens of
people, hundreds of people with an order of magnitude, hundreds of thousands of
agents or more"* [MEM t=139]. Memory must scale with **active** terminals, not
total terminals.

Mitchell's own reasoning applies to us: *"if we design for excessive, then the
low end will work really great."*

### G7 — Native clients, one per platform

Each client is written in its platform's native toolkit and powered by
libghostty-vt. macOS is first: Swift, AppKit/SwiftUI, Metal.

The Mac client specifically must:

- **Launch in half a bounce.** Chrome appears before any network work completes.
- **Switch sessions and terminals from a dropdown**, showing residency inline.
- **Connect to remote hosts.**
- **Own its own viewport.** ⚠ Scroll position and selection are per-client. In
  tmux, one client scrolling scrolls everyone's window — *"very annoying"*
  [ARCH t=323]. Not here.
- **Scroll natively** — real scroll views, real momentum, not synthesized wheel
  escape sequences.
- **Render splits as native splits**, each with its own connection to one PTY.
- **Look like a Mac application.**

## Non-goals

⚠ The first draft listed "panes, splits and layouts" as a non-goal. That was
wrong — Superlogical supports splits, it just refuses to draw them *inside a
terminal grid*. The corrected non-goal:

- **In-band multiplexing.** We will not subdivide one terminal's grid to draw
  multiple terminals in it, and we will not draw status bars into the grid.
  Splits are native widgets; each one is its own connection to its own PTY.
- **Being a terminal emulator.** libghostty-vt is the terminal.
- **Compatibility with tmux or screen.** No control-mode shim.
- **Serving dumb clients — for now.** Superlogical plans a compatibility mode
  that puts a libghostty terminal in the middle for terminals that cannot speak
  the protocol, and is explicit that this gives up the entire advantage:
  *"architecturally it's going to be identical there"* [ARCH t=507]. We may add
  one eventually; it is not a goal, and it must never constrain the fast path.
- **A configuration language.**
- **A hosted service.** Like Superlogical's, the server is self-hosted — embedded
  in the app for local use, runnable standalone anywhere [MEM t=14].

## How we will know it works

Superlogical's published numbers are the bar. Ours should be measured the same
way and reported honestly, including where we lose.

| Goal | Measurement | Target |
| --- | --- | --- |
| G2 | Client-visible throughput while the server is artificially slowed | No client-side regression |
| G3 | `attach` sent → first frame painted, with 1 MB vs 100 MB scrollback | No meaningful difference |
| G4 | Scrollback fully restored while a `yes`-style writer runs | No dropped output |
| G5.1 | unpark → renderable, 64 MB compressed scrollback | ~200 µs excluding disk ([MEM t=369]) |
| G5.1 | Attach to a parked terminal | Served from disk; terminal stays parked |
| G5.2 | IO throughput, hot vs parked PTY | ≤10% loss when parked ([MEM t=504]) |
| G6 | Memory per **full** terminal | ~400 KB (tmux ≈ 5 MB) ([MEM t=183]) |
| G6 | Memory per **empty** terminal | Match tmux — the case Superlogical currently loses |
| G6 | 10,000 idle terminals + 200 attachments | Total RSS, p99 input latency |
| G7 | Cold launch to window visible | Measured with `os_signpost`; 148 ms Debug, and flat against scrollback |

## A note on the source material

The public description of Superlogical that reached us mentioned snapshotting via
"libgoi". No such library exists. The mechanism is the snapshot API in
libghostty-vt (`include/ghostty/vt/snapshot.h`) — and Mitchell confirms it
directly: *"the libghostty that we're built on is the only terminal technology
within a multiplexer that supports that, supports binary snapshotting. And we
have some custom wrappers around it"* [MEM t=338].

That API's shape — a CRC-protected record stream with a READY marker separating
renderable state from streamable history — is not incidental. It was built for
this. We build both parking and attach directly on it, for the same reason
Superlogical does: it makes them the same mechanism.
