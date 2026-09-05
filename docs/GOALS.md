# Goals

`illogical` is a terminal multiplexer built around one bet: **the server should
never render, and the client should never parse a byte it did not have to.**

Everything below follows from that.

## What it is

A session server (`illogicald`) owns PTYs and terminal state. Native clients
attach to it, get the current screen essentially instantly, then get scrollback
streamed in behind that. The clients are real terminal emulators — not TUIs
drawing inside somebody else's terminal.

This is a clean-room build against the public description of Superlogical
(Mitchell Hashimoto / superlogical). We are not reading their source; we are
building the same idea on the same public foundation, libghostty-vt.

## Goals

### G1 — Sessions outlive clients

Close the laptop, quit the app, lose the network: the session keeps running.
Reattaching is the normal case, not recovery.

### G2 — The server ships unprocessed output

The wire carries the exact bytes the child process wrote. The server does not
re-render a screen into a diff, does not normalize escape sequences, and does
not decide what the client's terminal can display. Clients are modern terminal
emulators and can be trusted with the raw stream.

This is what makes correctness tractable: there is exactly one VT
implementation in the system (libghostty-vt), and both sides run it.

### G3 — Attach paints the current screen immediately

Attaching must not replay history to reconstruct the screen. The server keeps a
live terminal per session, encodes it with `ghostty_snapshot_encode`, and the
client decodes only through the snapshot's `READY` marker before painting.

Budget: **first frame within one round trip plus decode**, independent of how
much scrollback the session has.

### G4 — Scrollback arrives after, without blocking anything

History pages follow `READY`, newest first, and are prepended to the already-
rendered terminal. Live output continues to apply while they arrive. The user
sees a working terminal the whole time and scrollback simply gets deeper.

### G5 — Idle sessions cost nothing

A session with no output for 60s is *parked*: its state is snapshotted to disk
and its in-memory terminal is released. The PTY fd stays registered, so the next
byte of output unparks it. Target: **rehydrate-to-renderable in well under a
millisecond**, and idle RSS per session in the kilobytes, not megabytes.

This is what makes G6 possible.

### G6 — Hundreds of sessions and hundreds of attachments

The design target is agent workloads: many terminals, mostly idle, occasionally
bursting, with more clients attached than a human would ever open. Memory must
scale with *active* sessions, not total sessions.

### G7 — Native clients, one per platform

Each client is written in its platform's native toolkit and powered by
libghostty-vt. macOS is first: Swift, AppKit/SwiftUI, Metal.

The Mac client specifically must:

- **Launch in half a bounce.** The window and chrome appear before any network
  work completes; the terminal fills in as the snapshot arrives.
- **Switch sessions from a dropdown**, showing residency (live / parked) inline.
- **Connect to remote hosts** over SSH with the same protocol.
- **Scroll natively** — real scroll views, real momentum, real trackpad feel —
  not wheel escape sequences synthesized into the PTY.
- **Look like a Mac application**, not a cross-platform terminal wearing a
  traffic-light costume.

## Non-goals

- **Panes, splits and layouts inside a session.** The multiplexer multiplexes
  *sessions*; window management belongs to the client and to the OS.
- **Being a terminal emulator.** libghostty-vt is the terminal. We do not fix
  VT bugs here.
- **Backwards compatibility with tmux or screen.** No control-mode shim, no
  `.tmux.conf` translation.
- **Serving legacy clients.** A client that cannot run a modern VT engine is
  out of scope; that constraint is what buys G2.
- **A configuration language.** Config is a small, boring, declarative file.

## How we will know it works

| Goal | Measurement |
| --- | --- |
| G3 | Time from `attach` sent to first frame painted, with 1 MB and 100 MB of scrollback. Must not differ meaningfully. |
| G4 | Scrollback fully restored while a `yes`-style writer keeps running, with no dropped output. |
| G5 | `park` → `unpark` → renderable, measured in µs. Idle RSS per parked session. |
| G6 | 500 idle sessions + 200 attachments on a laptop: total RSS and p99 input latency. |
| G7 | Cold launch to window visible, measured with `os_signpost`. |

## A note on the source material

The public description of Superlogical mentions snapshotting via "libgoi". We
found no such library. What does exist, and does exactly this, is the snapshot
API in libghostty-vt (`include/ghostty/vt/snapshot.h`) — a CRC-protected binary
record stream with an explicit `READY` marker separating renderable state from
history, and a decoder that can restore the first part and stream the rest.

That API is so precisely shaped for park/unpark and for attach that we have
built both on it directly. If the name was a mishearing of something else, the
design here stands on its own merits regardless.
