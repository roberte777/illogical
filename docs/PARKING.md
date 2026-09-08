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

One thing does wake it besides a read: a resize. There is no VT on disk to
reflow or to answer a mode 2048 size report from, and a program that asked for
those reports ignores the SIGWINCH the new winsize raises — so it would never
speak, never cause the read that unparks, and never learn its window changed.
See [ARCHITECTURE.md](ARCHITECTURE.md#data-flow-resize).

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

**Encryption is XChaCha20-Poly1305, chunked** (`src/core/crypt.zig`). Compress
first, then encrypt: ciphertext does not compress.

```
"ILGPARK1" | nonce prefix (16B) | chunk | chunk | ... | terminator

chunk      = u32 LE length | ciphertext | tag (16B)
terminator = u32 LE 0      |            | tag (16B)
```

Chunked because both directions have to stay streaming. A terminal becomes
usable at READY, long before the last byte is read, and one AEAD over the whole
file would mean buffering all of it to check a single tag. At 32 KiB the
overhead is 0.05%.

Three properties, each of them something this kind of construction gets wrong
if nobody says it out loud:

- **Ordering.** A chunk's index is part of its nonce, so a chunk moved to
  another position decrypts under a different one and fails.
- **Truncation.** The terminator is an empty chunk authenticated under a
  "final" marker. A file that stops early has no valid final chunk and is
  rejected, rather than handed back as a plausible-looking shorter scrollback.
  A park that died halfway through is unreadable, which is the correct outcome.
- **Nonce reuse.** A fresh random 16-byte prefix per file. Repeating one under
  the same key is the failure that loses the plaintext outright.

The key is `park.key`, beside the store, mode 0600, generated on first run.

⚠ **What this does not buy.** Anyone who can read the store as this user can
read the key, so it is no defence against local compromise — that is the same
trust boundary the control socket already has, and not one a file mode can
move. What it buys is everything that *leaves* that boundary: backups, disk
images, a state directory in a container layer, a laptop passed on. Those stop
being plaintext, which is the whole of [MEM t=278]'s concern.

A park file written before this landed is still read: the magic decides, not
the presence of a key, so upgrading does not silently discard everybody's
parked terminals. They turn encrypted the next time they park.

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
**Migrate to hot** when a client attaches.

> "that 5 to 10% speed isn't going to matter as much when a human isn't judging
> it" — [MEM t=520]

The hysteresis matters: a client that attaches and detaches repeatedly must not
thrash threads. Promotion happens on attach, in the same call that subscribes
the client; demotion waits out `pty_park_unobserved_after`. The asymmetry is the
point — the side a person can feel is promotion.

Note what does *not* appear in the rule: PTY-read idleness. A busy terminal
nobody is watching still belongs in the poller. Ten thousand unwatched build
logs should be ten thousand registrations, not ten thousand threads, which is
why this is a separate decision from level 1's.

### How a descriptor is taken back

A hot reader is *inside* `read()`. The obvious way to wake it — close the
descriptor — is both wrong and broken. Wrong because the descriptor is being
handed to the poller, not discarded. Broken because on macOS `close` does not
return while another thread holds that same descriptor in a blocking call, so
the two wait on each other in the kernel: that was issue #28, and it is why the
daemon would not shut down while any terminal had a quiet child.

The read is interrupted instead, by a signal (`SIGUSR2`) whose handler does
nothing at all. `EINTR` comes back, the loop asks why it was woken and returns,
leaving the descriptor open with every queued byte still behind it. It is
signalled repeatedly rather than once, because delivery only interrupts whatever
syscall the thread is in at that instant — a signal arriving while it writes a
query response back to the PTY is absorbed by that write's own retry.

No byte is lost at a handover in either direction. The poller is
level-triggered, so whatever arrived while the descriptor was in flight is
reported as soon as it is registered; going the other way, the new thread's
first `read` returns what the kernel buffered all along.

### Reaping a polled child

A `waitpid` on the poller thread would stall every parked terminal on the
machine behind one child that closed its descriptors without exiting. So the
poller flags the hangup and the maintenance tick reaps it, within a tick.
Nobody is watching a polled terminal by definition, so nobody can see the delay.

### What it costs

`illogical list` has a `PTY` column: `hot` for a dedicated thread, `polled` for
one registration in the shared poller. `scripts/bench-pty.sh 100000 32 3`,
Debug build, M-series, 14 cores, median of 3:

| | hot | polled | |
| --- | --- | --- | --- |
| One PTY, 100,000 lines | 999 ms | 1001 ms | **+0.2%** |
| Eight PTYs at once, same total | 10,111 ms | 20,051 ms | **+98%** |
| Threads, no terminals | 7 | 7 | |
| Threads, 32 terminals | 38 | **7** | |

The last row is the point of the whole optimization and it is exactly flat:
thirty-two unwatched terminals cost the same seven threads as none.

The two throughput rows want reading together. Alone, a polled PTY costs
nothing measurable — well inside the 5-10% [MEM t=504] describes. Eight at once
cost twice as much, and the reason is not the poller: it is that the work a
wake-up triggers is the *VT parse*, not the `read`, and the pool has four
threads to do it on where eight terminals had eight. The cost is
`terminals / pool`, and it lands on terminals nobody is watching by definition.

The pool is why it is 2x and not 8x — see `src/core/poller.zig`. One thread was
the first shape and it pinned every unwatched terminal on the machine to a
single core.

⚠ Read the "eight at once" row carefully, because it is not only about regimes.
Eight terminals sharing 100,000 lines take **ten times** as long as one terminal
doing all of them, in *both* regimes and on the branch before this one. That is
a separate scaling problem in the daemon and it is not measured here.

---

## Level 3 — Client buffer parking

> "when a client attaches, in order to optimize the speed at which a client could
> read data from the server, we have a bunch of buffers … it adds up. It's
> kilobytes of buffers. When a client is mostly idle after a period of time,
> after the initial synchronization, we park the buffers, which is basically we
> free them." — [MEM t=551]

Kilobytes each, but multiplied by client count at our target scale. Freed after
`client_park_after` with no frame in either direction; reallocated on the next
one, which is the allocator's business rather than a state machine of ours.

Two buffers per connection: the queue the writer thread drains to the socket,
and the frame body the reader fills. Both grow to the largest thing that
connection ever carried and then keep it — a pane that streamed a build log
holds that queue capacity for as long as the window stays open.

Each is freed **by the thread that owns it**, and that is the only part of this
with any subtlety:

- The queue is freed by the writer, the next time it finds it empty. Asking is
  a flag and a wake-up. Doing it from the maintenance tick would mean freeing a
  buffer that is inside a `write` syscall.
- The read buffer goes under a `tryLock` the reader holds only between a
  frame's header and its dispatch. An idle connection is one blocked waiting
  for its next header, so it is never holding that lock — and a busy one is
  skipped rather than waited for, because one connection must not hold up the
  tick for all the others.

A connection with bytes still queued is never parked, idle clock or not: those
bytes are a stream nothing is going to send again.

### What it costs

`scripts/bench-memory.sh 20 10000 50` — 50 clients attached to a parked
terminal, Debug, M-series:

| | ours | Superlogical | tmux 3.5a |
| --- | --- | --- | --- |
| Just after attach, snapshot still in flight | 1091 KiB | — | — |
| Idle, buffers parked | **180 KiB** | 85 KiB | 157 KiB |
| Reclaimed by parking | 83% | — | — |

The first row is not a steady state, it is the snapshot itself sitting in the
pipeline; the second is what a connection actually costs to keep open.

Still twice the reference figure. What is left is not buffers — it is the two
thread stacks a connection owns, and that is A6's problem rather than this
one's.

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

⚠ **Today's code differs from the table above in two ways.**

**Park files are at `sessions/<tid>/`, not under `sessions/<sid>/terminals/`.**
`meta.json` is keyed by *session* id and `snapshot.gsnp` by *terminal* id, in
the same directory level — so session 3's name can share `sessions/3/` with
terminal 3's snapshot, which on a fresh daemon it does. The basenames never
collide, so nothing is lost; the consequence is that **nothing may `deleteTree`
a `sessions/<id>` directory**, because a recursive delete keyed by one id space
would take a file from the other with it. `park.Store.discardSessionMeta` and
`park.Store.discard` each delete named files for that reason, and then attempt a
plain `rmdir`, which fails harmlessly for as long as the other id space still
has something in there.

**`meta.json` holds `{id, name}` only — not the terminal list the table above
describes — and is written but never read back.** It is written when a session
is created and on every rename, staged through `meta.json.tmp` and renamed into
place, and discarded exactly when the session leaves the registry. Nothing
rebuilds a session from it yet.

Both gaps — the restart-read path and the layout unification, with its
orphan-file questions — belong to one follow-up and are tracked separately.

**That follow-up has one window to close before `meta.json` can be trusted on
restart.** The directory reap inside `park.Store.discard` runs on the
maintenance thread, *outside* `Server.mutex`, keyed by terminal id;
`writeSessionMeta` runs on a client's dispatch thread, under that mutex, keyed
by session id, and creates the directory and the staged file as two steps.
Where the two ids coincide — routine, given the layout above — a reap can land
between them and the write fails with `FileNotFound`. Today that is one warning
in the daemon log and nothing else, because the write is best effort and
nothing reads the file back. It becomes "the session forgot its name across a
restart" the moment something does. Unifying the layout removes the id
collision, and with it the window; `discardSessionMeta`'s own reap is not
affected, being serialized with the registry drop by the mutex.

`snapshot.gsnp` is exactly what is sent as `snapshot_chunk` payloads. One format,
one encoder, one decoder, two uses.

## Crash and restart

`meta.json` survives a daemon restart, so the session table can be rebuilt — the
*intent*; nothing reads it back yet (see the note above). The *children* cannot
be reattached — their controlling PTY died with the daemon — but the last known
screen is still there to show.

Surviving a restart with live children needs the PTY masters held by something
that outlives the daemon (fd passing, or re-exec preserving fds). Out of scope
for now.

## Tuning

| Knob | Default | Meaning |
| --- | --- | --- |
| `park_after` | 60 s | PTY-read idle before terminal parking [MEM t=246] |
| `compress_after` | 250 ms | idle before an incremental compression step |
| `pty_park_unobserved_after` | 5 s | delay before demoting an unwatched PTY |
| `client_park_after` | 10 s | quiet time before a client's buffers are freed |
| `max_snapshot_bytes` | 256 MiB | refuse to park beyond this; stay resident |

The first three and the fourth are also `illogicald` flags —  `--park-after`,
`--pty-park-after`, `--client-park-after` — which is how the benchmarks pin one
behaviour at a time.

## Measuring it

⚠ **Use `phys_footprint`, not RSS.** libghostty releases compressed scrollback
with `MADV_FREE_REUSABLE`, which on macOS leaves the pages counted in RSS until
there is memory pressure. Measured with `ps -o rss`, compression and parking
appear to do *nothing*; measured with `phys_footprint` the win is plain. This is
also the metric Superlogical's own charts report, so it is the only way to
compare honestly. `scripts/bench-memory.sh` reads it from `vmmap --summary`.

⚠ **Measure a release build.** This is not a refinement. It is the difference
between 90 KiB and 1743 KiB for an empty terminal, and every figure in this
document was wrong for a while because of it.

Zig fills `undefined` with `0xAA` in a debug build, so every buffer a debug
binary declares gets written before it is ever used. libghostty preheats four
~390 KiB pages per terminal *because* they are demand-paged — "this only costs
us address space" — and the debug fill makes all four resident. Our own reader
buffer went the same way. Everything published to compare against is a release
build, so ours has to be; `scripts/bench-memory.sh` builds one itself rather
than trusting whatever is in `zig-out`.

Two more things a zero in the table below does not mean:

- **Freeing is not returning.** Parking frees a terminal outright and level 3
  frees a client's buffers; the tests assert both directly, on capacity.
  Whether those pages go back to the kernel is the allocator's decision — the
  debug allocator hands them back, the release one keeps them for the next
  caller.
- **A5 gets there first.** By the time a fill has settled, scrollback
  compression has already released the physical pages, so parking has little
  left to reclaim in this metric. The live row is an already-compressed
  terminal, not a raw one.

Results from `scripts/bench-memory.sh 20 10000 50`, ReleaseFast, M-series,
against the reference figures in [RESEARCH.md](RESEARCH.md#7-numbers):

| | ours | Superlogical | tmux 3.5a |
| --- | --- | --- | --- |
| Server start, no terminals | **1.23 MiB** | 10.6 MiB | 2.50 MiB |
| Per empty 80×24 terminal | 94 KiB | 68 KiB | **15 KiB** |
| Per client connection, idle | **45 KiB** | 85 KiB | 157 KiB |
| Per filled 10,000-line terminal, settled | **390 KiB** | 407 KiB | 4.89 MiB |
| Snapshot on disk | 32 KiB | — | — |

The filled row moves a few percent between runs — 380 to 407 across two — because
where compression has got to when the footprint settles is not deterministic.
The others are stable to a kilobyte.

The two rows Superlogical loses are the two that scale, which is the same shape
their own numbers have. We lose the empty-terminal row to tmux by 6×, and most
of what is in it is libghostty's, not ours: one preheated page that gets touched
and the terminal struct behind it.

The filled row is a *settled* measurement — the fill and A5's compression race
each other, and an earlier version of this table stopped the clock at whichever
of them happened to win, reporting 1876 KiB from a debug build and 9979 KiB from
a release one for the same code. Neither was wrong; they were answers to
different questions.

Still to measure:

- Park wall time vs. scrollback size.
- **Unpark → `ready()` returns.** The headline latency; target ~200 µs at 64 MB
  excluding disk.
- Full history restore time (background; must not regress interactivity).
