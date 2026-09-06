# Roadmap

Ordered by what unblocks what. Each milestone ends somewhere usable, and each
carries the optimizations that must land *with* it — the ones marked **structural**
cannot be retrofitted without rewriting the layer they live in.

Optimization IDs refer to [OPTIMIZATIONS.md](OPTIMIZATIONS.md).

---

## M0 — Scaffold ✅

- Nix devshell pinning Zig 0.16, matching `vendor/ghostty`.
- `vendor/ghostty` submodule; server and client from one pinned revision.
- `illogicald` + `illogical` linking the `ghostty-vt` module.
- `ghostty-vt.xcframework` build, verified end to end.
- macOS app target building against libghostty-vt.
- Wire protocol defined twice — Zig and Swift — with matching tests.

## M0.5 — Research and design ✅

- [RESEARCH.md](RESEARCH.md): every public claim about Superlogical, cited,
  with confidence levels and an explicit list of what we could not verify.
- [OPTIMIZATIONS.md](OPTIMIZATIONS.md): the full optimization catalogue.
- Existing docs corrected against the research. Two were materially wrong:
  the session model (a session holds *many* terminals) and the server IO model
  (thread-per-PTY, **not** one event loop).

---

## M1 — The session server ✅

**Ends at:** `illogical new`, `illogical list`, and a terminal that keeps running
after the CLI exits. **Done** — verified end to end, including that terminals
stay `live` after every client disconnects.

| | Work |
| --- | --- |
| | PTY allocation and child spawn (`src/core/pty.zig` is a stub) |
| **structural** | **A3** — one dedicated OS thread per PTY, blocked on `read()`. Not an event loop. This shapes everything above it |
| **structural** | **B3** — continuation tracking enabled at terminal creation, unconditionally. There is no retroactive path |
| | One `ghostty-vt` terminal per terminal, fed raw PTY output |
| | Session registry: a session holds many terminals; `meta.json` persistence |
| | Frame reader/writer over unix sockets; `hello`/`list`/`create`/`kill`/`input`/`resize` |
| | **F1** — server answers DA/DSR/XTWINOPS, with zero or N clients attached |
| | libxev loop for the control socket and timers only |

**Gate:** a terminal survives client exit; queries answered while detached. ✅

Also landed: `illogical peek`, which returns the server's rendered screen as
plain text without attaching. It was pulled forward from M6 because it is how
the whole stack gets tested.

## M2 — Attach ✅

**Ends at:** attaching shows the correct screen instantly, then fills in
scrollback. The Mac client attaches, decodes the snapshot into its own
libghostty-vt terminal and renders it; input round-trips to the PTY.

| | Work |
| --- | --- |
| **structural** | **C1** — raw PTY bytes teed to clients. Never diffs |
| **structural** | **C2** — one writer, many readers; input serialized; desync ⇒ re-attach |
| **structural** | **C3** — viewport and selection are client-side; server stores none |
| ✅ | Pause PTY processing, mark offset *N*, `snapshot_encode` at *N*, unpause |
| ✅ | `snapshot_begin` → chunks → `ready` → history newest-first → `end` |
| ✅ | Output fan-out to N clients |
| ✅ | Client-side streaming `SnapshotRestore` (reader callback, not `new_buf`) |
| ✅ | Mac client transport + session/terminal dropdown, live |
| ✅ | Loading state for history that has not arrived: the scrollbar describes the extent the snapshot **declares** at READY, not the part that has landed. See [CLIENT.md](CLIENT.md#the-loading-state) |

**Gate:** attach latency does not vary between 1 MB and 100 MB of scrollback.
**Met, within a bound the gate did not anticipate** — `scripts/bench-attach.sh`,
Debug build, M-series, median of 5:

| scrollback | attach → ready | attach → end | bytes read at ready |
| --- | --- | --- | --- |
| 200 lines | 32.2 ms | 32.5 ms | 14,369 |
| 20,000 lines | 33.8 ms | 150.1 ms | 14,879 |
| 200,000 lines | 33.0 ms | 375.4 ms | 11,719 |
| 700,000 lines | 33.5 ms | 379.9 ms | 13,679 |

The first column is the gate and it does not move — 32.2 to 33.8 ms across a
3,500× range of scrollback. The second is what the client used to wait for,
because `snapshot_ready` went out after the whole encode, so the old number for
the bottom row is the 380 ms beside it, not the 34 ms. The third says why the
first is flat: the client paints after about fourteen kilobytes whatever the
terminal is holding.

Read the bottom two rows carefully. They are the same measurement: a terminal
is capped at 50 MB of scrollback (`SpawnOptions.max_scrollback_bytes`), so
somewhere below two hundred thousand lines of 80-column text the history stops
growing and 700,000 lines carries exactly as much as 200,000. **The gate's
"100 MB" is therefore not reachable at all**, and the honest claim is narrower
than the one it asks for: flat from a screenful to the cap. Raising the cap is
what it would take to answer the question as written, and that is worth doing
before M5 puts this on a network.

The benchmark disables parking (`--park-after 86400`) and refuses to run
against a terminal that is not `live`, which is not hygiene: rows fill
sequentially, so a large one takes minutes and every smaller terminal would
cross the 60 s park threshold while it waits. Attaching to a parked terminal
serves the compressed park file off disk instead of encoding a live one, and an
earlier version of this table silently timed one path against the other and
called the difference scrollback.

The server finds the READY marker by record framing as the encoder streams past
it (`ReadyScanner` in `src/daemon/Client.zig`), which buffers nothing and works
the same for a live encode and for a park file replayed off disk.

Two things this does not do. The server still holds the terminal lock for the
whole encode, so [PROTOCOL.md](PROTOCOL.md)'s "UNPAUSE at READY" is not literal
— history is encoded before the PTY reader thread runs again, and splitting
that needs a two-phase encoder libghostty-vt does not expose (`snapshot.encode`
is one call). And the client decodes history once it has all arrived rather
than page by page, because the decoder reads inside `next()`, under the
engine's lock; the reasoning is in [CLIENT.md](CLIENT.md#the-attach-path-and-the-launch-budget).

## M3 — The renderer (in progress)

**Ends at:** the Mac app is a terminal you would actually use. See
[CLIENT.md](CLIENT.md).

Landed so far: the Metal renderer described in [CLIENT.md](CLIENT.md), ported
from libghostty's own; the Superlogical-style chrome (session button,
per-terminal tab strip, breadcrumb); key, mouse and focus encoding through
libghostty-vt's own encoders; and resize driven by the view's own geometry.

| | Work |
| --- | --- |
| ✅ | Metal renderer + glyph atlas, replacing the CoreText path |
| ✅ | **D1** — two-phase update: lock, begin, unlock, end |
| ✅ | **D2** — two-layer dirty tracking; `render_state_clean()` per frame |
| ✅ | CoreText glyph rasterization + atlas: ligatures, box drawing, emoji, wide chars |
| ✅ | Native scrollback; never synthesize wheel sequences |
| ✅ | Key/mouse/focus encoding via libghostty-vt, replacing the hand-rolled subset |
| ✅ | Selection via `selection.h`'s gesture machine, tracked grid refs |
| ✅ | Native splits: one connection per pane |
| ✅ | `os_signpost` launch budget |

Renderer numbers, Release, M-series, 200x50 cells:

| | CPU | with a synchronous GPU wait |
| --- | --- | --- |
| Full rebuild (a `clear`, a resize) | 1.2 ms | 2.5 ms |
| One dirty row (a keystroke) | 0.03 ms | 0.9 ms |

The gap between those two rows is what the dirty tracking buys. The GPU column
is what a benchmark measures because it blocks; the renderer does not, so in
the app that work overlaps the next frame's.

**Gate:** cold launch to window under the budget; first frame independent of
scrollback size. **Met** — `scripts/bench-launch.sh`, Debug build, M-series,
median of 7:

| scrollback | launch → window | ready → first frame |
| --- | --- | --- |
| empty terminal | 148 ms | 25–28 ms |
| a screenful, no history | 148 ms | 30–31 ms |
| 20,000 lines | 148 ms | 31 ms |
| 100,000 lines | 149 ms | 31–33 ms |

Two things to read out of that. Launch to window does not move at all with
scrollback, which is the point of connecting *after* the first layout: nothing
on screen waits for the network. And the first frame is the same whether there
are two hundred lines of history or a hundred thousand — a 5× increase in
scrollback costs nothing, so nothing is being buffered that should be
streaming. The 4 ms between an empty terminal and a full screen is glyph work
on the first frame, which is content, not history.

That second row only became true in this milestone. Restoring history ran
inline after `adopt`, so the first frame waited behind however much scrollback
there was — 8 ms at twenty thousand lines. It now runs off the main actor at
utility priority, one page at a time under the engine's lock.

Launch to window is a Debug build; treat 148 ms as a ceiling.

## M4 — Parking and the memory work ✅

**Ends at:** 10,000 idle terminals on a laptop, and you cannot tell. This is the
milestone the whole architecture exists for. See [PARKING.md](PARKING.md).

| | Work |
| --- | --- |
| ✅ | **A1** — terminal parking. Idle = **no PTY reads** for 60 s. Not keystrokes |
| ✅ | Snapshot encode → compress → fsync → atomic rename → free terminal |
| ✅ | Streaming unpark: `ready()` on the hot path, history on a background thread |
| ✅ | **A2** — attach to a parked terminal streams from disk and does **not** unpark |
| ✅ | **A5** — live scrollback compression: activity token, incremental steps on idle, never `MODE_FULL` on a hot path |
| ✅ | The benchmark, as `scripts/bench-memory.sh` and `scripts/bench-pty.sh` (not in CI — there is no CI) |
| ✅ | **F2** — flow control: bounded per-client queue, overflow ⇒ forced re-attach |
| ✅ | **A3** (second half) — PTY fd migration between dedicated thread and shared poller, with hysteresis |
| ✅ | **A4** — client buffer parking |
| ✅ | **A6** — per-terminal fixed costs: zero-init, lazy allocation, shared palette |
| ✅ | **F3** — snapshot **encryption**. Chunked XChaCha20-Poly1305 over the compressed stream, so unpark stays streaming |

**Gate: the benchmark table. Met**, with two of its four memory rows now better
than the reference implementation and one worse than tmux. The numbers and what
they do and do not say are below.

Deflate is used rather than zstd: Zig 0.16 ships a zstd decompressor only, and a
C zstd would be the first non-ghostty native dependency. One constant to change.

Two things this milestone learned the hard way, both recorded where they were
caused rather than only here:

- **Every memory number was a debug build**, and a debug build is off by an
  order of magnitude — Zig writes `0xAA` into every `undefined` buffer,
  including the demand-paged pages libghostty preheats per terminal. An empty
  terminal reads 1743 KiB debug against 90 KiB release. The benchmark builds
  release now.
- **Shrinking thread stacks broke parking**, and the test suite could not see
  it, because every park test called `park` from the test runner's own thread.
  One of them now runs it on the stack the daemon actually gives it.

## M5 — Remote

**Ends at:** the dropdown lists terminals on other machines.

- `illogicald --stdio`; SSH transport reusing the user's SSH config.
- Multiple simultaneous hosts in one window.
- Reconnect-and-reattach on network loss (which is just desync recovery).

## M6 — Beyond

- Session sharing — multiple people, one session. Needs identity and permissions,
  neither of which the protocol addresses yet.
- **D3** — incremental search over scrollback.
- Rename, reorder, per-terminal cwd in the UI.
- Config file.
- Daemon restart survival for live children (fd handoff).
- An automation surface. [boo](https://github.com/coder/boo) has the shape right:
  `send`, `peek`, `wait`, `--json`, all usable without a TTY. Given the agent
  framing this is arguably not "beyond" — it may deserve to move up.
- A second native client, to prove the protocol is not accidentally Mac-shaped.

---

## The benchmark suite

Superlogical's published numbers are the bar. Measure the same way they did —
macOS, `phys_footprint`, same terminal shapes — and report losses honestly.

| Benchmark | Superlogical | tmux 3.5a | ours | status |
| --- | --- | --- | --- | --- |
| Server start, no terminals | 10.6 MiB | 2.50 MiB | **1.23 MiB** | measured |
| Per terminal, 10,000 lines, settled | 407 KiB | 4.89 MiB | **390 KiB** | measured |
| Per empty 80×24 terminal | 68 KiB | **15 KiB** | 94 KiB | measured |
| Per client connection (50 filled) | 85 KiB | 157 KiB | **45 KiB** | measured |
| Unpark, 64 MB scrollback | ~200 µs (excl. disk) | — | — | not measured |
| Parked-PTY throughput cost | 5–10% | — | **+0.2%** one PTY, **+98%** eight at once | measured |

Run it with `scripts/bench-memory.sh 20 10000 50`, and the last row with
`scripts/bench-pty.sh 100000 32 3`.

We win the two rows that scale and lose the fixed-cost one to tmux, which is the
same shape Superlogical's own numbers have. Most of the empty-terminal row is
not ours — a libghostty terminal and the one preheated page that gets touched.

The throughput row needs its two halves read together. One parked PTY costs
nothing measurable, comfortably inside the reference figure. Eight busy ones at
once cost twice as much, because what a poller wake-up triggers is the VT parse
rather than the `read`, and four pool threads are doing what eight dedicated
readers would have. The cost is `terminals / pool`, it is paid only by terminals
nobody is watching, and it buys the flat thread count below.

⚠ **These are release-build numbers, and that changed them by an order of
magnitude.** Everything here was previously measured on a debug build, where
Zig fills `undefined` with `0xAA` and so writes every buffer a binary declares
before it is used — including the four ~390 KiB pages libghostty preheats per
terminal *because* they are demand-paged. An empty terminal measures 1743 KiB
debug and 90 KiB release. Everything in the two reference columns is a release
build. `scripts/bench-memory.sh` builds one now rather than trusting `zig-out`.

Three more things to be careful of. It is `phys_footprint`, not RSS — with RSS
the compression and parking wins are invisible on macOS, because
`MADV_FREE_REUSABLE` leaves pages counted until there is pressure. Freeing is
not returning: parking frees a terminal and A4 frees a client's buffers, and
the tests assert both on capacity, but whether the pages go back to the kernel
is the allocator's decision. And A5 gets there first — by the time a fill has
settled, compression has already released the physical pages, so there is no
separate "parked" row any more; it measures the same as settled-live.

Sources and methodology in [RESEARCH.md §7](RESEARCH.md#7-numbers).

Also measure, where no reference number exists:

- Attach latency at 1 MB vs 100 MB scrollback — must not differ. **32–34 ms
  from 200 to 700,000 lines**, Debug, measured in M2 above. 100 MB is not
  reachable: a terminal caps its scrollback at 50 MB.
- Attach to parked: terminal stays parked, no allocation spike.
- Full history restore time, in background, without regressing input latency.
- Thread count vs terminal count — must flatten, not track. **Flat**: 32
  unwatched terminals cost the same 7 threads as none, against 38 when every
  one of them is hot. `scripts/bench-pty.sh`, measured in M4.
- p99 input latency at 200 attachments.
- Client cold launch to window. **148 ms**, Debug, measured above.

---

## Open questions

- **Snapshot format churn.** libghostty-vt says format v1 has no compatibility
  guarantee. Pinning one revision for both sides works now and breaks the moment
  a client and server upgrade separately. Vendor a frozen copy, or accept
  lockstep?
- **Adopt Superlogical's protocol instead of ours?** Mitchell intends it to be
  open and shipped as part of libghostty [ARCH t=524]. If that lands, our
  protocol is redundant and we should delete it. Worth watching before M2
  hardens.
- **Empty-terminal footprint.** Superlogical is 4.5× worse than tmux here and
  says it knows why. We do not know why. Finding out is worth doing early,
  because it is fixed overhead we will otherwise inherit blindly.
- **Snapshot compression codec.** zstd is our starting choice; Superlogical has
  never said. Do not assume LZ4 — that is Ghostty's *in-memory page* codec, a
  different problem.
- **Resize with disagreeing clients.** One terminal, many window sizes.
- **Alternate screen and parking.** A terminal sitting in a full-screen TUI is
  idle by the PTY-read definition but expensive to restore. Different threshold?
- **Where the park key should live.** The scheme is settled — chunked
  XChaCha20-Poly1305, see [PARKING.md](PARKING.md) — but the key sits beside the
  data at mode 0600, so it protects backups and disk images and not a local
  compromise. The Keychain, or a passphrase, or an agent, is a different answer
  and a platform-specific one.
