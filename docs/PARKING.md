# Parking and rehydration

Idle sessions should cost approximately nothing. Not "less"; nothing.

## The lifecycle

```
                 output arrives
        ┌───────────────────────────────┐
        │                               │
        ▼                               │
   ┌─────────┐   idle ≥ 60s   ┌────────┴────────┐
   │  live   │───────────────►│     parked      │
   └─────────┘                └─────────────────┘
        ▲                               │
        │                               │ PTY readable
        │      history restored         ▼
        │                     ┌──────────────────┐
        └─────────────────────│   rehydrating    │
                              └──────────────────┘
```

**live** — terminal state in memory, PTY registered, output fanned out.

**parked** — `snapshot.gsnp` on disk, terminal freed. The PTY master fd is
*still* registered with the event loop. This is the whole trick: a parked
session costs one file descriptor and one small metadata record. The child
process never notices.

**rehydrating** — `READY` has been decoded, so the session can accept output and
serve attaches immediately. History pages are still being restored on a
background thread.

## Parking

Triggered when a live session has produced no output for
`park_after` (default 60s). Attached-but-silent sessions are parked too — with
agent workloads that is the common case, and an attached client that is not
looking at anything costs nothing to re-serve from a snapshot.

1. Encode with `ghostty_snapshot_encode` to `snapshot.gsnp.tmp`.
2. `fsync`, then `rename` over `snapshot.gsnp`. Atomic: a crash mid-park leaves
   the previous good snapshot in place.
3. Free the in-memory terminal.
4. Leave the PTY fd registered.

The terminal must not be mutated during encode — libghostty-vt requires it — so
the loop thread pauses that session's output handling for the duration. Encode
cost scales with scrollback, which is why it happens on a pool thread and why
`max_snapshot_bytes` exists as an escape hatch for pathological sessions.

## Unparking

Triggered by the PTY becoming readable, or by a client attaching.

1. `ghostty_snapshot_decoder_new_buf` over the mapped file.
2. `ghostty_snapshot_decoder_ready()` → renderable terminal.
   **The session is usable at this point.** Pending PTY bytes are applied and
   any waiting attach is served.
3. `ghostty_snapshot_decoder_next()` in a loop on a background thread, prepending
   history pages newest-first, until `GHOSTTY_NO_VALUE`.

Step 2 is the latency that matters — it is bounded by the active screen, not by
scrollback, which is what makes a sub-millisecond target reasonable. Step 3 can
take as long as it likes; the session is already working.

## Continuation state

A session can be parked mid-escape-sequence — the child may have written half a
CSI when it went quiet. The snapshot's `CONTINUATION` record carries the
unfinished VT parser and UTF-8 decoder state, so unparking resumes *inside* that
sequence rather than dropping or misinterpreting it.

This requires continuation tracking to be enabled on the terminal **before** the
input that produced the unfinished state was written. So the server enables it
on every session at creation, unconditionally, and the parked snapshot always
round-trips exactly.

## On-disk layout

```
$XDG_STATE_HOME/illogical/
  server.sock
  server.pid
  sessions/<id>/meta.json          name, argv, cwd, size, child pid
  sessions/<id>/snapshot.gsnp      GHOSTSNP record stream
  sessions/<id>/snapshot.gsnp.tmp  staged, renamed on fsync
```

`snapshot.gsnp` is exactly the byte stream sent as `snapshot_chunk` payloads
during attach. One format, one encoder, one decoder, two uses.

## Crash and restart

`meta.json` survives a daemon restart, so `illogicald` can rebuild its session
table on startup. It cannot reattach to the *children* — their controlling PTY
died with the daemon — but it can present the last known screen and let the user
see what happened before dismissing them.

Surviving a daemon restart with live children requires the PTY masters to be
held by something that outlives the daemon (fd passing to a supervisor, or
re-exec preserving fds). Out of scope for now; see [ROADMAP.md](ROADMAP.md).

## Tuning

| Knob | Default | Meaning |
| --- | --- | --- |
| `park_after` | 60s | idle time before parking |
| `park_while_attached` | true | park even with clients attached |
| `max_snapshot_bytes` | 256 MiB | refuse to park beyond this; stay resident |

## What to measure

- `park` wall time vs. scrollback size.
- `unpark` → `ready()` returns. This is the headline number.
- Full history restore time (background, should not regress interactivity).
- RSS of a parked session vs. a live one.
- Snapshot size vs. scrollback rows.
