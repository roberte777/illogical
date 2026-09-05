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
├── split view
│   ├── TerminalSurface ── connection ── terminal 3 ── PTY
│   └── TerminalSurface ── connection ── terminal 7 ── PTY
└── toolbar: session dropdown
```

This is why the server never divides a grid, and why closing a split is just
closing a connection.

## The attach path, and the launch budget

The goal is that **nothing on screen waits for the network**:

1. `applicationDidFinishLaunching` → window and chrome are up. No I/O.
2. Connect (unix socket, or spawn `ssh`), send `hello`, `attach`.
3. Feed `snapshot_chunk` bytes into a `GhosttyReader`.
4. `snapshot_ready` → `ghostty_snapshot_decoder_ready()` → **first frame**.
5. `output` frames → `ghostty_terminal_vt_write()`.
6. `snapshot_chunk` (history) → `ghostty_snapshot_decoder_next()` on a background
   queue, one page per call, interleaved with (5).

Use the **streaming** decoder (`ghostty_snapshot_decoder_new` with a reader
callback), not `new_buf`. Decode should overlap the network read; the scaffold's
buffered version is a placeholder.

Measure steps 1 and 4 with `os_signpost`. Step 4 must not vary with scrollback
size — if it does, something is buffering that should be streaming.

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

## Scrollback is native, and sometimes absent

Two requirements that pull against each other:

- Scrolling is a real scroll view with real momentum. We never synthesize wheel
  escape sequences into the PTY.
- History arrives **after** the first frame, newest-first. Scrolling into a
  region that has not landed yet must show a **loading state**, not block and not
  lie [ARCH t=308].

The viewport is entirely client-side [ARCH t=323]. Two people attached to one
terminal scroll independently — the tmux behaviour where one client's scroll
moves everyone's window is a bug we are deliberately not reproducing.

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
