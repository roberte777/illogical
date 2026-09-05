# The macOS client

`Illogical.app`. Swift 6, AppKit + SwiftUI, libghostty-vt via
`ghostty-vt.xcframework`, Metal for drawing.

The client is not a viewer. It is a **full terminal emulator running the same VT
engine as the server**, which is what lets the server send raw bytes and stop
caring. Mitchell's own phrasing of the requirement: *"it does require that every
connecting client be a very smart, high-functioning, compliant client"*
([The Register](https://www.theregister.com/), quoting [ARCH]).

## Structure

```
Illogical.app
├── App/            window, menus, session dropdown
├── Sessions/       connection state, session + terminal lists
├── Terminal/
│   ├── TerminalEngine.swift     libghostty-vt wrapper + snapshot extraction
│   ├── SnapshotRestore.swift    two-phase attach decode
│   ├── TerminalController.swift one connection, one terminal
│   ├── TerminalSurfaceView.swift  NSView host, layer, input
│   └── Renderer/                Metal renderer, atlases, fonts, sprites
└── Transport/      unix socket, ssh stdio, framing

Packages/IllogicalKit/
└── IllogicalProtocol           pure Swift, no libghostty — testable alone
```

## One connection per terminal

⚠ A window showing four splits holds **four** protocol connections, each 1:1 with
a PTY [ARCH t=440]. There is no in-window multiplexing and no layout protocol —
splits, tabs and windows are ordinary AppKit views.

```
NSWindow
├── tab: a split tree
│   ├── TerminalPane ── connection ── terminal 3 ── PTY
│   └── TerminalPane ── connection ── terminal 7 ── PTY
└── toolbar: session dropdown, tab strip
```

This is why the server never divides a grid, and why closing a split is just
closing a connection.

A **tab** is a layout of panes, not a terminal. It has an identity of its own,
because a tab named by the terminal it started as has nothing to be called once
you close that pane and keep working in the other one; its label follows its
focused pane, so a split tab says what you are working in. Splitting creates a
terminal on the server and a connection to it, and adds a pane — never a tab.

The split controls live in **each terminal's own header**, not the window
toolbar: in a tab with four panes, "split right" has to mean "split this one",
and a button in the title bar cannot say which one it means. Split right, split
down, zoom, close — with zoom disabled in a tab with one pane, because there is
nothing to zoom out of.

Focus is AppKit's. The pane the layout calls focused is whichever surface is
first responder, reported back by the surface, rather than a SwiftUI tap
gesture layered over the terminal that would swallow the clicks selection
needs. ⌘W reaches the focused surface as `performClose:` through the responder
chain, so it closes a pane and falls through to closing the window when there
is only one — no fight with the standard Close Window item for the shortcut.

## The attach path, and the launch budget

The goal is that **nothing on screen waits for the network**:

1. `applicationDidFinishLaunching` → window and chrome are up. No I/O.
2. Connect (unix socket, or spawn `ssh`), send `hello`, `attach`.
3. Feed `snapshot_chunk` bytes into a `GhosttyReader`.
4. `snapshot_ready` → `ghostty_snapshot_decoder_ready()` → **first frame**.
5. `output` frames → `ghostty_terminal_vt_write()`.
6. `snapshot_chunk` (history) → `ghostty_snapshot_decoder_next()` on a background
   queue, one page per call, interleaved with (5).

The decoder is the **streaming** one (`ghostty_snapshot_decoder_new` with a
reader callback), not `new_buf`, and it pulls from `SnapshotStream` — a pipe
that `snapshot_chunk` payloads go into and that releases each chunk as the
decoder reads it. Nothing holds a second copy of the stream, and `ready()`
needs only the bytes through the READY marker, which is what makes step 4
independent of scrollback size.

`SnapshotStream` **reports end of file when it runs dry rather than waiting**,
which reverses `snapshot.h`'s advice that a source which can starve must block
in its callback. Blocking is what it must not do: `ready()` runs on the main
actor and `next()` runs under the engine's lock, so a starved read would stall
the window or the renderer for as long as the transport took. Neither can
legitimately starve — the server frames `snapshot_ready` after every byte it
describes and `snapshot_end` after the last of them, so each phase is driven
from bytes already in hand. A read that finds nothing means the stream is
malformed or abandoned, and the decoder reporting truncated data is the right
outcome: the client falls back to a blank screen and takes live output.

That is also why step 6 starts at `snapshot_end` rather than at the first
history chunk. Decoding pages as they arrive means calling `next()` — and so
reading — while holding the engine's lock, which needs a way to wait for bytes
without stalling the renderer. Until there is one, history decodes once it has
all landed. The user-visible cost is that scrollback appears in one go rather
than filling in; the first frame, which is the gate, does not wait for any of
it.

Step 6 is not optional and not a refinement. History restored inline after
`adopt` pushes the first frame back by however long it takes, which was 8 ms at
twenty thousand lines: G3 says the first frame must not depend on how much
scrollback there is, and G4 says history must not block anything. It runs on a
background task at utility priority, one page per call — each under the
engine's lock, because the decoder writes into the terminal the engine now owns
and the render thread reads that same terminal.

Measure steps 1 and 4 with `os_signpost`. Step 4 must not vary with scrollback
size — if it does, something is buffering that should be streaming.

`Signposts` emits both as `os_signpost` for Instruments and, under
`ILLOGICAL_TRACE`, as `milestone <name> <seconds>` lines, because a gate has to
be runnable without a GUI. `scripts/bench-launch.sh` (`just bench-launch`)
reads the latter and compares three terminals: empty, a screenful with no
history, and a screenful with a large one. The gate is the last two matching;
the first is expected to differ, because an empty first frame has almost no
glyphs to shape.

`scripts/bench-attach.sh` (`just bench-attach`) measures the step before that
one — `attach` to `snapshot_ready`, which is M2's gate — across scrollback
sizes, and reports `attach`→`snapshot_end` beside it so the history the client
is no longer waiting on is visible. It waits for each terminal's PTY to go
idle first, using the daemon's own idle clock: the reader thread holds the
terminal lock while it applies output, so attaching to a terminal that is
still writing measures how long the writer has left to run and nothing else.

"First frame" means the frame carrying the adopted snapshot, not the
renderer's first frame — the blank surface is drawn at layout, before the
attach handshake has even been sent, and timing that would report a number
that is always the same and always wrong.

## Rendering

libghostty-vt gives us grid state and dirty tracking. Everything below the grid —
glyphs, atlas, draw calls — is ours.

**Two-phase update.** `ghostty_render_state_begin_update` needs the terminal
lock; `ghostty_render_state_end_update` does not. Lock, begin, **unlock**, end.
The network/IO path keeps writing while the frame is assembled.

**Dirty tracking has two independent layers** — a global state (clean / partial /
full) and per-row flags. `update` sets them and never clears them. Call
`ghostty_render_state_clean()` after a successful frame, and remember that
clearing one layer does not clear the other.

**Three passes.** The renderer is Metal, ported closely enough from
libghostty's own (`src/renderer/`) that the two can be diffed against each
other. A frame is three draw calls:

1. `bg_color` — one full-screen triangle for the surface background.
2. `cell_bg` — one more triangle; the fragment shader derives its grid
   position from the fragment coordinate and indexes a per-cell colour
   buffer. There is no geometry per cell: an 80×24 screen of backgrounds is
   two triangles and 1,920 bytes, not 1,920 quads.
3. `cell_text` — one instanced 32-byte quad per glyph, underline,
   strikethrough, overline and cursor.

**Colour.** The target is an IOSurface tagged Display P3, and the shaders
convert from sRGB, enforce a configurable WCAG minimum contrast, and can
correct alpha so linear blending keeps the apparent stroke weight of
gamma-incorrect blending. The default matches Ghostty's on macOS: blend in the
display's own space, which is what the system's own apps do.

**Glyphs.** Rasterized with CoreText into skyline-packed atlases — grayscale
for text, BGRA for emoji — shared process-wide and uploaded only when
something new is added. Sub-pixel positioning is kept out of the atlas
coordinates and folded into the drawing transform, so a glyph that wants to
sit at x=3.4 is rasterized *as* 3.4 rather than snapped. Metrics come from the
OpenType tables directly: CoreText rounds to points and hides whether the font
specified an underline position at all.

**Sprites.** Cursors, the five underline styles, strikethrough, overline, box
drawing, block elements, braille, powerline separators, sextants, octants and
the branch-drawing set are drawn by us, not loaded from a font. Not for lack
of glyphs — for tiling. A font glyph is positioned by advance-width rounding,
so a vertical line in one cell lands a pixel off the one below it and a table
border comes out visibly ragged.

**Shaping.** CoreText run shaping, split at every boundary where shaping must
restart (a style change, a selection edge, the cursor), cached on a
position-independent hash of the run's contents. Shaping was 96% of frame time
in libghostty before they cached it; the same cache means an unchanged line
costs a hash lookup per run.

**Threading.** A dedicated render thread per surface, woken by a display link
on that thread rather than on the main thread, and paused outright after a
second with nothing to draw. Frames are triple-buffered and presented by
handing a CALayer a finished IOSurface — not a `CAMetalDrawable`, whose
`nextDrawable` blocks on the display and stalls a renderer that could be
building the next frame.

## Scrollback is native

The viewport is entirely client-side [ARCH t=323]. We call
`ghostty_terminal_scroll_viewport` on our own replica and tell the server
nothing, so two people attached to one terminal scroll independently — the
tmux behaviour where one client's scroll moves everyone's window is a bug we
are deliberately not reproducing.

We never synthesize wheel sequences into the PTY. There is no arrow-key
translation and no alternate-scroll mode: the wheel moves our window over the
history, and that is all it does. When the program has asked for mouse events
the wheel belongs to it instead and we leave the viewport alone.

**Turning gestures into rows** is `ScrollAccumulator`, ported from
libghostty's `scrollCallback`. Two device quirks make it more than a division.
A trackpad reports a few pixels at a time, so the remainder has to carry
between events or nothing ever moves. A wheel reports ticks, but macOS fakes
precision for wheels by ramping the tick magnitude with speed — a slow single
click arrives as 0.1 — so the magnitude is rounded out to a whole tick.
Momentum needs no special handling: the OS keeps sending events after the
fingers lift and they run through the same path.

**Moving the viewport forces a full repaint.** libghostty's per-row dirty
flags describe content, not position, so after a scroll every row is still
"clean" and a renderer that trusted them would show the old screen. The engine
marks the next frame fully dirty instead.

Typing jumps back to the live output; output arriving does not. Those are
libghostty's defaults and they are the right ones — output scrolling out from
under you while you read history is infuriating.

The position indicator is an overlay layer, not an `NSScrollView`. There is no
document view to scroll (the content is an IOSurface the renderer repaints in
place) and the scrollable area changes shape as output arrives and scrollback
is pruned, so there is nothing for a scroll view to manage.

### The loading state

The design called for history arriving **after** the first frame, newest-first,
with a loading state for regions that had not landed [ARCH t=308]. That window
now exists: the server sends `snapshot_ready` at the READY marker and history
after it, so between the first frame and `history-restored` the client is
painting a terminal whose scrollback it does not have. At two hundred thousand
lines that window is a third of a second on a unix socket, and it is the whole
transfer over SSH.

Nothing marks it yet. `scrollbackRows` stays zero until the restore finishes,
so the scrollbar reports the screen only and there is nothing to scroll into
rather than something wrong to scroll into — which is the safe failure, but not
the designed one. The state to build is a distinct treatment for rows the
snapshot has declared and not yet delivered: `SCREEN` carries each screen's
complete logical history extent at READY, so the size is known before the pages
arrive.

## Selection

Selection is per-client too, for the same reason the viewport is. Use
`selection.h`'s gesture state machine rather than hand-rolling drag handling,
and keep endpoints as **tracked** grid refs — plain `GhosttyGridRef`s are
invalidated by the next terminal mutation, which for us is every output frame.

The renderer already draws a selection when the render state reports one; what
is missing is the input half that sets it.

Selection is likewise per-client, and is `selection.h`'s gesture state machine
rather than hand-rolled drag handling. The client supplies a pointer position,
the click timing AppKit already knows, and the renderer's own geometry; the
gesture decides what a double-click selects and how a word-granular drag
extends backwards over its own anchor.

Endpoints must be **tracked** grid refs: a plain `GhosttyGridRef` is
invalidated by the next terminal mutation, which for us is every output frame.
Two mechanisms give us that, and neither requires holding a ref ourselves.
Installing a selection with `GHOSTTY_TERMINAL_OPT_SELECTION` makes the terminal
copy it into tracked state, so the *result* of a gesture survives; and the
gesture owns tracked references for its own anchor, so the gesture in progress
survives too. The consequence is a lifetime rule: those references belong to
the terminal that made them and must be released before it is freed, which is
why `TerminalEngine` owns the gesture and resets it in `adopt` rather than the
view owning it and finding out later.

Deriving a ref and using it are one operation under the terminal lock, for the
same reason. Points are resolved in **viewport** coordinates, which
`ghostty_terminal_grid_ref` interprets against wherever the viewport currently
sits — so the conversion is already correct while scrolled back into history,
with no offset to plumb through.

A selection changes no cell, so libghostty's per-row dirty flags do not
describe it and the frame has to be rebuilt in full when it changes.

Copy is `ghostty_terminal_selection_format_alloc` with plain output, unwrap and
trim — the combination the header names as matching Ghostty's own
`selectionString()`, and what makes a copied command paste back as one command.
Paste is `ghostty_paste_encode`, which strips control bytes and wraps in
bracketed paste when the program asked for it; `ghostty_paste_is_safe` decides
when to ask the user first, because a pasted newline is a pressed return and
outside bracketed paste the shell cannot tell the difference.
## Input

Encode with libghostty-vt and send the bytes as `input`. Do not echo locally:
the server is the single writer, and the echo comes back as `output` like
everything else.

Three encoders, all of which read the terminal's own state rather than a table
of ours:

- `ghostty_key_encoder_encode`, with the options taken from the terminal by
  `ghostty_key_encoder_setopt_from_terminal` before every event. That is what
  makes DECCKM, `modifyOtherKeys` and the five Kitty keyboard flags work
  without the client tracking any of them. `macos-option-as-alt` is the one
  option the terminal cannot supply; it defaults by keyboard layout, as
  Ghostty's does.
- `ghostty_mouse_encoder_encode`, given the renderer's own screen, cell and
  padding sizes so a report lands on the cell the user aimed at. Shift
  suppresses reporting for **buttons and motion**, which is how you select
  text inside a full-screen TUI — and deliberately not for the wheel, because
  Ghostty's `scrollCallback` has no shift gate at all. Ghostty's full rule also
  lets the terminal take shift back with XTSHIFTESCAPE and exposes the choice
  as `mouse-shift-capture`; we implement its default and neither of those.
- `ghostty_focus_encode`, gated on DEC mode 1004 — it takes no terminal and
  will happily encode a report nobody asked for.

The wheel has three possible claimants and libghostty's own order decides
between them: quantize the gesture to whole rows *unconditionally*, then give
it to mouse reporting if the program asked for the mouse, else to alternate
scroll (DECSET 1007 in the alternate screen, where a wheel becomes the cursor
keys `less` already understands), else to the viewport. The first two write to
the PTY and belong to the encoder; the third is native scrollback's, and owns
`scrollWheel` and the accumulator. Quantizing first is not a detail: a report
is one button press per row, so a caller handing raw trackpad deltas to the
encoder would emit ten reports where a mouse emits one, and a gesture that
crossed into a mouse-tracking program would carry a stale fraction back out.

The client translates only two things itself: the macOS virtual keycode to a
physical key, and AppKit's `characters` to the text the layout produced. What
those *mean* is never ours to decide.

Client-side echo would be a latency optimization that breaks the one-writer
invariant, which is what makes desync recovery trivial. Don't.

## Session and terminal switching

The dropdown lists sessions; a session expands to its terminals. Each row shows
residency — live, parked, rehydrating, exited — because parked is normal and
should look normal, not like an error.

Switching to a parked terminal is **not** an unpark: the server streams its
snapshot straight from disk and the terminal stays parked [MEM t=660]. From the
client's side this is indistinguishable from attaching to a live one, which is
the point. Do not add a spinner for it.

## Remote hosts

`ssh <dest> illogicald --stdio`, with the frame stream on the pipe. The user's
existing SSH config, keys, jump hosts and agent forwarding apply. No credential
handling of our own, and nothing to store.

Superlogical's server additionally has built-in Tailscale/Headscale support and
acts as a node ([MASTO]). Out of scope for us; SSH first.

## Not sandboxed

The client talks to a unix socket outside a container and spawns `ssh`, so
`com.apple.security.app-sandbox` is off. Revisit only if this ever ships through
the App Store.

## What is deliberately not here

- **No compatibility mode.** Rendering into someone else's terminal means putting
  a libghostty terminal in the middle, which is *"the same trade-off as other
  multiplexers"* [ARCH t=507]. `illogical attach` (the CLI) is that path if we
  ever want it; the app must never take it.
- **No layout protocol.** Layout is local UI state. If we ever sync it across
  devices it is a separate feature on a separate channel, not part of the
  terminal protocol.
