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

### The loading state we do not need yet

The design called for history arriving **after** the first frame, newest-first,
with a loading state for regions that had not landed [ARCH t=308]. The server
does not do that yet: `Client.attach` encodes the whole snapshot — screen and
history — into `snapshot_chunk` frames, and only then sends `snapshot_ready`
and `snapshot_end`. So by the time the client can paint, the history is already
in hand and there is no window in which to be missing anything.

The client is written for either shape: it decodes through READY, paints, then
prepends history pages until FINISH. When the server starts streaming history
after READY — [#19](https://github.com/roberte777/illogical/issues/19) — the
loading state becomes reachable, and that is the point to build it. Building it
now would mean building against a protocol shape nothing produces.

## Selection

Selection is per-client too, for the same reason the viewport is. Use
`selection.h`'s gesture state machine rather than hand-rolling drag handling,
and keep endpoints as **tracked** grid refs — plain `GhosttyGridRef`s are
invalidated by the next terminal mutation, which for us is every output frame.

The renderer already draws a selection when the render state reports one; what
is missing is the input half that sets it.

## Input

Encode with libghostty-vt (`ghostty_encode_key`, `ghostty_encode_mouse`,
`ghostty_encode_focus`) and send the bytes as `input`. Do not echo locally: the
server is the single writer, and the echo comes back as `output` like everything
else.

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
