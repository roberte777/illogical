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
├── Supporting/
│   └── Fonts/      JetBrains Mono, shipped as the default face
├── Terminal/
│   ├── TerminalEngine.swift     libghostty-vt wrapper + snapshot extraction
│   ├── SnapshotRestore.swift    two-phase attach decode
│   ├── TerminalController.swift one connection, one terminal
│   ├── TerminalSurfaceView.swift  NSView host, layer, input
│   └── Renderer/                Metal renderer, atlases, fonts, sprites

Packages/IllogicalKit/
└── IllogicalProtocol           pure Swift, no libghostty — testable alone
    ├── Frame.swift             the wire header
    ├── Connection.swift        reader thread, frame stream, serialized writes
    ├── Transport.swift         unix socket, or `ssh <dest> illogicald --stdio`
    ├── LocalDaemon.swift        starts the local illogicald when there is none
    └── Session.swift           sessions, terminals, hosts
```

Transport is in the package rather than the app on purpose: it is the half of
remote support that can be tested without a window, a GPU or a daemon, and
`just test-swift` runs it in under a second.

## Several machines in one window

A window holds one `HostConnection` per machine: the local daemon, plus any
number of remote ones. Each owns **what exists** on its machine — its control
connection, its sessions, its terminals, its per-terminal controllers.
`SessionStore` owns **where that is drawn**: the tabs, the split trees, the
selection, across every host at once.

```
SessionStore                      tabs, splits, selection
├── HostConnection  Local         sessions, terminals, controllers
├── HostConnection  build-box     sessions, terminals, controllers
└── HostConnection  gpu-01        sessions, terminals, controllers
```

That split is what makes the rest of the client indifferent to where a terminal
is. The one thing it forces is that **a terminal is a `TerminalRef`, not an id**:
every daemon numbers its terminals from 1, so two machines both have a terminal
1, and a `UInt64` in a pane would draw one machine's terminal in the other's
pane rather than merely losing a tab. The same goes for a `SessionRef`.

A tab belongs to one session, and a session lives on one machine, so a tab never
spans two hosts. Splitting inside it creates a terminal on that same machine.
Which machine you are looking at is on the session button; which machine a
*pane* is on is in its own header, because a tab has one strip entry and a split
tab could otherwise say nothing about it.

Hosts are remembered in `UserDefaults`, and there is no credential among them:
`ssh` reads the user's own config, so a `Host` alias out of it is a perfectly
good answer. Only what the *user* added is written — hosts injected by
`ILLOGICAL_HOSTS` are deliberately not, so a session started with that variable
does not quietly make them permanent the first time you add or forget anything
else.

**One unreachable machine is not a broken window.** A failed host is a marker in
the dropdown with `ssh`'s own complaint behind it and a button to try again; the
"no server" screen only takes over when *every* host is down. `ILLOGICAL_HOSTS`
adds destinations at launch without remembering them, so a two-machine window
can be inspected without driving the mouse.

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
needs.

**⌘W closes the focused terminal.** It reaches the surface as `performClose:`
through the responder chain, so the terminal gets first refusal without
fighting the standard Close Window item for the chord. The window closes only
when that terminal was the last one in it — the condition is
`tabs.count > 1 || tab.isSplit`, and it counts *every* tab the window holds,
not the strip's. A window whose front session shows one tab may be holding
tabs on another session, and closing it would take those with it; the selection
moves to them instead (issue #41).

The policy is `SessionStore.closeSurfacePane` and not the delegate method over
it, so "does ⌘W close the window" is a question a test can ask without a window.

**⇧⌘W closes the whole tab** — as does the ✕ in the tab strip, and a pane's own
✕ is ⌘W for that pane. All four routes answer to the same two store calls, and
the window half of each goes through `WindowClose`, because they used to
disagree: ⌘W on the last terminal closed the window and left the shell running,
while ⇧⌘W on the same terminal hung it up and left an empty window behind.

The rules, in the order they are applied:

- **The window's last tab closes the window**, and kills nothing. Closing a
  window here is a detach — "Sessions keep running after you close this window"
  is the empty state's own promise, and re-launching re-attaches. That is also
  why this case does not confirm: nothing is destroyed.
- **A tab with more than one pane asks first**, because closing it really does
  hang up every terminal in it.
- **One pane closes outright.** No shipping terminal confirms a single close,
  and the one thing that would justify it — a foreground process still
  running — is not something we can detect (`TerminalSummary.command` is the
  child's argv[0], not the foreground job).

## The attach path, and the launch budget

The goal is that **nothing on screen waits for the network**:

1. `applicationDidFinishLaunching` → window and chrome are up. No I/O.
2. Connect (unix socket, or spawn `ssh`), send `hello`, `attach`.
3. Feed `snapshot_chunk` bytes into a `GhosttyReader`.
4. `snapshot_ready` → `ghostty_snapshot_decoder_ready()` → **first frame**.
5. `output` frames → `ghostty_terminal_vt_write()`.
6. `snapshot_end` → `ghostty_snapshot_decoder_next()` on a background queue, one
   page per call, interleaved with (5). Per the design this should start at the
   first history chunk rather than at `snapshot_end`; why it does not is below.

The decoder is the **streaming** one (`ghostty_snapshot_decoder_new` with a
reader callback), not `new_buf`, and it pulls from `SnapshotStream` — a pipe
that `snapshot_chunk` payloads go into and that releases each chunk as the
decoder reads it. Nothing holds a second copy of the stream, and `ready()`
needs only the bytes through the READY marker, which is what makes step 4
independent of scrollback size.

`SnapshotStream` **reports end of file when it runs dry rather than waiting**.
`snapshot.h` gives a source that can starve two options — "wait outside the
decoder or block in their callback" — and this takes the first. Blocking is
what it must not do: `ready()` runs on the main actor and `next()` runs under
the engine's lock, so a blocked callback would stall the window or the renderer
for as long as the transport took. Waiting outside the decoder is what the
caller does instead: `ready()` is called only once `snapshot_ready` has
arrived, `next()` only once `snapshot_end` has, so each phase is driven from
bytes already in hand. A read that finds nothing means the stream is malformed
or abandoned, and the decoder reporting truncated data is the right outcome:
the client falls back to a blank screen and takes live output.

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

**Fonts.** The default face is not whatever `.userFixedPitch` returns — the
app ships JetBrains Mono in its bundle, from the same tarball at the same hash
that ghostty pins, and uses it when no family is configured. Two variable
files cover four styles: bold is the upright face with the `wght` axis at 700,
bold-italic the italic face with the same, which is what `SharedGridSet.zig`
does. Italic needs its own file because asking CoreText for the italic trait
on a variable upright face hands the upright face straight back. The faces are
built from their bytes and never registered with `CTFontManager`, so they are
private to the process and never turn up in the user's font list. A named
family still wins; there is just nothing yet that can name one (#42).

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

The scrollbar marks it. `ScrollbarState` describes the **declared** scrollable
area rather than the delivered one: `pending` counts rows the snapshot has
promised and not yet sent, and both `total` and `offset` include them. The
overlay draws that region at the top of the track, dimmer than the knob.

The count comes from the decoder. `SCREEN` carries each screen's complete
logical history extent and `ghostty_snapshot_decoder_get` reports it as
`HISTORY_ROWS_PRIMARY` the moment READY validates — before a page has arrived —
so `TerminalController` declares it there, minus the resident overlap READY
already carried, and counts it down by each page's `PROGRESS_ROWS`.

The decrement happens inside the same `withLock` as the decode that earned it.
That is the whole trick and it is worth being explicit about: a page landing
adds *n* rows to the terminal and removes *n* from what is owed, so the sum
that positions the knob does not change. Split them across two lock
acquisitions and a frame can catch one without the other, which is the jump
this exists to prevent. It is also why the count is counted down rather than
recomputed from the terminal — live output pushes rows into the same history
and would otherwise be mistaken for scrollback arriving.

Three things the mechanism deliberately does not do:

- **The extent is advisory**, and `snapshot.h` says so. A page that can no longer be applied to a live terminal is still consumed and still reports zero rows, so the count is cleared outright when the restore ends rather than trusted to reach zero. Otherwise a snapshot whose pages delivered less than promised leaves a sliver of the bar pending for the terminal's lifetime.
- **The alternate screen reports nothing pending.** It has no scrollback of its own, and `canScroll` gates whether the indicator is drawn at all, so folding the primary's owed rows in would put a scrollbar over vim. Nothing is forgotten — the count is still there when the program exits.
- **A viewport scrolled to the very top still travels** as history lands, because libghostty's "top" is a position and not a pin: it means the oldest row there is, and it keeps meaning that as older rows arrive. The viewport really is moving there, and a bar that held still would be the one lying.

There is no `TerminalController.scrollbackRows` any more. It was written once
when the restore finished and read by nothing, and it could not have been the
mechanism even in principle — it is a final total, available only after the
last moment anyone would want a loading state for.

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

## Keybindings

The whole set, and where each one is registered. **Where** is the interesting
column: a chord a menu item claims is consumed by the key-equivalent pass and
never reaches `keyDown`, so the menu bar is also the list of things that can
never be typed into a terminal.

| Key | Action | Registered where |
|---|---|---|
| ⌘T | New Terminal | File |
| ⇧⌘N | New Session | File |
| ⌘W | Close the focused terminal; the window when it was the last one | responder chain — the standard Close item sends `performClose:`, and `TerminalSurfaceView` answers it |
| ⇧⌘W | Close Tab (asks first when the tab holds more than one terminal; closes the window when it is the last tab) | File |
| ⌘D / ⇧⌘D | Split Right / Split Down | File |
| ⇧⌘↩ | Zoom / Unzoom pane | File |
| ⌥⌘← → ↑ ↓ | Focus pane left/right/above/below | View |
| ⇧⌘K | Change Session — toggles the dropdown | View |
| ⌘R | Refresh Sessions | View |
| ⇧⌘] / ⇧⌘[ | Show Next / Previous Tab, wrapping | Window |
| ⌘1 … ⌘8 | Select that tab | Window |
| ⌘9 | Last tab (the iTerm/Ghostty/browser convention, not the ninth) | Window |
| Esc | Dismiss the session menu | `SessionMenu`'s `onExitCommand` — key events go where focus is, and the filter field has it |
| ⌘Home / ⌘End | Scroll to the top / bottom of the scrollback | `TerminalSurfaceView.keyDown` |
| ⌘PgUp / ⌘PgDn | Scroll one page (a screen less a row of overlap) | `TerminalSurfaceView.keyDown` |
| ⌘C / ⌘V / ⌘A | Copy / Paste / Select All | system Edit menu → responder chain |
| ⌘Q / ⌘H / ⌘M | Quit / Hide / Minimize | the system's own items |

Tab switching is scoped to the session in front: the strip shows one session at
a time, and a chord must not move the window to another session — or, with two
machines connected, to another machine. ⌘1–⌘9 are greyed out when they would go
nowhere. That is honesty, not safety: a *disabled* menu item still consumes its
key equivalent — `performKeyEquivalent` reports the chord handled and simply
does not fire the action — so ⌘5 with two tabs open never reaches the terminal
either way.

The four scroll chords are the only keys taken in `keyDown`, and they are taken
**before** `KeyTranslation` and the encoder. That order is the whole point: a
program speaking the Kitty protocol is told about keys the legacy encoding
drops, so intercepting after the encoder would let ⌘PgUp through as a key
event. It is the same rule the wheel follows — the viewport half of the surface
never synthesizes a sequence.

They are claimed narrowly, and the three exclusions each cost a bug to find:

- **⌘ and nothing else.** ⇧⌘Home is macOS's "extend selection to the top of the
  document"; ⌥⌘Home and ⌃⌘End are ordinary editor bindings under the Kitty
  protocol. A `contains(.command)` test ate all three.
- **The key-up is matched to the key-*down* this view actually swallowed**,
  never to the modifiers the release happens to carry. Letting go of ⌘ before
  the key — the ordinary way anyone releases a chord — otherwise put a release
  on the wire for a press the program never saw.
- **Only where there is scrollback to move through.** On the alternate screen
  (`vim`, `less`, `htop`) there is none, so the chord falls through to the
  program rather than becoming a dead key that eats a keystroke and does
  nothing. Without ⌘ the identical keys are always the program's: `less` gets
  its own PgUp.

Closing the session menu hands the keyboard back to the terminal. The menu's
filter field held it, and nothing in the split tree changed when the overlay
went away, so `SessionStore.focusGeneration` is bumped instead — a counter
`TerminalPane` reads in its body and passes to the surface, which makes SwiftUI
re-run `updateNSView`, which is where first responder is re-asserted. Only the
counter is under test; the rest of that chain needs a running app and was
checked by hand.

## Session and terminal switching

The dropdown lists sessions; a session expands to its terminals. Each row shows
residency — live, parked, rehydrating, exited — because parked is normal and
should look normal, not like an error.

With more than one machine connected it grows a header per host and the sessions
under it are that machine's. One host is the common case, so the headers only
appear when there is something to disambiguate.

Switching to a parked terminal is **not** an unpark: the server streams its
snapshot straight from disk and the terminal stays parked [MEM t=660]. From the
client's side this is indistinguishable from attaching to a live one, which is
the point. Do not add a spinner for it.

## Remote hosts

`ssh <dest> illogicald --stdio`, with the frame stream on the pipe. The user's
existing SSH config, keys, jump hosts and agent forwarding apply. No credential
handling of our own, and nothing to store but the destination string.

A **`Transport`** is a pair of descriptors and whatever holds them open — one
socket for a local host, two pipe ends and a child process for a remote one.
`Connection` reads and writes those descriptors and knows nothing else, so
`TerminalController`, the snapshot decode and the renderer are all identical
either way. The only line in the client with an opinion is
`ServerHost.makeTransport()`.

```
ServerHost.local ──► UnixSocketTransport ──┐
                                           ├──► Connection ──► frames
ServerHost.ssh   ──► CommandTransport ─────┘
                     ssh -T … dest illogicald --stdio
```

Two details that are not decoration:

- **`-T`.** A pty in the middle would put a line discipline on a binary frame
  stream and rewrite every `0x0a` byte a snapshot chunk carried.
- **`ControlMaster=auto`.** One connection per terminal means four splits on one
  host open five SSH connections; multiplexing makes the four after the first
  cost a channel rather than a handshake. The `ControlPath` is the one
  `src/core/conn.zig` renders, so the app and `illogical --host` share a master.

The child's stderr is drained and kept — an undrained pipe fills at 64 KiB and
wedges `ssh` — so "could not resolve hostname" survives as itself rather than as
a closed connection. It is reported only once the child has actually gone: `ssh`
writes to stderr on perfectly good connections too (the known-hosts warning on a
first connect, banners, the remote daemon's own logging), and treating any of
that as a failure made a healthy host render as the broken one.

Superlogical's server additionally has built-in Tailscale/Headscale support and
acts as a node ([MASTO]). Out of scope for us; SSH first.

## Starting the server

**Running the app is enough.** If nothing is listening on the local socket, the
app starts a server, and the server it starts outlives it.

The order matters, because the fast path must not pay for any of this. The app
connects to the unix socket exactly as it always has. Only when *that* connect
comes back `ECONNREFUSED` or `ENOENT` — a socket with nothing accepting on it,
or no socket at all — does it run

```
<Illogical.app>/Contents/MacOS/illogicald --ensure --socket <path>
```

off the main actor, wait for it to exit, and connect again. Everything after
that second connect is the path every other host takes.

**Whatever is already listening always wins.** A daemon answering that socket
owns every terminal behind it, and the app never kills, restarts or replaces
it. `--ensure` connects before it forks; if two of them race — two windows, or
an SSH bridge arriving at the same moment — `Server.listen` probes and the loser
exits without unlinking the winner's socket. A connection that is *accepted* and
then dropped is not this case: something is there, so nothing is started.

**At most one start per outage.** A daemon that starts and immediately dies
leaves the socket refusing connections exactly as before, so without that rule
every backoff tick would fork another one — four a second, against a machine
already in trouble. The permission comes back on the next `session_list`, which
is the frame that proves the outage is over, and on the user pressing Try Again.

**And at most one start per ten seconds of server.** A `session_list` proving
the outage is over is exactly right for a daemon that ran for a day and then
died, and exactly wrong for one that starts, answers `list`, and dies on its
first attach — a corrupt park file, a full disk on `park.key`. That one clears
the rule above on its way past and gets replaced by an identical copy of itself,
three times a second, forever. So a server *this app started* which stops
answering within ten seconds of coming up is not started again: the host goes to
"no server" naming `daemon.log`, and stays there until somebody presses Try
Again.

Four things this deliberately is not:

- **Not `illogicald --stdio` locally.** The bridge would give spawn-if-missing
  away for free, and it would put a process and a byte copy on every *local*
  connection — one per terminal, so a window with four splits is five bridges.
  M5 measured the bridge at +10% on a whole snapshot. The local path stays one
  `connect()`.
- **Not a reimplementation in Swift.** `fork()` in a multithreaded Cocoa process
  is not safe, so it would be `posix_spawn` with `POSIX_SPAWN_SETSID` and
  `POSIX_SPAWN_CLOEXEC_DEFAULT` and file actions for the log — a second
  implementation, in a second language, of a double fork that
  `src/daemon/stdio.zig` already does and already tests on both platforms in
  CI. And the local and SSH spawn paths could then drift apart, which is a whole
  class of bug that one code path cannot have. The SSH path *is* this path with
  a pipe in front of it.
- **Not a `Process` holding the daemon.** That daemon would be a child in the
  app's process group and session, holding the app's pipes: Xcode's Stop button,
  `pkill -f Illogical`, a crash reporter's group kill, or the `Process` object
  being deallocated could each take it. `--ensure` exits; what it leaves behind
  is two forks away, `setsid`'d into a session of its own, with `/dev/null` for
  stdin and stdout, `daemon.log` for stderr, and `closeFrom(3)` having dropped
  every inherited descriptor. Nothing ties it to the app — not the process
  group, not the session, not a controlling terminal, not a descriptor — so ⌘Q
  and a crash both leave the terminals running. `scripts/smoke-ensure.sh` is the
  proof: it SIGKILLs the starter's entire process group and the daemon keeps
  answering. Logging out does take it, exactly as it takes a hand-started one.
- **Not a launchd agent or `SMAppService` login item.** That would hand the
  daemon's lifecycle to launchd — bundle-path-bound, restarted on its terms,
  registered per user — and split the story from the CLI and SSH paths, which
  use the detached model. Its supervision is not something we want anyway: a
  daemon that exits is a daemon whose terminals are gone, and nothing launchd
  does brings those back.

Two macOS consequences worth knowing about:

- **TCC responsibility is inherited.** Shells under an app-started daemon are
  attributed to `Illogical.app` for Files & Folders and Full Disk Access
  prompts. That is what a Terminal.app user expects, but it differs from a
  daemon started *from* Terminal.app, which is attributed to Terminal — so
  somebody who granted Full Disk Access there will be asked again.
- **The daemon inherits launchd's environment, not a shell's.** No `LANG`, and a
  `PATH` of `/usr/bin:/bin:/usr/sbin:/sbin`. `pty.zig` repairs the locale; the
  server spawns `$SHELL -l` so that `path_helper` and the user's own `zprofile`
  repair the `PATH`. Without the login shell, no terminal opened from the app
  would find brew.

**The seam.** `ILLOGICAL_DAEMON` names the executable to run, read in one place
(`LocalDaemon.executable()`) — the local analogue of `ILLOGICAL_SSH`. Above it,
`DaemonLauncher` is injected into `SessionStore` and `HostConnection`, so
`ReconnectTests` uses a recording stub and never spawns anything. The launch
budget is untouched by construction: `store.connect()` already runs in `.task`
after the first layout, and `--ensure` runs in a `Task` off the main actor while
the host sits in `.connecting` — the one status the "no server" screen does not
take over for.

## Losing the network, and getting it back

**Reconnecting needed almost no new machinery, and that is the point.** A
connection that goes away is a client that has missed output; the protocol
already recovers from that by throwing the terminal state away and replaying
the attach handshake, which is O(screen). So the only new question is *when* —
an exponential backoff from 250 ms to a 30-second ceiling, retried forever. A
laptop closed overnight should find its terminals in the morning, and "give up
after five minutes" is exactly the case where that fails; the ceiling is what
makes forever cheap.

```
connection closes ─► .reconnecting ─► attach ─► snapshot_begin ─► PAINT
                       (backoff)                 tears down the old terminal,
                                                 the same way a desync does
```

Three things this deliberately does **not** do:

- **It does not blank the screen.** The last thing a terminal showed is still
  the best guess at what it shows, and the far side never stopped. A dropped
  packet should not look like a crash. A pill over the terminal says what is
  happening, with a Retry that skips the backoff.
- **It does not drop the host's session list.** Clearing it when a control
  connection closes would take every tab on that machine with it through the
  reconcile — closing panes and their connections over a blip. The `list` after
  the reconnect corrects it, because the *server* is what remembers. Which is
  the premise of the whole project.
- **It does not treat a first failure differently from a later one.** A host
  that was never reachable and one that went away are the same question.

There is one exception to "retried forever", and it is about the *kind* of failure rather than how many there have been: a host that cannot be dialled at all — `ssh` not on `PATH`, a socket path too long for `sockaddr_un`, an `ssh` that is not an executable program — is marked `failed` and left alone, because rescanning `PATH` on a thirty-second timer tells nobody anything. Everything else keeps trying.

The line between the two is drawn on the errno rather than on the shape of the failure, and that matters more than it sounds: `Process.run()` throwing is `EMFILE` as readily as it is a broken shebang. A remote connection costs three descriptors, so a window with enough panes open reaches `EMFILE` by itself and recovers the moment one closes — calling that a verdict would kill a perfectly reachable machine for the life of the process. `CommandTransport.spawnError` is where the two are told apart.

A resize during an outage is remembered and carried into the re-attach, so a
window resized while disconnected comes back at the size it is now.

Over SSH the control connection and every terminal's share one TCP connection
underneath, so a network coming back recovers them together and only whichever
gets there first pays for a handshake. `ServerAliveInterval` is what makes a
dead network *become* a closed connection at all — without it a laptop that
changed networks waits indefinitely on a socket with nobody behind it.

One thing that had to be fixed before any of this worked: a write to a socket
or pipe whose far end has gone raises `SIGPIPE`, and the default disposition is
to kill the process. A daemon going away with a keystroke in flight is the
ordinary case here, so the recovery path was the one that killed the app.
`SO_NOSIGPIPE` on the socket; the process-wide disposition for the pipe, which
has no per-descriptor equivalent.

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
