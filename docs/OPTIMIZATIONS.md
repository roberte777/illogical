# The optimization catalogue

Every performance technique we know Superlogical uses, plus the ones libghostty
already implements that we get by building on it. Each entry says what it is, why
it works, what it costs, and whether we are adopting it.

Sources are keyed as in [RESEARCH.md](RESEARCH.md): **[ARCH]** and **[MEM]** are
Mitchell's architecture and memory videos, **[GH]** is ghostty's own commit
history. Commit hashes refer to `vendor/ghostty`.

**Status legend**

| | |
| --- | --- |
| **Adopt** | Do this, as described |
| **Adapt** | Do this, with a stated modification |
| **Free** | libghostty already does it; we get it by using the library correctly |
| **Defer** | Right idea, wrong milestone |
| **Ours** | Not from Superlogical — our own call |

---

## A. Server memory

The headline, measured (macOS 26.6.2, M4 Max, `phys_footprint`, charts attached
to [X 2095218879714996629]):

| | Superlogical | tmux 3.5a |
| --- | --- | --- |
| Per terminal filled with 10,000 lines | **407 KiB** | 4.89 MiB |
| Per client connection (50 filled terminals) | **85 KiB** | 157 KiB |
| Per empty 80×24 terminal | 68 KiB | **15 KiB** |
| Server start, one session | 10.6 MiB | **2.50 MiB** |

Note that tmux wins the two fixed-cost rows. This section is what buys the two
that scale. See [RESEARCH.md §7](RESEARCH.md#7-numbers).

### A1. Terminal parking — snapshot idle terminals to disk

**Status: Done.** Landed in M4.

After 60 s with no PTY *read* activity, encode the entire terminal state with
`ghostty_snapshot_encode`, write it to disk, and free the in-memory terminal. The
only remaining cost is whatever it takes to watch the file descriptor
[MEM t=246].

Two details that are easy to get wrong:

- **"Idle" means PTY reads only.** Keystrokes do not count. Input that produces
  no output leaves the terminal parked [MEM t=296]. This is what makes parking
  work *while clients are attached* — ten open windows sitting at idle shells are
  ten parked terminals.
- **Unpark is streaming.** Decompress and decode straight off disk without
  waiting for the whole file [MEM t=384]. ~200 µs for a 64 MB compressed
  scrollback, excluding disk I/O [MEM t=369].

### A2. Attach to a parked terminal without unparking it

**Status: Done.** Landed in M4, with a test asserting the terminal is still
parked after serving a client a full, decodable snapshot.

The park file and the attach payload are the same bytes, so a client attaching to
a parked terminal is served **straight from disk**. The terminal never comes back
into memory. A client cycling attach/detach never wakes anything [MEM t=660].

This is the single strongest argument against inventing a separate wire format
for attach, and it falls out for free if you do not.

### A3. PTY parking — migrate fds between a thread and a poller

**Status: Done.** Thread-per-PTY landed in M1, migration in M4.

Counter-intuitive and load-bearing:

> "the fastest way to get IO performance is to put each PTY in its own dedicated
> OS thread blocked on the read syscall … if you throw multiple PTY FDs into
> kqueue or epoll or io_uring, there is a very noticeable hit to latency, to IO
> throughput." — [MEM t=399]

But threads cost too much at thousands of terminals [MEM t=443]. So each PTY
lives in one of two regimes and moves between them:

| | Hot | Parked |
| --- | --- | --- |
| Mechanism | dedicated OS thread blocked on `read()` | fd registered in one shared kqueue/epoll thread |
| IO throughput | baseline | **5–10% worse** [MEM t=504] |
| Cost per fd | a kernel thread + its stack | an fd registration |

Migrate to parked when the terminal is parked, **or** when no client is observing
it — "that 5 to 10% speed isn't going to matter as much when a human isn't
judging it" [MEM t=504].

> **This invalidates the obvious design.** Our first architecture draft had a
> single libxev loop owning every PTY. That is exactly the configuration
> Mitchell says he measured and rejected. An event loop is still the right tool
> for the *parked* poller and for the control socket; it must not be the hot
> path.

The awkward part is not deciding to migrate, it is getting the descriptor back.
A hot reader is *inside* `read()`, and the obvious wake — close the descriptor —
is both wrong (it is about to be handed to the poller, not thrown away) and
broken: on macOS `close` does not return while another thread holds that same
descriptor in a blocking call, so the two wait on each other in the kernel. That
was issue #28, and it is why `illogicald` would not shut down while any terminal
had a quiet child.

The read is **interrupted** instead, by a signal whose handler does nothing at
all. `EINTR` comes back, the loop checks why it was woken, and returns leaving
the descriptor open with every byte still queued behind it. The signal is sent
repeatedly rather than once, because delivery only interrupts whichever syscall
the thread is in at that instant — one that lands while it is writing a query
response back to the PTY is absorbed by that write's own retry.

Nothing is dropped at a handover. The poller is level-triggered, so bytes that
arrived while the descriptor was in flight are reported the moment it is
registered; the reverse handover is a `read` on a descriptor the kernel has been
filling all along.

Two consequences worth stating:

- **The hysteresis is one-sided.** Promotion happens on attach, synchronously,
  in the same call that subscribes the client. Demotion waits out
  `pty_park_unobserved_after`. Someone clicking between tabs must not spawn and
  join a thread each time, and the side a person can feel is promotion.
- **A parked terminal's child still gets reaped.** The poller thread is shared,
  so it cannot sit in `waitpid`; it flags the hangup and the maintenance tick
  collects it within a tick. Nobody is watching a polled terminal by definition.

`illogical list` grew a `PTY` column reading `hot` or `polled`. "How many
terminals still cost a thread" is the question this optimization exists to
answer, and it should not need a debugger.

**The poller is a small pool, not one thread**, and that was measured rather
than assumed. The work a wake-up triggers is the VT parse, not the `read`, so
one thread serialises it: eight busy terminals ran **7.8× slower** than eight
dedicated readers, which is not a 5-10% trade, it is one core's worth of
throughput. Four threads bring the same case to 2×, exactly `terminals / pool`.
Thread count stays a constant either way, which is the property that matters —
and above the core count the pool is the *better* regime anyway, since ten
thousand runnable threads is worse than a bounded pool whatever the fd cost.

Measured, Debug, M-series, `scripts/bench-pty.sh`:

| | hot | polled | |
| --- | --- | --- | --- |
| One PTY, 100,000 lines | 999 ms | 1001 ms | +0.2% |
| Eight PTYs, same total | 10,111 ms | 20,051 ms | +98% |
| Threads for 32 terminals | 38 | **7** | flat |

It shows up in memory too, and by more than the fd accounting suggests. A
parked terminal cost **356 KiB** before this and **192 KiB** after, same
machine — the difference is the reader thread's touched stack, which a parked
terminal no longer has.

### A4. Client buffer parking

**Status: Done.** Landed in M4.

Per-client pipeline buffers are kilobyte-scale but multiply by client count. Free
them once a client has been idle past its initial sync; reallocate on activity
[MEM t=551].

Two per connection: the queue F2 drains to the socket, and the frame body the
reader fills. Both grow to the largest thing that connection ever carried and
then hold it — a pane that streamed a build log keeps that queue capacity for as
long as the window stays open.

Each is freed by the thread that owns it, which is the only part with any
subtlety to it. `parkBuffers` sets a flag and the *writer* frees the queue the
next time it finds it empty; freeing it from the maintenance thread would mean
freeing a buffer that is inside a `write` syscall. The read buffer goes under a
`tryLock` the reader holds only between a frame's header and its dispatch — so
an idle connection, which is one blocked waiting for its next header, is never
holding it.

Measured with `scripts/bench-memory.sh 20 10000 50`: 50 clients attached to a
parked terminal, Debug, M-series.

| | |
| --- | --- |
| Just after attach, snapshot still in the pipeline | 1091 KiB/client |
| Idle, buffers parked | **180 KiB/client** |
| Reclaimed | 83% |

Still twice Superlogical's 85 KiB. What is left is not buffers — it is the two
thread stacks a connection owns, which is A6's problem rather than this one's.

### A5. Scrollback page compression (LZ4, in memory)

**Status: Done.** Landed in M4 — the server's maintenance tick drives the
activity token and incremental steps. Note the measurement trap: the win is
invisible in RSS and only shows in `phys_footprint`.

Distinct from parking and it runs while the terminal is *live*. libghostty
compresses non-active, non-viewport scrollback pages in place:

- **70–90% reduction in resident memory** for compressed pages [GH `7e02af879`, #13264]
- Codec is **LZ4** [GH `9a4bd2120`]
- Ghostty raised its default scrollback limit 10 MB → 50 MB on the strength of it
- Physical memory is released with `MADV_DONTNEED` (Linux) / `MADV_FREE_REUSABLE`
  (Darwin) while the **virtual** mapping is retained — which makes decompression
  *infallible*, since the OS has already committed the address space
- macOS and 64-bit Linux only
- In Ghostty, compression is triggered after **250 ms** of idle [SBC]

libghostty-vt does not schedule this for us: *"libghostty-vt does not create a
timer or background thread"* (`example/c-vt-compression`). We must call it:

```c
ghostty_terminal_compression_activity(term, &token);  // cache; restart idle timer on change
ghostty_terminal_compress(term, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result);
// PENDING -> call again while still idle; COMPLETE -> wait for the token to change
```

Incremental mode does bounded work suitable for an idle callback. Full mode
*"can stall on large scrollback buffers"* — never call it on the hot path.
Compression is not thread-safe with other terminal access and must be serialized
against writes, rendering and search.

Ghostty also has `renderer: avoid starving scrollback compression`
[GH `25e624569`] — worth remembering when we schedule ours.

### A6. Per-terminal fixed costs

**Status: Done** for M4, and permanently ongoing. This is the one where the
reference implementation currently *loses*.

tmux costs 15 KiB per empty terminal; Superlogical costs 68 KiB. Mitchell
concedes it and says it is fixable [MEM t=197]. Since we are starting fresh we
should try to win it outright rather than inherit the deficit. It is all fixed
overhead, and libghostty has been chipping at exactly this:

- Dynamic palette **shares the built-in default** instead of copying 256 entries
  per terminal [GH `d1cd56a56`]
- Pages **initialize from zeroed memory** and cache-line align their cells
  [GH `d2ff6d77a`] — a fresh terminal needs no `memset`, so session creation is
  cheap
- Hash maps and ref-counted sets also initialize from zeroed memory
  [GH `c0a4f80d8`]
- Bitmap allocator marks free chunks with **zero** bits [GH `ffe015ee5`] — same
  trick, same reason

The lesson for us: anything we allocate per session must also be zero-initialized
or lazy. At 10,000 sessions, a 4 KB eager buffer is 40 MB.

#### What we found when we went looking

**The measurement was wrong before the code was.** Every memory figure in this
project was taken from a debug build, and a debug build is not off by a little.
Zig fills `undefined` with `0xAA`, so every buffer a debug binary declares is
written before it is used — including the four ~390 KiB pages libghostty
preheats per terminal *precisely because* they are demand-paged and "only cost
us address space". An empty terminal measures **1743 KiB debug and 90 KiB
release**. Everything we compare against is a release build.
`scripts/bench-memory.sh` builds one now.

Three costs were ours, and all three are gone:

- **A 64 KiB PTY read buffer that no read could ever fill.** A macOS pty master
  returns at most 1024 bytes per read whatever you give it — 118,000 reads of a
  child writing 13 MB flat out, mean 115 bytes, maximum 1024 — because that is
  what its output queue holds. Linux is larger and the same shape. Now 16 KiB.
- **64 KiB of stack, permanently, per client that ever attached.** The buffer
  between the park store and the decompressor sat on the stack of whichever
  thread was attaching, so a connection that attached once dirtied 64 KiB of its
  reader's stack for as long as it lived. On the heap it lasts as long as the
  attach does.
- **16 MiB of stack reservation per thread.** Address space rather than memory,
  but two threads per client at ten thousand clients is 320 GiB of it. Now
  512 KiB, against a measured high-water mark of 32 KiB.

Measured, ReleaseFast, same machine, before and after:

| | before | after |
| --- | --- | --- |
| Per hot terminal | 176 KiB | **155 KiB** |
| Per client connection | 87 KiB | **59 KiB** |

And against the reference figures, from `scripts/bench-memory.sh 20 10000 50`:

| | ours | Superlogical | tmux 3.5a |
| --- | --- | --- | --- |
| Server start, no terminals | **1.27 MiB** | 10.6 MiB | 2.50 MiB |
| Per empty 80×24 terminal | 90 KiB | 68 KiB | **15 KiB** |
| Per client connection, idle | **46 KiB** | 85 KiB | 157 KiB |

We win the connection row and lose the empty-terminal row, which is the row this
section was written about. Most of what is in it is not ours: a libghostty
terminal and the one preheated page that gets touched. Winning it outright needs
either a smaller page for small terminals or lazy page allocation, and both are
upstream's to make.

### A7. Position-independent page memory

**Status: Free**, and it is the reason everything else in section A works.

> "our memory is directly serializable because we only store **pointer offsets,
> not full pointers**, so we need this to be able to do disk offload (can write
> compressed data direct to disk)"
> — [MASTO], 2026-07-09 *(verbatim)*

Ghostty's terminal pages contain no absolute pointers. Consequences that the rest
of this document quietly depends on:

- Encoding a snapshot is closer to a **copy** than to a graph traversal, which is
  why a 60-second park interval is affordable.
- **Compressed pages can be written straight to disk** without a decompress /
  re-serialize round trip.
- Restoring is a read into an arena plus offset fix-ups — no pointer patching.

If we ever add our own per-terminal data structures that hang off a page, they
must obey the same rule or they will not survive a park.

---

## B. The snapshot codec

We inherit all of this by using the format rather than inventing one. It is worth
knowing what we are getting.

### B1. The READY marker

**Status: Free.** The whole design rests on it.

The format is deliberately ordered so a terminal becomes usable as early as
possible: `TERMINAL → SCREEN → PAGE… → CONTINUATION → READY → HISTORY → PAGE… →
FINISH`. Everything before READY is what you need to render; everything after is
scrollback, newest-to-oldest so it can be prepended as it arrives.

> "The snapshot is purposely laid out in a way that prioritizes making a terminal
> functional as quickly as possible."
> — `src/terminal/snapshot/main.zig`

### B2. Wire and codec optimizations already in the format

**Status: Free.** [GH `d351d9ce0`, #13566] reports **~30× smaller wire size and
~45× faster encode/decode** for 1 MB of VT input with full scrollback, versus the
format's own first version:

- **8-byte grid cells** — one 64-bit word whose layout deliberately matches the
  native cell. Was 16 bytes, of which 97% were zero.
- **Variable-width cells** — each row declares whether its cells transport in
  1, 2, 4 or 8 bytes, chosen by the widest cell in that row.
- **Trailing blanks are not written** — rows declare an encoded cell count.
- **Hardware CRC32C** — inline asm on aarch64/x86_64. Zig's stdlib manages
  0.56 GB/s; the hardware path hits 10 GB/s.
- **Vectorized grid cell encode and decode** [GH `973f619a2`, `2aaad3ca9`]
- **Single-pass style entry codec**; style remap tables skipped entirely for
  pages with no styles [GH `1359973ae`, `47a518262`]
- **Stack fallback for record scratch** [GH `ee8095d37`] — no heap traffic for
  small records

### B3. Continuation tracking

**Status: Free**, but must be enabled at session creation. Milestone M1.

A terminal can be parked mid-escape-sequence. The `CONTINUATION` record carries
the minimum bytes needed to bring a grounded parser back to the identical state,
so unparking resumes *inside* the sequence [GH `f5880782f`, #13544].

The implementation is itself an optimization worth noting: when the parser is in
a non-ground state it does a **backwards vectorized search** for the last `ESC`
in the input slice; in the ground state it only needs to find the lead UTF-8
byte. Cost when tracking is off is nil, by design.

**Tracking must be on before the input that produced the unfinished state is
written.** There is no retroactive path. So we enable it on every session,
unconditionally, at creation.

---

## C. The wire protocol

### C1. Raw PTY bytes, not screen diffs

**Status: Adopt.** Milestone M2. This is the architecture, not an optimization,
but it is where the performance comes from.

tmux and zellij maintain a screen and send diffs. Superlogical tees raw PTY bytes
to every client "like SSH" [ARCH t=203]. The server's parse speed stops being the
client's problem:

> "If the server actually starts parsing slower, the client is still parsing at
> full speed. It doesn't matter." — [ARCH t=255]

It also means the fan-out path is a `write` of a byte slice N times — no
per-client rendering, no per-client diff state.

### C2. One writer, many readers

**Status: Adopt.** Milestone M2.

Input is serialized to the authoritative server; output fans out. The clients are
*"synchronized finite state machines"*, and a client that desyncs simply resets
and replays the attach handshake [ARCH t=273, t=356]. There is no reconciliation
protocol to get wrong, and no per-client server-side screen state to maintain.

### C3. Per-client viewport

**Status: Done** for scroll position, landed in M3. Selection is still to come.

Scroll position and selection live entirely in the client [ARCH t=323]. The
server stores nothing per client except its buffers (see A4) and its subscription
set. This is both a correctness win over tmux and a memory win.

Concretely: the client calls `ghostty_terminal_scroll_viewport` on its own
replica and tells the server nothing. Two clients attached to one terminal
scroll independently, and neither can move the other's window.

---

## D. Client rendering

### D1. Two-phase render state update

**Status: Done.** Landed in M3.

`ghostty_render_state_begin_update` needs exclusive terminal access;
`ghostty_render_state_end_update` completes using only render-state memory. A
renderer locks, begins, **unlocks**, then finishes — so the IO thread keeps
feeding the terminal while the frame is assembled.

> "This allows the render state to minimally impact terminal IO performance and
> also allows the renderer to be safely multi-threaded." — `render.h`

### D2. Two-layer dirty tracking

**Status: Done.** Landed in M3. Worth 1.2 ms → 0.03 ms of CPU per frame on a
200×50 grid: a full rebuild versus one dirty row.

Global dirty state (clean / partially dirty / fully dirty) plus per-row dirty
flags, with dedicated dirty-row iteration [GH `ad6e72ddc`]. The renderer redraws
only changed rows.

The API's own warning is worth repeating: the two layers are independent, and
`update` does not clear either. Use `ghostty_render_state_clean()` after a
successful frame.

### D2a. No geometry for cell backgrounds

**Status: Adopt.** Landed in M3.

Both background passes are a single full-screen triangle. The fragment shader
derives its grid position from the fragment coordinate and indexes a flat
colour buffer, so a screen of backgrounds costs two triangles and four bytes
per cell rather than a quad per cell. Text is one instanced 32-byte quad per
glyph — the size libghostty settled on, and worth holding to: a full screen
with underlines is tens of thousands of them per frame.

### D2b. Shared, incrementally uploaded glyph atlases

**Status: Adopt.** Landed in M3.

Skyline-packed atlases, grayscale for text and BGRA for emoji, shared across
every surface in the process rather than per-pane — four splits should not
rasterize the same 'e' four times or carry four textures. Each atlas keeps a
modified counter; a frame that adds no glyph uploads nothing.

### D2c. Run shaping cache

**Status: Adopt.** Landed in M3.

Shaping accounted for 96% of libghostty's frame time before they cached it
[GH `src/font/shaper/Cache.zig`]. The cache key is a hash of the run's
contents with cluster positions taken relative to the run start, so the same
word shaped at column 3 and column 40 shares one entry. Fixed-size and
set-associative, so it neither allocates per frame nor grows without bound.

### D2d. Render off the main thread, and stop when idle

**Status: Adapt.** Landed in M3.

libghostty runs a renderer thread per surface driven by a display link. We do
the same, with the display link on the render thread rather than the main one,
and additionally **pause the link** after a second with nothing to draw. An
idle terminal is the case this whole project is built around (see A1); it
should not wake a thread 120 times a second to be told there is nothing to do.

Frames are triple-buffered and presented by handing a CALayer a finished
IOSurface. Not a `CAMetalDrawable`: `nextDrawable` blocks on the display, which
stalls a renderer that could be building the next frame, and it behaves poorly
under live resize.

### D3. Incremental, caller-driven search

**Status: Free.** Milestone M6.

Terminal search over a large scrollback is split into small steps the caller
drives, so it never blocks a frame. Results survive resize, reflow, primary/alt
screen switches and scrollback pruning (`search.h`).

### D4. Everything else libghostty has already optimized

**Status: Free.** These are why "assume every client is a fast, correct terminal"
is a reasonable assumption:

- Much faster wide-character reflow on resize [GH `88ed6bebf`]
- Much faster grapheme-heavy IO throughput [GH `3d9b2b483`]
- Vectorized reflow run scan, reduced to masked compares [GH `ec5b36961`, `d4e446c48`]
- SIMD OSC string reading [GH `8c5bc3d29`] and SIMD base64 for OSC 52 [GH `39799a61c`]
- Fast-path APC termination [GH `afb351f83`]
- Fast print styles [GH `8838c37f4`]
- Formatter sped up 1.5×–8× [GH `b9bb50c83`] — matters if we ever add a
  formatter-based fallback path

---

## E. Robustness that is also performance

Bounded work is a performance property when the input is hostile or just weird.

- **Bounded OSC and grapheme allocations** [GH `46767b521`]
- **Kitty graphics**: png decoder allocation limits, eviction without scratch
  allocation, glyf decode limits [GH `590d669c4`, `9cb214764`, `e524df6c8`]
- **Snapshot decoder** enforces a maximum continuation size
  (`GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES`, default 65 MiB) and
  CRC32Cs every record

At our target scale a single session that can be made to allocate without bound
is a server-wide outage.

---

## F. Ours, not Superlogical's

Decisions we had to make because no source covers them. Flagged so they are not
mistaken for research.

### F1. Terminal queries are answered by the server

The child writes `DA`/`DSR`/`XTWINOPS` to the PTY and something must reply.
Superlogical has never said what. In our model the server owns the authoritative
terminal and is the only party guaranteed to exist, so **the server always
answers** — with zero clients attached or fifty. Clients never reply to queries;
they would race each other and produce duplicate responses.

This is a departure from [boo](https://github.com/coder/boo), where the attached
client's real terminal answers and the daemon only answers while detached. boo
needs that because its client *is* a passthrough TTY. Ours is not.

Unresolved: which client's dimensions to report when attached clients disagree.
Provisionally the session's own configured size, not any client's.

### F2. Flow control

**Status: Done.** Landed in M4.

Never addressed in any source. A bounded per-client queue where overflow drops
the client back to a fresh attach — a client that has fallen far enough behind
is better served by a new snapshot than a long replay. Given C2 this costs
nothing architecturally: reset-and-reattach is already the desync path, so the
only new thing on the wire is an error code that names it.

The bound is not the interesting part. The interesting part is that fan-out
stopped writing to sockets at all. It runs on a terminal's reader thread under
that terminal's lock, so a blocking `write` to one client that had stopped
reading stalled the terminal itself — its PTY, its state, and every other client
attached to it. Each client now has a queue and a thread of its own, and the
fan-out only ever copies into it.

The lock order that falls out is worth stating, because it decides the shape of
the code: **terminal lock, then client queue lock, never the reverse.** That is
why an overflowing subscriber is pruned by the terminal, from inside its own
fan-out loop, rather than unsubscribing itself from its writer thread.

One case is deliberately not covered: `attach` holds the terminal lock across
the encode, so a client that stops reading *mid-attach* still stalls that
terminal. Splitting that needs a two-phase encoder libghostty-vt does not
expose. See [PROTOCOL.md](PROTOCOL.md#flow-control).

### F3. Snapshot compression and encryption

**Status: Done.** Landed in M4.

Mitchell confirms parked snapshots are compressed and encrypted but names
neither algorithm [MEM t=278, t=369]. Compression is deflate rather than the
zstd he has recommended, because Zig 0.16 ships a zstd *decompressor* only and
a C zstd would be the project's first non-ghostty native dependency; it is one
constant to change.

Encryption is **XChaCha20-Poly1305, chunked**, over the compressed stream.
Chunked and not sealed once, because parking is worth nothing if unparking
stops being streaming: a terminal is usable at READY, long before the last byte
is read, and one AEAD over the file would mean buffering all of it to check a
single tag. 32 KiB chunks, 0.05% overhead.

The three things this kind of construction gets wrong, and what stops each:

| | |
| --- | --- |
| Chunks reordered | the chunk index is part of its nonce |
| File truncated | an authenticated empty terminator; a short file has none |
| Nonce reused | a fresh random 16-byte prefix per file |

The key lives beside the store at mode 0600. Anyone who can read the store as
this user can read the key, so this is not a defence against local compromise —
it is the same trust boundary the socket already has. It defends what *leaves*
that boundary: backups, disk images, container layers, a laptop passed on.
Which is the case [MEM t=278] is about.

Do not assume LZ4 here — that is Ghostty's *in-memory page* compression (A5),
which is a different problem with different constraints.

---

## Priority

If we only did some of this, in this order:

1. **C1 + C2** — raw byte fan-out with one writer. Everything else assumes it,
   and retrofitting it later means rewriting the protocol.
2. **B1** — the READY split. Attach latency stops depending on scrollback size.
3. **A3** — thread-per-PTY with poller migration. The hardest to retrofit
   because it shapes the whole IO layer.
4. **A1 + A2** — terminal parking, and serving attach from disk.
5. **A5** — live scrollback compression.
6. **A4 + A6** — the constant factors that decide the 10,000-session case.
