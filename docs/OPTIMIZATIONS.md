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

**Status: Adopt.** Milestone M4.

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

**Status: Adopt.** Milestone M4.

The park file and the attach payload are the same bytes, so a client attaching to
a parked terminal is served **straight from disk**. The terminal never comes back
into memory. A client cycling attach/detach never wakes anything [MEM t=660].

This is the single strongest argument against inventing a separate wire format
for attach, and it falls out for free if you do not.

### A3. PTY parking — migrate fds between a thread and a poller

**Status: Adopt.** Milestone M1 (thread-per-PTY) and M4 (migration).

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
> Mitchell says he measured and rejected. libxev is still the right tool for the
> *parked* poller and for the control socket; it must not be the hot path.

### A4. Client buffer parking

**Status: Adopt.** Milestone M4.

Per-client pipeline buffers are kilobyte-scale but multiply by client count. Free
them once a client has been idle past its initial sync; reallocate on activity
[MEM t=551].

### A5. Scrollback page compression (LZ4, in memory)

**Status: Free**, once we drive it. Milestone M4.

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

**Status: Adopt.** Ongoing — and this is the one where the reference
implementation currently *loses*.

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

**Status: Adopt.** Milestone M2.

Scroll position and selection live entirely in the client [ARCH t=323]. The
server stores nothing per client except its buffers (see A4) and its subscription
set. This is both a correctness win over tmux and a memory win.

---

## D. Client rendering

### D1. Two-phase render state update

**Status: Free.** Milestone M3.

`ghostty_render_state_begin_update` needs exclusive terminal access;
`ghostty_render_state_end_update` completes using only render-state memory. A
renderer locks, begins, **unlocks**, then finishes — so the IO thread keeps
feeding the terminal while the frame is assembled.

> "This allows the render state to minimally impact terminal IO performance and
> also allows the renderer to be safely multi-threaded." — `render.h`

### D2. Two-layer dirty tracking

**Status: Free.** Milestone M3.

Global dirty state (clean / partially dirty / fully dirty) plus per-row dirty
flags, with dedicated dirty-row iteration [GH `ad6e72ddc`]. The renderer redraws
only changed rows.

The API's own warning is worth repeating: the two layers are independent, and
`update` does not clear either. Use `ghostty_render_state_clean()` after a
successful frame.

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

Never addressed in any source. Our intent is a bounded per-client queue where
overflow drops the client back to a fresh attach — a client that has fallen far
enough behind is better served by a new snapshot than a long replay. Given C2,
this costs nothing architecturally: reset-and-reattach is already the desync path.

### F3. Snapshot compression and encryption

Mitchell confirms parked snapshots are compressed and encrypted but names neither
algorithm [MEM t=278, t=369]. We will start with **zstd** (which he has
recommended for snapshots in a ghostty discussion) and leave encryption to M4,
tracked as an open question in [ROADMAP.md](ROADMAP.md).

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
