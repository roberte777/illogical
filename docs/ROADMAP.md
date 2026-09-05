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

## M2 — Attach ✅ (server and client), history streaming outstanding

**Ends at:** attaching shows the correct screen instantly, then fills in
scrollback. The Mac client attaches, decodes the snapshot into its own
libghostty-vt terminal and renders it; input round-trips to the PTY.

| | Work |
| --- | --- |
| **structural** | **C1** — raw PTY bytes teed to clients. Never diffs |
| **structural** | **C2** — one writer, many readers; input serialized; desync ⇒ re-attach |
| **structural** | **C3** — viewport and selection are client-side; server stores none |
| | Pause PTY processing, mark offset *N*, `snapshot_encode` at *N*, unpause |
| | `snapshot_begin` → chunks → `ready` → history newest-first → `end` |
| | Output fan-out to N clients |
| | Client-side streaming `SnapshotRestore` (reader callback, not `new_buf`) — currently buffers the whole snapshot before decoding |
| | Mac client transport + session/terminal dropdown, live |
| | Loading state for history that has not arrived |

**Gate:** attach latency does not vary between 1 MB and 100 MB of scrollback.

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
| | Native scrollback; never synthesize wheel sequences |
| ✅ | Key/mouse/focus encoding via libghostty-vt, replacing the hand-rolled subset |
| ✅ | Selection via `selection.h`'s gesture machine, tracked grid refs |
| ✅ | Native splits: one connection per pane |
| | `os_signpost` launch budget |

Renderer numbers, Release, M-series, 200x50 cells:

| | CPU | with a synchronous GPU wait |
| --- | --- | --- |
| Full rebuild (a `clear`, a resize) | 1.2 ms | 2.5 ms |
| One dirty row (a keystroke) | 0.03 ms | 0.9 ms |

The gap between those two rows is what the dirty tracking buys. The GPU column
is what a benchmark measures because it blocks; the renderer does not, so in
the app that work overlaps the next frame's.

**Gate:** cold launch to window under the budget; first frame independent of
scrollback size.

## M4 — Parking and the memory work (core landed)

**Ends at:** 10,000 idle terminals on a laptop, and you cannot tell. This is the
milestone the whole architecture exists for. See [PARKING.md](PARKING.md).

| | Work |
| --- | --- |
| ✅ | **A1** — terminal parking. Idle = **no PTY reads** for 60 s. Not keystrokes |
| ✅ | Snapshot encode → compress → fsync → atomic rename → free terminal |
| ✅ | Streaming unpark: `ready()` on the hot path, history on a background thread |
| ✅ | **A2** — attach to a parked terminal streams from disk and does **not** unpark |
| ✅ | **A5** — live scrollback compression: activity token, incremental steps on idle, never `MODE_FULL` on a hot path |
| ✅ | The benchmark, as `scripts/bench-memory.sh` (not yet in CI — there is no CI) |
| | **A3** (second half) — PTY fd migration between dedicated thread and shared poller, with hysteresis |
| | **A4** — client buffer parking |
| | **A6** — per-terminal fixed costs: zero-init, lazy allocation, shared palette |
| | **F2** — flow control: bounded per-client queue, overflow ⇒ forced re-attach |
| | **F3** — snapshot **encryption**. Compression landed; encryption did not, so park files are plaintext on disk and scrollback holds secrets. This is a real gap, not a refinement |

**Gate:** the benchmark table. Partially met — see below.

Deflate is used rather than zstd: Zig 0.16 ships a zstd decompressor only, and a
C zstd would be the first non-ghostty native dependency. One constant to change.

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
| Server start, no terminals | 10.6 MiB | 2.50 MiB | **2.38 MiB** | measured |
| Per terminal, 10,000 lines, live | **407 KiB** | 4.89 MiB | 1867 KiB | measured |
| Per terminal, 10,000 lines, parked | — | — | **374 KiB** | measured |
| Per empty 80×24 terminal | 68 KiB | **15 KiB** | — | not measured |
| Per client connection (50 filled) | **85 KiB** | 157 KiB | — | not measured |
| Unpark, 64 MB scrollback | ~200 µs (excl. disk) | — | — | not measured |
| Parked-PTY throughput cost | 5–10% | — | — | A3 not implemented |

Run it with `scripts/bench-memory.sh 20 10000`.

Two things to be careful about when reading that table. First, it is
`phys_footprint`, not RSS — with RSS the compression and parking wins are
invisible on macOS, because `MADV_FREE_REUSABLE` leaves pages counted until
there is pressure. Second, Superlogical's 407 KiB does not say whether it was
measured parked. Our parked figure lands beside it and our live figure is 4.5×
worse, so either their number is also a settled measurement or their live
representation is genuinely leaner. We do not know which, and should not claim
the win either way.

Sources and methodology in [RESEARCH.md §7](RESEARCH.md#7-numbers).

Also measure, where no reference number exists:

- Attach latency at 1 MB vs 100 MB scrollback — must not differ.
- Attach to parked: terminal stays parked, no allocation spike.
- Full history restore time, in background, without regressing input latency.
- Thread count vs terminal count — must flatten, not track.
- p99 input latency at 200 attachments.
- Client cold launch to window.

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
- **Encryption scheme** for parked snapshots. Mitchell deferred it publicly; we
  have to pick something.
