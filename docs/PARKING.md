# Parking

> **Revised 2026-09-04.** The first draft described one mechanism. There are
> **three**, they are independent, and they have different triggers. See
> [RESEARCH.md §6](RESEARCH.md#6-three-levels-of-parking).

Idle terminals should cost approximately nothing. Not "less"; nothing. This is
the optimization that makes the target scale — *"hundreds of thousands of agents
or more"* [MEM t=139] — reachable at all.

Mitchell's framing: *"four things, maybe three or four things I want to talk
about … I call it parking and unparking"* [MEM t=231]. The three are the
terminal, the PTY, and the client's buffers.

---

## Level 1 — Terminal parking

Snapshot the terminal state to disk and free it from memory.

### What "idle" means

⚠ **PTY reads only.** Not keystrokes, not attachment, not focus.

> "When I say idle, I'm really talking about read bytes on the PTY, bytes that
> would update the terminal emulator screen or history state … You could still
> type keys and send data right to the PTY, but if that isn't updating the actual
> terminal emulator state, the PTY read, we don't need to unpark this."
> — [MEM t=246, t=296]

The consequence is the whole point:

> "this parking terminals works even when clients are attached. If I have my
> Superlogical app open and I have 10 terminals, but all 10 terminals are sitting
> on idle shells, all 10 terminals are going to be parked. They're going to cost
> nothing in memory." — [MEM t=311]

So a terminal that is attached, focused, and being typed into is **still parked**
if the child is producing no output. Our `park.shouldPark` must key on
`last_pty_read_ns`, never on a general "activity" timestamp.

### Lifecycle

```
                     PTY read
        ┌────────────────────────────────┐
        │                                │
        ▼                                │
   ┌─────────┐  60s no PTY reads  ┌──────┴──────────┐
   │  live   │───────────────────►│     parked      │
   └─────────┘                    └─────────────────┘
        ▲                                │
        │                                │ PTY read arrives
        │       history restored         ▼
        │                       ┌──────────────────┐
        └───────────────────────│   rehydrating    │
                                └──────────────────┘

   attach ──────────────────────────────► served from disk,
                                          terminal stays parked
```

**live** — state in memory, PTY hot, output fanned out.

**parked** — `snapshot.gsnp` on disk, terminal freed. *"The cost of a terminal
that's parked to disk is only basically the minimal resources to monitor the file
descriptor so that it could unpark"* [MEM t=278]. The child never notices.

**rehydrating** — READY decoded, so the terminal accepts output and serves
attaches immediately. History pages still restoring in the background.

### Parking

1. Encode with `ghostty_snapshot_encode` to `snapshot.gsnp.tmp`.
2. Compress, then encrypt (see below).
3. `fsync`, then `rename` over `snapshot.gsnp`. A crash mid-park leaves the
   previous good snapshot in place.
4. Free the in-memory terminal.
5. Migrate the PTY fd to the shared poller — **level 2**, below.

The terminal must not be mutated during encode, so the terminal's lock is held
for the duration. Encode cost scales with scrollback, hence a pool thread and
`max_snapshot_bytes` as an escape hatch.

### Unparking

Triggered by a PTY read. **Not by attach** — see below.

1. `ghostty_snapshot_decoder_new` over a streaming reader on the file.
2. `ghostty_snapshot_decoder_ready()` → renderable terminal. **Usable here.**
   Pending PTY bytes are applied.
3. `ghostty_snapshot_decoder_next()` on a background thread, prepending history
   newest-first, until `GHOSTTY_NO_VALUE`.

Step 2 is bounded by the active screen, not by scrollback. Measured by
Superlogical at **~200 µs for a 64 MB compressed scrollback, excluding disk
I/O** [MEM t=369] — and he is explicit that in practice it is *"really bound by
your disk speed"* [MEM t=352].

Decode is streaming: *"we can decompress and decode streaming from disk. We
don't have to wait for all of it to be in memory"* [MEM t=384]. Use the
`GhosttyReader` callback form, not `new_buf`.

> Do not cite "20 µs" from [MEM t=384]; the captions are ambiguous there. See
> [RESEARCH.md §6.1](RESEARCH.md#61-terminal-parking).

### Attach never unparks

> "if a client connects to a parked terminal, we actually stream the binary
> snapshot from disk directly to the client. We don't need to unpark the terminal
> because a client attached. So if you have a client that's just hammering attach
> attach attach attach, on off on off on off, the server is just on disk and
> we're just streaming from disk." — [MEM t=660]

This works because the park file and the attach payload are the same bytes. It is
the reason not to invent a separate attach format.

Implementation: on attach to a parked terminal, `sendfile`/`splice` the park file
into the client connection framed as `snapshot_chunk`, and subscribe the client
to future output. The terminal unparks only when a PTY read actually arrives.

### Continuation state

A terminal can be parked mid-escape-sequence. The snapshot's `CONTINUATION`
record carries the unfinished VT parser and UTF-8 decoder state, so unparking
resumes *inside* the sequence.

Tracking must be enabled **before** the input that produced that state was
written — there is no retroactive path. So the server enables it on every
terminal at creation, unconditionally.

### Compression and encryption

Mitchell confirms both and names neither:

> "there's encryption and other security involved there to prevent — there's
> often secrets in scrollback, so we have to protect against that. We'll talk
> about that another time." — [MEM t=278]

**We use deflate, not zstd.** Zig 0.16 ships a zstd *decompressor* only, and a C
zstd would be this project's first non-ghostty native dependency. It sits behind
one constant (`park.Store.Container`) so swapping it later is a local change.
Measured: a filled 10,000-line terminal parks to **32 KiB** on disk.

**Encryption is not implemented.** Scrollback holds secrets and the park file is
plaintext on disk today. This is the one part of parking that is a genuine gap
rather than a deferred refinement — see [ROADMAP.md](ROADMAP.md).

⚠ Do not use LZ4 here by analogy with level-1.5 below. That is a different
problem: in-memory pages need infallible, instant decompression; on-disk
snapshots want ratio.

---

## Level 1.5 — Scrollback compression (not parking, but adjacent)

Runs while the terminal is **live**, and is already implemented in libghostty.
Non-active, non-viewport scrollback pages are LZ4-compressed in place:

- **70–90% resident memory reduction** for compressed pages [GH #13264]
- Physical pages released with `MADV_DONTNEED` / `MADV_FREE_REUSABLE`, virtual
  mapping retained — so **decompression cannot fail**
- macOS and 64-bit Linux only
- Ghostty triggers it after 250 ms idle

We must schedule it ourselves — libghostty-vt creates no timers or threads:

```c
ghostty_terminal_compression_activity(term, &token);   // changed? restart idle timer
ghostty_terminal_compress(term, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &r);
// PENDING -> step again while idle; COMPLETE -> wait for token change
```

Never call `MODE_FULL` on a hot path — it *"can stall on large scrollback
buffers"*. Serialize against writes, rendering and search.

---

## Level 2 — PTY parking

The PTY file descriptor moves between two IO regimes. Full rationale in
[ARCHITECTURE.md](ARCHITECTURE.md#server-io-two-regimes-per-pty).

| | Hot | Parked |
| --- | --- | --- |
| Mechanism | dedicated OS thread blocked on `read()` | shared kqueue/epoll poller |
| Throughput | baseline | 5–10% worse [MEM t=504] |
| Cost | kernel thread + stack | one fd registration |

**Migrate to parked** when the terminal parks, or when no client is observing it.
**Migrate to hot** when a client attaches to a live terminal producing output.

> "that 5 to 10% speed isn't going to matter as much when a human isn't judging
> it" — [MEM t=520]

The hysteresis matters: a client that attaches and detaches repeatedly must not
thrash threads. Migrate to hot on attach; migrate back on a delay.

---

## Level 3 — Client buffer parking

> "when a client attaches, in order to optimize the speed at which a client could
> read data from the server, we have a bunch of buffers … it adds up. It's
> kilobytes of buffers. When a client is mostly idle after a period of time,
> after the initial synchronization, we park the buffers, which is basically we
> free them." — [MEM t=551]

Kilobytes each, but multiplied by client count at our target scale. Free after an
idle period past initial sync; reallocate on activity.

---

## On-disk layout

```
$XDG_STATE_HOME/illogical/
  server.sock
  server.pid
  sessions/<sid>/meta.json                    session name, terminal list
  sessions/<sid>/terminals/<tid>/meta.json    argv, cwd, size, child pid
  sessions/<sid>/terminals/<tid>/snapshot.gsnp
  sessions/<sid>/terminals/<tid>/snapshot.gsnp.tmp
```

`snapshot.gsnp` is exactly what is sent as `snapshot_chunk` payloads. One format,
one encoder, one decoder, two uses.

## Crash and restart

`meta.json` survives a daemon restart, so the session table can be rebuilt. The
*children* cannot be reattached — their controlling PTY died with the daemon —
but the last known screen is still there to show.

Surviving a restart with live children needs the PTY masters held by something
that outlives the daemon (fd passing, or re-exec preserving fds). Out of scope
for now.

## Tuning

| Knob | Default | Meaning |
| --- | --- | --- |
| `park_after` | 60 s | PTY-read idle before terminal parking [MEM t=246] |
| `compress_after` | 250 ms | idle before an incremental compression step |
| `pty_park_unobserved_after` | 5 s | delay before demoting an unwatched PTY |
| `max_snapshot_bytes` | 256 MiB | refuse to park beyond this; stay resident |

## Measuring it

⚠ **Use `phys_footprint`, not RSS.** libghostty releases compressed scrollback
with `MADV_FREE_REUSABLE`, which on macOS leaves the pages counted in RSS until
there is memory pressure. Measured with `ps -o rss`, compression and parking
appear to do *nothing*; measured with `phys_footprint` the win is plain. This is
also the metric Superlogical's own charts report, so it is the only way to
compare honestly. `scripts/bench-memory.sh` reads it from `vmmap --summary`.

Results from `scripts/bench-memory.sh 20 10000` (macOS, Apple M4 Max), against
the reference figures in [RESEARCH.md](RESEARCH.md#7-numbers):

| | ours | Superlogical | tmux 3.5a |
| --- | --- | --- | --- |
| Server start, no terminals | **2.38 MiB** | 10.6 MiB | 2.50 MiB |
| Per filled 10,000-line terminal, live | 1867 KiB | 407 KiB | 4.89 MiB |
| Per filled 10,000-line terminal, parked | **374 KiB** | — | — |
| Snapshot on disk | 32 KiB | — | — |
| Reclaimed by parking | 79% | — | — |

Read this carefully before claiming a win. Superlogical's 407 KiB is labelled
"per filled terminal" and does not say whether it was parked. Our *parked*
number lands next to it and our *live* number is 4.5× worse, so the honest
reading is either that their figure is a settled/parked measurement too, or that
their live representation is leaner than ours. We do not know which.

Still to measure:

- Park wall time vs. scrollback size.
- **Unpark → `ready()` returns.** The headline latency; target ~200 µs at 64 MB
  excluding disk.
- Full history restore time (background; must not regress interactivity).
- IO throughput, hot vs parked PTY. Target ≤10% loss.
- Thread count vs terminal count. Should flatten, not track.
