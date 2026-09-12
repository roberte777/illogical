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
│   └── Fonts/      JetBrains Mono and the Nerd Font symbols, shipped
├── Terminal/
│   ├── TerminalEngine.swift     libghostty-vt wrapper + snapshot extraction
│   ├── TerminalColors.swift     the config's colours, resolved for libghostty
│   ├── SnapshotRestore.swift    two-phase attach decode
│   ├── TerminalController.swift one connection, one terminal
│   ├── TerminalSurfaceView.swift  NSView host, layer, input
│   └── Renderer/                Metal renderer, atlases, fonts, sprites

Packages/IllogicalKit/
├── IllogicalProtocol           pure Swift, no libghostty — testable alone
│   ├── Frame.swift             the wire header
│   ├── Connection.swift        reader thread, frame stream, serialized writes
│   ├── Transport.swift         unix socket, or `ssh <dest> illogicald --stdio`
│   ├── LocalDaemon.swift        starts the local illogicald when there is none
│   └── Session.swift           sessions, terminals, hosts
└── IllogicalConfig             the config file, in Ghostty's format
    ├── ConfigSyntax.swift      key = value, comments, quoting
    ├── Config.swift            the keys, and what setting one does
    ├── ConfigColor.swift       colours, palette entries, cell-relative ones
    ├── X11Colors.swift         rgb.txt, embedded and read on first use
    ├── ConfigTheme.swift       one theme, or a light/dark pair
    ├── ThemePath.swift         where a theme is looked for, and in what order
    ├── ConfigPath.swift        XDG and Application Support
    ├── ConfigLoad.swift        reading the files, and the diagnostics
    └── ConfigTemplate.swift    the file written when a machine has none
```

Transport is in the package rather than the app on purpose: it is the half of
remote support that can be tested without a window, a GPU or a daemon, and
`just test-swift` runs it in under a second. The config parser is there for the
same reason. The two are separate targets because they answer to different
machines: the protocol to the one the terminals run on, the config to the one
you are sitting at.

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
Which machine a *pane* is on is in its own header, because a tab has one strip
entry and a split tab could otherwise say nothing about it.

**Which machine you are looking at is stored, not derived.**
`SessionStore.currentHost` is what ⌘T makes a terminal on, whose sessions the
tab strip draws, and what the session button names. Selecting a tab moves it —
one funnel, so the toolbar and the next ⌘T cannot disagree — and View ▸ Switch
Host sets it directly. Read off the front tab instead, "which machine" could
only ever be a machine with a terminal on it: an empty one was somewhere the
window could not be, and a window with no tabs at all fell back to "the first
host that is connected", which quietly sent ⌘T to a machine nothing on screen
named. A machine with nothing on it now shows the empty screen rather than
borrowing another machine's tabs, and one that cannot be reached shows `ssh`'s
own complaint with a Try Again that dials that machine alone.

The window remembers the session last in front **on each host**, so coming back
to a machine lands where you left it rather than on its first session. Across
launches it remembers one thing: the machine, and the *name* of the session in
front on it. The name and not the id, because `next_session_id` is a daemon's
in-memory counter and a machine that has rebooted renumbers everything it still
has. The name is simply absent when nothing was in front — end the day on a
machine with no sessions and you reopen on that machine's empty screen, which is
the same claim as the rest of this section, that an empty machine is a place the
window can be. It is written through as it changes, since there is no
termination hook in this app and a write at exit is one a force-quit loses. The
window opens on that machine immediately — showing the empty screen for the
length of the handshake, rather than opening on the local daemon and yanking
itself away a second later — and lands on the session when the machine answers.
Any explicit move you make first voids the restore, whether it lands on a tab or
on an empty machine.

Hosts are remembered in `UserDefaults`, and there is no credential among them:
`ssh` reads the user's own config, so a `Host` alias out of it is a perfectly
good answer. Only what the *user* added is written — hosts injected by
`ILLOGICAL_HOSTS` are deliberately not, so a session started with that variable
does not quietly make them permanent the first time you add or forget anything
else. The front session above obeys the same rule, for a sharper reason: a
window standing on an injected host — or on the throwaway daemon
`ILLOGICAL_SOCK` names, which is how `scripts/bench-launch.sh`,
`bench-attach.sh` and `bench-remote.sh` launch the shipped app — would write a
machine that is not in the list next launch, so the restore is dropped and the
session you were *really* last in is gone with it.

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
down, zoom, close — with zoom and close both disabled in a tab with one pane.
There is nothing to zoom out of, and the ✕ closes *a pane*: in an unsplit tab
the only pane is the tab, so a live one would take the whole tab from a control
that never said it could. Closing a tab is the strip's ✕, which says so.

Focus is AppKit's. The pane the layout calls focused is whichever surface is
first responder, reported back by the surface, rather than a SwiftUI tap
gesture layered over the terminal that would swallow the clicks selection
needs.

**⌘W closes the focused terminal.** It reaches the surface as `performClose:`
through the responder chain, so the terminal gets first refusal without
fighting the standard Close Window item for the chord. The window closes only
when that terminal was the last one in it — the condition is
`tabs.count > 1 || tab.isSplit`, and it counts *every* tab the window holds,
not the strip's. A window whose front session shows one tab may be holding tabs
elsewhere, and closing it would take those with it (issue #41) — so the window
stays, and where the selection goes depends on where they are. On another
session of the machine you are on, it moves to them. On another *machine*, it
does not: you are left standing on the machine you were on with an empty strip,
because stealing a tab would move the toolbar, the strip and the next ⌘T
somewhere nobody asked to go.

The policy is `SessionStore.closeSurfacePane` and not the delegate method over
it, so "does ⌘W close the window" is a question a test can ask without a window.

**⇧⌘W closes the whole tab** — as does the ✕ in the tab strip, and a pane's own
✕ is ⌘W for that pane, in the splits where it is live. All four routes answer
to the same two store calls — the chord keeps the cases the button drops, since
⌘W is allowed to mean both and a button is not — and the window half of each
goes through `WindowClose`, because they used to disagree: ⌘W on the last
terminal closed the window and left the shell running, while ⇧⌘W on the same
terminal hung it up and left an empty window behind.

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
private to the process and never turn up in the user's font list.

The icons ship too. Neovim's file trees and statuslines draw with Nerd Font
glyphs, which live in the private use area and are in no ordinary text font;
on a machine with no Nerd Font installed the cascade came back empty. What the
cell then drew was not nothing: `TextShaper` substitutes U+FFFD for a
codepoint no face resolves, JetBrains Mono has that glyph, and the constraint
is computed from the cell's *own* codepoint — so a file tree came out as a row
of replacement characters, each one rescaled by the patcher rule belonging to
the icon it stood in for. The bundle carries Symbols Nerd Font, the symbols-only face
the nerd-fonts project publishes for exactly this, from the tarball ghostty
pins at the same hash, and the grid searches it last for every style. That is
ghostty's arrangement rather than a patched JetBrains Mono, and the reason is
the fallback order: the symbols sit behind every configured family, so the
icons survive a `font-family` of the user's own. The file is the unpatched
one, so the icons are fitted to their cells per codepoint by
`NerdFontConstraints`, which is the patcher's own arithmetic transpiled from
libghostty.

A configured family wins, and the shipped fonts stay behind it as fallbacks
rather than being replaced by it — see **Configuration** below.

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

## Search

`search.h` is incremental by design: `tick` makes bounded progress on data the
search has already copied and never touches the terminal, `feed` reads the
terminal to pick up changes, and the caller decides how much of each a frame
may cost. Who that caller is, is the only real design decision here — and it is
the find bar, not the render thread. `SearchSession` pumps on the main actor
while the bar is on screen: at frame rate until the search reports complete,
slowly after that, because feeding is the only way a search learns about new
output or a moved viewport. Closing the bar drops the needle, so a terminal
with no find bar over it does no search work at all.

Everything that touches the terminal — the needle, a feed, stepping to the next
match — goes through the engine's lock, the discipline selection already
follows and for a sharper reason: a match is an **untracked** grid reference,
valid only until the next byte of output. Reading the viewport's matches and
converting them to cells is therefore one operation under that lock, in
`updateSnapshot`, beside `begin_update`.

A match is a selection over two grid references and nothing more — Ghostty's
own `RenderState.Highlight` is not in the C API — so mapping matches onto
per-row cell ranges is ours. The renderer takes them as the four-way
`{ plain, selection, search, search selected }` value Ghostty carries where we
had a `selected: Bool`, with one colour pair for a match and another for the
one you are standing on. Like a selection, a highlight changes no cell, so the
frame is rebuilt in full when the set of them moves — and doing that has to
*wake* the render loop, which pauses after a second of quiet.

A search is bound to the terminal it was created with and cannot be rebound, so
`adopt` makes a new one and gives it the same needle: a find bar open across an
attach keeps looking for the same thing.

### The find bar floats, and gets out of the way

The bar is an overlay on the surface rather than a row above it. A bar that
took its own space would resize the PTY every time ⌘F was pressed — a
`winsize` change, a resize sequence to whatever is running, and a reflow of the
very screen being searched.

The price of floating is that it covers something, and the one thing it must
not cover is the match it has just taken you to. So it moves: `SearchNudge`
steps the bar down past that match, and `SearchBar` animates the difference.
Down rather than sideways, because what it is dodging is text on a grid —
moving left would put the bar over the middle of a line, which is where output
actually lives, while moving down lands it in the gap between two rows.

The *selected* match, and no other. Dodging every hit on screen was the first
shape this had and it is the wrong one: a query with a column of matches down
the right-hand side walks the bar past all of them and halfway down the window,
to keep clear of hits nobody is looking at. The selected match is the one the
search scrolled to and the one the count is counting; the rest are context, and
context is allowed to be behind a floating bar.

That geometry is a pure function of two rectangles and a list, which is what
makes "the bar gets out of the way" something a test holds rather than
something you check by looking at it.

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
| ⇧⌘P | Command Palette — toggles the panel. Everything in this table that is a menu item, searchable, plus Add Remote Host and Forget Host | View. The slot is free because `CommandGroup(replacing: .printItem)` removes SwiftUI's default Page Setup… (⇧⌘P) and Print… (⌘P): the app prints nothing, and two items claiming one chord resolve by menu order |
| ⌘K | Change Session — toggles the dropdown. Unshifted, so the terminal cannot be sent ⌘K | View |
| ⌘R | Refresh Sessions | View |
| ⇧⌘] / ⇧⌘[ | Show Next / Previous Tab, wrapping | Window |
| ⌃⇥ / ⌃⇧⇥ | The same two, under the chord every browser uses | `ContentView.onTabCycle` — a local `NSEvent` monitor |
| ⌘1 … ⌘8 | Select that tab | Window |
| ⌘9 | Last tab (the iTerm/Ghostty/browser convention, not the ninth) | Window |
| ⌘F | Find — opens the find bar over the focused pane, keeping the last query | Edit |
| ⌘G / ⇧⌘G | Next / Previous match, wrapping; greyed out with no bar open and nothing found | Edit |
| Esc | Dismiss the session menu, the command palette, or the find bar | each one's `onEscape` — a local `NSEvent` monitor, alive only while that overlay is |
| ↑ ↓ / ⌫ | Move the palette's highlight, skipping rows that cannot be run; ⌫ on an empty argument field takes the command's chip back to the list | `CommandPalette.onPaletteKey` — a local `NSEvent` monitor, alive only while the palette is. Bare keys only: a modified arrow is a chord, so ⌥⌘↑ passes through to Focus Pane Above rather than moving the highlight |
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

⌃⇥ is the one tab chord that is not a menu item, because it cannot be: AppKit
gives a menu item a single key equivalent, and Show Next Tab spends its on the
⇧⌘] the Window menu has to go on displaying. Safari and Terminal.app carry both
by hanging a second, hidden item off the same action, which SwiftUI's `commands`
has no spelling for — so it is `onEscape`'s local monitor again, which runs
inside `sendEvent(_:)` and drops what it claims, and therefore keeps the same
promise the menu bar does. It claims ⌃⇥ **and ⌃⇧⇥ only**: bare ⇥ is completion
in every shell, ⌃C is the program's, and a `contains(.control)` test would have
taken both. It claims them even with one tab open, so the chord means one thing
rather than depending on how many tabs happen to be there.

The monitor also swallows the matching key-*up*, matched to the key-down it
took rather than to the release's own modifiers — the rule the scroll chords
follow, for the same reason. Nothing else in the app needs it: every other
chord carries ⌘, and AppKit delivers no `keyUp` at all while ⌘ is held.

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

The other half is that the surface stands down while either overlay is up —
`SessionStore.overlayHoldsKeyboard`, the same rule the find bar already had.
`updateNSView` runs whenever SwiftUI updates the representable, which is not
only when `focusGeneration` asks: a terminal appearing on any machine rewrites
`tabs`, which the surface reads. Without the stand-down each of those updates
took the keyboard back from the panel's field, so ⌘K and ⇧⌘P opened a panel
that could not be typed into and whose Return (`.onSubmit`) went to the shell —
while the arrows, which `PaletteKeys` takes off the event stream before first
responder is consulted, went on working and made the panel look as though it
had the keyboard.

**Escape does not go where focus is.** W10
shipped Escape as `.onExitCommand` on `SessionMenu`'s root, on the stated
assumption that the filter field takes first responder as the menu appears. It
did not hold: with the menu open the app's `AXFocusedUIElement` was still the
terminal surface underneath and the field's `AXFocused` was `false`, so nothing
in the menu was ever in the focus chain, `.onExitCommand` never fired, and
Escape went to the terminal. (Click the field first and Escape *does* close the
menu — which is how the mechanism was pinned down, against the running app.) So
Escape is a local `NSEvent` monitor instead — `View.onEscape`, in
`EscapeKey.swift` — which runs inside `NSApplication.sendEvent(_:)` and does not
care what holds first responder. It is installed by the menu's `onAppear` and
removed by its `onDisappear`, so Escape belongs to the terminal the rest of the
time, and it returns `nil` so the keystroke that closed the menu is not also
delivered underneath it. Both halves were checked against a terminal running
`cat -v`: with the menu closed, Escape puts `^[` on its screen; with the menu
open, the menu closes and the screen does not change. The field not holding
focus turned out to be the surface taking it back (above), and the monitor stays
now that it no longer does: it never depended on where first responder is.

Clicking away *does* dismiss the menu and always did — the full-window
`Color.black.opacity(0.001)` layer under it works. A report that it does not is
worth re-checking with a real click: a synthetic one built from `leftMouseDown`,
a run of `leftMouseDragged` at the same point, and `leftMouseUp` fails SwiftUI's
`TapGesture`, which is movement-sensitive, and looks exactly like a broken
dismiss layer.

## Session and terminal switching

The dropdown lists sessions, one row each, and switching to one brings its tabs
to the front. It does **not** expand a session to its terminals: the tab strip
is where a session's terminals live, and a dropdown that listed them again
would be a second, worse tab strip. Residency — live, parked, rehydrating,
exited — is shown on the tab itself (`Chrome.swift`, `TerminalTab`), because
parked is normal and should look normal, not like an error.

With more than one machine connected it grows a header per host and the sessions
under it are that machine's. One host is the common case, so the headers only
appear when there is something to disambiguate.

Switching to a parked terminal is **not** an unpark: the server streams its
snapshot straight from disk and the terminal stays parked [MEM t=660]. From the
client's side this is indistinguishable from attaching to a live one, which is
the point. Do not add a spinner for it.

Tab **order** is this window's and nothing else's. The server has no opinion
about it — a session is a set of terminals, not a list — so dragging a tab along
the strip is `SessionStore.moveTab` and nothing about it leaves the process
(issue #38). A drag across two sessions is refused rather than reordered: the
strip only ever draws one session's tabs, so a cross-session order is one it
could not show. Order does not **survive a relaunch** either: `reconcileTabs`
builds the list from each host's `session_list`, so a new window is back to the
server's order. #38 argues that is right — layout is per-window client state —
and persisting it is a feature rather than polish.

The drag is a `DragGesture`, not `.draggable`/`.dropDestination`. Most of a
197 pt slot is the select button's hit area, and a control that takes the
mouse-down is the documented way for a `.draggable` on macOS to never start at
all; a reorder that silently does nothing would be worse than none. The gesture
is attached with `simultaneousGesture` so it runs beside the button rather than
against it, which also means the button still fires on the mouse-up that ends a
drag — a dragged tab comes to the front, the way it does in every tabbed app.

What the strip *does* with the drag is the native tab bar's answer, and it is
three things at once. The dragged slot is **lifted** — an opaque ground, an
edge and a shadow, so a tab with no fill of its own does not read through the
one it is passing over — and **carried** under the pointer, held inside the
strip so it stops at the first slot and the last rather than sailing out over
`+`. Every other slot **slides** to where it would be if you let go, so the gap
under the pointer is the answer and there is nothing left to annotate. At the
mouse-up all three unwind inside one `withAnimation` alongside `moveTab`, and
because they add up the tab travels continuously from under the pointer into
its slot instead of snapping.

The first version drew none of that: the strip held still and outlined the slot
the tab pointed at, on the grounds that fixed-width slots laid edge to edge
would have to shove their neighbours to open a gap. They do, and that shove is
the whole effect — what made it read as broken was doing it once, at the drop.

Four pure functions in `TabStrip` carry it, and they are the part that is
unit-tested; the gesture plumbing around them cannot be simulated.
`dropIndex` turns a translation into a slot, `clampedTranslation` holds the
carried tab inside the strip, `displayOrder` gives the order the strip is
*drawn* in on this frame — which is where both the slide (a slot's drawn
position less its stored index) and the hairlines come from, so a separator
travels with its tab instead of staying behind at an index, and neither side of
the gap draws one — and `slot(at:)` says which slot a pointer is in.

**Hover is the strip's, not each slot's.** One hovered slot held by the strip,
set from the pointer's position — by a local event monitor as it moves, and by
the drag gesture while a button is down. The difference
is the case a flag cannot answer: a drop rearranges the tabs under a pointer
that never moved, so every flag then describes the arrangement before it — the
tab you just dropped sat under the pointer believing it was not hovered, with
no ✕, until you took the pointer out to the terminal and brought it back,
because that was the next enter event it would see. `Cursor.swift` documents
the same bug from the other direction, where a view leaves under a stationary
pointer and its `onHover(false)` never arrives. A stored *position* survives
the reorder that caused the trouble: the region the pointer is in did not
change, and which tab is drawn there is read off the new order. The position is
written only when it crosses into another slot, so this costs no more redraws
than the flags did.

The event source is a **local `NSEvent` monitor** (`PointerTracker` in
`WindowChrome.swift`), which is a strange answer to "is the pointer over this
view" and the only one that works here. Every ordinary way of asking stops
reporting to a view once a drag ends on it — SwiftUI's `onHover` and
`onContinuousHover`, and an `NSTrackingArea` on the same view — and stays
silent until the pointer leaves the window and returns. Every drop ends a drag
under the pointer, so that is precisely when the strip needs an answer and
precisely when it stops getting one.

This was measured, not reasoned; three fixes reasoned their way to the wrong
mechanism first. In one traced reproduction, after the drop: **0** events from
the tracking area, **0** from SwiftUI's hover, **390** from the monitor. The
window never stops *generating* the events — delivery to the view is what
breaks — so a monitor, which watches what the app dispatches rather than what a
view is offered, sees all of them. It needs
`window.acceptsMouseMovedEvents = true`, which `WindowChrome.configure` sets:
without it the window makes no mouse-moved events for anyone at all, monitor or
tracking area, and SwiftUI turning it on for its own hover tracking is not
something to depend on.

A **drag does not select.** The select button and the drag run side by side, so
the mouse-up that finishes a reorder also fired the button under it and opening
a tab was the price of moving it. The button stands down once the drag
threshold has been passed — reordering and selecting are different intentions,
and a click that never became a drag still selects.

The ✕ on a slot appears on **hover**, on every tab including the active one. It
sat on the active tab permanently until it did not: that parks a close button
under the pointer's usual resting place on the tab you are most likely to be
clicking, and gives the active slot a different shape from every other one.
File ▸ Close Tab and the ⇧⌘W beside it are the discoverable path. The strip
holds hover false on *every* slot for the length of a drag, which is also what
keeps the ✕ off a tab in flight: the dragged slot rides under the pointer, so
the mouse-up that ends the drag would otherwise land inside its close button —
dragging a tab by its ✕ closed it, measured.

### The name a new session starts with

⇧⌘N names the session it makes rather than numbering it: two words and a
hyphen, drawn from the lists in `SessionNames` — `drifting-cedar`,
`cosmic-summit`. What that replaces is `session-1`, `session-2`, `session-3`,
and the reason is that a session name is the one label this app asks you to
recognise. It is what the dropdown lists, what the session button says, what ⌘K
matches against and what `illogical rename` takes; three numbers on screen at
once are three rows you cannot tell apart without opening each. The machine
already has an identifier for a session — the id, which every frame carries and
no user ever reads.

The name is a *starting* name. Rename is right there, and `drifting-cedar`
being obviously arbitrary is part of it: nothing about it claims the app knows
what the session is for, so it reads as a handle rather than as a description
that has gone stale.

**The draw avoids names already on that machine, and that is not cosmetic.** A
`create` is addressed by name and `Server.sessionByNameLocked` *joins* a
session whose name it already has rather than refusing it — so a name that is
already there does not make a confusingly-labelled second session, it makes no
session at all and opens a second tab in the one that was there. That was the
whole of the `session-N` bug this replaces (`count + 1` named a session still
on screen, once a lower-numbered one had been deleted), and it survives the
change to random names, so the check does too. Sixteen draws, then the last
pair plus the lowest free number: the numbered fallback is reachable only by a
machine holding a large share of the 9,120 pairs, and it is the one step that
cannot fail to terminate.

Both word lists are ASCII, lower-case and free of `-`, so every pair satisfies
the naming rule below. That is load-bearing in the same way the typed-name
check is: a word added later with an apostrophe in it would not make one odd
session, it would make ⇧⌘N do nothing at all, for everyone, whenever it came
up. `SessionNamesTests` holds every word against `SessionName.isValid` rather
than against a reading of the list.

What this does *not* close is the race — two ⇧⌘Ns inside one SSH round trip
both read `host.sessions` before either `created` lands. Random names make a
collision there far less likely than `session-1` twice did, which is an
improvement and not a fix; "A session is addressed by name on the way in" below
is what closing it would actually take.

### Renaming and deleting a session

Right-click a session row: **Rename** turns the row into a text field in place
— Enter commits, Escape cancels — and **Delete…** asks first. Both are also in
the File menu, disabled when no session is selected; Rename Session… there
opens the dropdown with that row already a field, because the field *is* the
row and there is no second place to read the name.

Delete is additionally disabled — in the File menu and in the row's own context
menu — while that machine is being reconnected to. The rows stay listed through
an outage on purpose (`controlClosed` keeps `sessions`: the machine is still
running them), so they look exactly as live as they did a second before while
nothing sent can leave the process. Offering an irreversible action there asked
somebody to confirm something that could not happen.

Neither is optimistic. `rename_session` and `delete_session` have no positional
reply: the server answers a success with the `sessions_changed` broadcast every
client re-lists on, and a failure with an `err` on the control channel. So the
name changes everywhere at once, when the server says it has, and a refused
rename simply is not there on the next list. Nothing holds a session by name —
`TabLayout.session` is a `SessionRef`, which keys on the id — so a rename moves
no tab and no selection.

Delete cascades, always: the app has already asked. (`only_if_empty` is on the
frame for scripts that want to be careful; the app never sets it.) Confirming
takes the session's tabs immediately and closes their connections, because the
server is a SIGHUP, a child exit and a maintenance tick away, and the lists it
sends in between still name every one of those terminals — the same `closing`
mechanism that stops a closed pane being resurrected covers it. The server's
own cascade is what ends the terminals, so the client sends no `kill` beside
the delete.

**The request goes first; the window is torn down only if it left.** Both
halves of that matter. `HostConnection` sends on a control connection that is
nil for the whole of a reconnect, so tearing down first destroyed a window's
state on the strength of a `try?` — the tabs went, `closing` pinned those
terminals invisible for the life of the process (it is only ever intersected
with what is *live*, and they stayed live), and the next click on that session
made a third terminal, all under a dialog that had just said "This cannot be
undone." And the session is re-checked at confirm time rather than trusted from
when the dialog was built: its last terminal can exit while the question is on
screen, and `delete_session` for a session the server has already retired is
answered `no_such_session`, which is an `err` — see the create-voiding
paragraph below.

**Session names somebody typed are checked client-side, with the server as the
authority.** The rule is 1–64 bytes of `[A-Za-z0-9._-]`, mirrored in
`SessionName.isValid`. That is load-bearing rather than polite: a `create` the
server refuses produces no `created` frame at all, and the `err` it sends
instead voids *every* create outstanding on that host — the frame does not say
which one failed — so an unchecked typo in the filter field turns a ⌘D split
that was already in flight into a tab. A rename has the same consequence and
one more reason to check, since you rename *towards* names you already use.

There is one rule and one place it lives, because the two halves have to agree
and did not: `SessionStore.filterOffer` decides both whether the Create row
appears and what is shown instead, and `SessionStore.renameRefusal` decides
both whether the rename field is amber and whether Enter sends. A refused name
puts the reason where the Create row would be (`SessionNameRefusal`) rather
than leaving Enter to do nothing. Two things that rule covers beyond
`isValid`:

- **Trimming.** Leading and trailing whitespace is a typing artefact, so it is
  removed before anything is checked or sent — `work ` renames to `work`. Only
  the ends: an inner space is a real character in a name the server will not
  take, and deleting it would make a session under a name nobody asked for.
- **Names already in use.** Refused before sending, per machine (names are
  unique per daemon, so a name used on a remote box does not block a local
  rename) and by exact comparison, mirroring `Server.renameSession`'s
  `mem.eql`. A session keeping its own name is not a collision.

**Names that came from the server are not checked.** Only typed ones are. ⌘T,
the `+` button, the empty-state button and ⌘D all derive their session name
from what the daemon listed, and this app supports talking to daemons it did
not ship — one older than the naming rule may be holding a session called
`my project`. Refusing that here would make all four do nothing, with nothing
on screen saying why: the silent no-op the check exists to prevent, turned on
the user. `SessionStore.createName` is the single place that decides, and every
create in the app goes through it.

### A session is addressed by name on the way in (residual, #37)

`create` carries a `session_name`, not a session id — issue #37 notes this
under "the session ID has to stay stable across a rename". Everything the
client *holds* is keyed by id (`SessionRef`), and rename and delete are
id-scoped frames, so the audit passes for those. `create` is the exception, and
it cannot be fixed from this side: `SessionStore.createName` has to resolve the
tab's `SessionRef` back to a name at send time, out of the last list.

The window where that is wrong is between a rename being sent and the
`session_list` that follows it — one round trip locally, up to a few hundred
milliseconds over SSH. Rename `work` to `done` and press ⌘T inside it and the
create carries `work`, which `Server.sessionByNameLocked` **creates** rather
than failing on: a second session appears under the old name. With ⌘D the new
pane is spliced into a tab whose `SessionRef` still points at the renamed one.

Closing it means a session id on `create` (and `sessionByNameLocked` refusing
to invent a session for a `create` that named one), which is server work and a
protocol change. Until then this is a known residual, not a fixed bug.
**A tab slot has to claim its own mouse-down, or the title bar takes it.** The
toolbar is an `NSTitlebarAccessoryViewController` (see `WindowChrome.swift`),
and AppKit decides what in a title bar drags the window per *view*, from
`mouseDownCanMoveWindow`. Every view an `NSHostingView` puts there answers
`true` — the default for anything not opaque, which nothing SwiftUI draws is —
so the whole accessory was window chrome. The window's drag loop took the
mouse-down, the `simultaneousGesture` never started, and drag-to-reorder as
shipped in #64 moved the *window* by the drag delta and reordered nothing; a
drag begun on `+` moved the window and made a terminal on the mouse-up.
`View.claimsMouseDown()` puts a one-line `NSView` behind the slot, the session
button and `+`, whose only job is to answer `false`.
`window.isMovableByWindowBackground` is a different knob and was already
`false`, which is why the terminal body ignored a drag while the strip above it
did not. The `Spacer` between the strip and `+` is deliberately left un-claimed:
empty toolbar drags the window, and that is a feature.

The ✕ is hidden on the slot being dragged. The dragged slot rides under the
pointer, so its ✕ rides with it, and the mouse-up that ends the drag lands
inside the close button — dragging a tab by its ✕ closed it. With the ✕ gone for
the length of the drag the mouse-up lands on the select button instead, which is
what the strip wants anyway.

None of that is unit-testable: a draggable region needs a window on a screen.
`ClaimsMouseDown.BackingView.mouseDownCanMoveWindow` is asserted, and it is
honest about covering one line. Everything else here was checked by driving the
built app with synthetic `CGEvent`s and reading window and button geometry back
through the accessibility API — always normalising button x by the *window's*
position, because a bug that moves the window hides in coordinates that do not.

## Motion

The chrome animates. The terminal does not.

| Surface | What it does | Duration |
|---|---|---|
| Session dropdown | fades and grows from its top-left anchor | 120 ms, ease-out |
| Tab strip | slots fade in and out; the active pill slides between them | 180 ms, snappy |
| Tab drag | the dragged slot tracks the pointer un-animated; the drop-target outline fades in | 180 ms, snappy |
| Splits | a pane fades in while the frames grow around it; zoom likewise | 160 ms, ease-out |
| Reconnect banner | slides down from the top edge and fades | 200 ms, ease-out |
| Content area | crossfades between terminals, "no terminals" and "no server" | 150 ms, ease-in-out |
| Residency badge | fades, so parked does not pop | 120 ms, ease-out |

Three things deliberately do **not** animate:

- **Switching tabs.** It is what this app does most often, and it has to feel
  like nothing happened. The only motion when you click another tab is the pill
  sliding; the surface underneath swaps between two frames. That is also why the
  content area's crossfade is keyed on *which screen* is showing rather than on
  the selected tab, and why a split that arrives in a background tab brings that
  tab forward outside the animation.
- **The divider drag, and the tab drag.** Both track the pointer 1:1, so neither
  `setRatio` nor the dragged slot's offset is ever wrapped in an animation. Only
  the split tree's *topology* changes are — a pane appearing, closing, zooming —
  which animate because `SplitPair`'s frames are a pure function of ratio and
  topology.
- **Anything before the first frame.** Every animation here hangs off a state
  change that cannot happen until the window is on screen, which is what keeps
  the launch budget (G7) where it was.

All of it is gated on `accessibilityReduceMotion`: with the system setting on,
every duration becomes `nil` — SwiftUI's "do it now" — and every transition
becomes a plain crossfade. Two pure functions carry that,
`Motion.animation(reduceMotion:)` and `Motion.entrance(reduceMotion:)`, and both
are pinned by the tests. They are not merely a convention views are trusted to
follow: `Motion`'s stored entrance is private and the only way to an
`AnyTransition` is through the gate, because `AnyTransition` is opaque enough
that a check living inside one could be deleted with every test still green.
Views read the setting from the SwiftUI environment; `SessionStore`, which has
none, reads the same setting through
`NSWorkspace.accessibilityDisplayShouldReduceMotion`. Durations live in `Motion`
rather than at the call sites, so the app has a vocabulary instead of eleven
magic numbers.

One consequence of animating the split tree is worth knowing about, because it
bit twice. A topology change moves the surviving pane to a new position in the
view tree, so SwiftUI builds it a **new** `TerminalSurfaceView` over the *same*
`TerminalEngine` and keeps the old one alive for the length of the transition.
Anything the engine holds per-view therefore has two claimants at once, and the
teardown of the outgoing one used to clear the wake callback the live one had
just installed — after which the display link paused on schedule and the pane
stopped repainting until it was clicked. `TerminalEngine.bind`/`unbind` are
keyed on view identity for that reason, and `reportSizeIfNeeded` checks the same
thing so a displaced surface cannot resize the PTY out from under its
replacement.

The **renderer** is the same slot, and the second bite. Each surface builds its
own `TerminalRenderer` on its own render thread, so for the length of the
transition two of them called `updateSnapshot` on one engine — and libghostty's
render state belongs to the *terminal*, not to a view. `begin_update` "consumes
terminal/screen dirty state" (`render.h`), and one row iterator was being
advanced by two threads. The rows the displaced surface took were rows its
replacement was never told about, so a fresh split came up showing a screen from
before it: a stale prompt above the real one, and lines with characters
duplicated and dropped where the two extractions interleaved. Clicking the pane
repaired it, because a click starts a selection and a selection calls
`invalidate`.

So binding hands over the right to draw as well. `bind` takes a
`TerminalRenderSink` — the renderer — stops whichever one it displaces, and
invalidates the engine so the incoming renderer starts from a whole screen
rather than from whichever rows happen to still be marked. A displaced renderer
keeps the last IOSurface it drew, which is the right thing to show on a view
that is fading out anyway. `frameLock` closes the rest: `bind` cannot stop a
render thread that is already *inside* an extraction, and two threads sharing
one row iterator is a garbled row rather than a late one.

The replacement has to *say* what size it is, and that is the other half. A
surface's first layout is exempt from `reportSizeIfNeeded` because the size
travels in the attach — true for a controller the attach just made, and false
for every one of these: the surviving pane's controller is already connected, at
the geometry of the pane it used to fill. So the size was recorded as reported
and never sent, and a ⌘D left a half-width pane drawing a full-width grid with
the right-hand half past its own edge. `Coordinator.attach` resizes the
controller it was handed, which the controller drops when it is already at that
size — so a fresh attach still says it once, and a rehomed surface says it at
all.

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

## Configuration

Ghostty's file format, Ghostty's option names, and Ghostty's semantics. The
audience for this app largely has a `~/.config/ghostty/config` already, the two
files end up next to each other holding the same font, and a file that looks
identical while behaving differently is worse than one that looks nothing
alike. The parser is `IllogicalConfig`, ported from `cli/args.zig` — a pure
Swift package target, so it tests under `swift test` without a window or an
XCFramework.

**Two files, both optional**, read in order and applied to one config:
`$XDG_CONFIG_HOME/illogical/config`, then
`~/Library/Application Support/<bundle id>/config`. "Later wins" is per line
rather than per file: a `font-family` in the second appends to the list the
first started, exactly as a second line in one file would, and `font-family =
""` is how you mean "replace". If neither file exists the app writes a
commented template to the second — a config file that does not exist is
undiscoverable, and there is no menu item that reveals it.

The name is `config`, not `config.illogical`. Ghostty 1.3 moved to the
extension so editors can key syntax highlighting off it; we ship no editor
plugin, so it would cost a file name nobody guesses and buy nothing.

**Loading is explicit**, from `IllogicalApp.init()`, and not a lazy global.
Lazily, the first pane to ask for a font size would read the file — which means
every *test* process that builds a surface reads the developer's own config and,
finding none, creates one under whatever bundle identifier the test host has.
A process that never calls `AppConfig.load()` gets the defaults, which is the
right answer for all of them. `ILLOGICAL_CONFIG` names one file instead of
both, the same seam as `ILLOGICAL_SOCK` and `ILLOGICAL_DAEMON`.

**The command line wins, and it replaces rather than appends.** Arguments are
applied after every file, so `--font-size=15` outranks what is on disk. A
list-valued key is the case that needs its own rule: every entry appends, which
is what makes `font-family` a fallback chain rather than four spellings of one
name, and it would leave `--font-family=Menlo` meaning "and also Menlo" with no
way to say "Menlo instead". So the first argument for such a key resets the
list before adding to it — libghostty's rule, and its stated reason is that you
should not have to pass an empty value first. Two arguments for the same key
still build a list between themselves.

The reset is spelled as a synthetic `font-family = ""` entry rather than as a
flag on the apply path, because `""` already means reset and an entry is
something the loader already knows how to carry: it replays underneath a theme
and it reports a diagnostic, with no new argument threaded anywhere. Only
`--key=value` and a bare `--key` are recognised, never `--key value` — a Mac
app is handed its arguments by whoever launched it, and a two-token form cannot
tell a value from a file path the Finder appended. Anything not starting with
`--` is skipped rather than reported, which is load-bearing: AppKit adds
`-NSDocumentRevisionsDebugMode YES` and friends to any app launched from Xcode,
and reporting those would mean a warning per launch about a flag nobody typed.

**Everything is a warning.** A misspelled key is reported with its file, line
and spelling and the rest of the file still applies. One typed on the command
line is reported without a file, since naming a config file for a mistake that
is not in it sends somebody to the wrong place. A config file is not a
program, and refusing to open a terminal over a typo is a poor trade when the
terminal is how the file gets fixed. They go to `os.Logger` rather than only to
`Trace`, because a config warning is the one kind of message that has to reach
somebody who is not debugging the app.

### The font, exactly as libghostty arranges it

`font-family` repeats to build an ordered fallback list, and the four style
lists are searched independently. `FontGrid.build` follows `SharedGridSet.zig`
step for step, and each step is a decision that shows up as text in the wrong
typeface if it is skipped:

1. **The configured families, in order**, each asked for the style — its own
   bold, or one synthesized from it. A family nothing on the system provides is
   *skipped*, not substituted: `CTFontCreateWithFontDescriptor` hands back
   Helvetica for a family it cannot match, and a proportional face mismeasures
   every cell in the grid.
2. **A style that came out empty borrows the regular family** (libghostty's
   `completeStyles`). `font-family-bold` naming something uninstalled falls back
   to `font-family` in bold — never to another family, because bold text in a
   different typeface than the text around it looks wrong in a way a missing
   bold does not.
3. **The text font we ship, behind all of it.** A fallback, not a default: a
   codepoint the configured family lacks is drawn from JetBrains Mono before
   the system cascade is asked.
4. **The system's fixed-pitch face** only if the bundle lost its font
   resources.
5. **The Nerd Font symbols, behind all of that.** One face for all four
   styles — icons have no bold or italic — so a family that carries its own
   icons is still asked first. After the system fixed-pitch face on purpose:
   the grid's metrics are read off the first regular face, and a symbols-only
   font must never be it.
6. **Apple Color Emoji, behind even that.** Pinned by exact name rather than
   left to the cascade, which is libghostty's decision and its stated reason:
   "in case people add other emoji fonts to their system, we always want to
   prefer the official one." One face for all four styles again. A configured
   family is searched first, so naming an emoji font of your own is how you
   override it.

**Which face may answer is a question about presentation, not just coverage.**
A colour glyph and a monochrome one are not interchangeable: a colour glyph
goes into the BGRA atlas and the shader samples the bitmap as it is, so the
cell's foreground colour is *discarded*. That is right for 😀 and quite wrong
for the green ✔ a test runner just printed. So a face is asked whether it has
the codepoint *and* whether the glyph it would draw is the kind that was
asked for:

- **U+FE0F or U+FE0E decides on its own.** An explicit emoji request takes
  only colour glyphs, an explicit text request only monochrome ones.
- **With neither, the codepoint decides**, from Unicode's
  `Emoji_Presentation` property — `EmojiPresentation.swift`, generated from
  the `emoji-data.txt` in the uucode package ghostty pins, which is the same
  data behind libghostty's `is_emoji_presentation`. U+26A0 ⚠ and U+26A1 ⚡ are
  adjacent, are both in JetBrains Mono and both in Apple Color Emoji, and
  nothing a font can see tells them apart; the table is the only reason ⚠
  comes back as text and ⚡ in colour.
- **A configured family is exempt from that second rule.** Somebody who names
  Menlo gets Menlo's monochrome ⚡, because the rule is for the faces we
  reached for and not for the one they chose. libghostty draws the line in the
  same place, promoting a default presentation to an explicit one only for
  entries it marked as fallbacks.
- **And if that leaves nothing**, a last pass takes any face that has the
  glyph at all. Strictness must not make a codepoint vanish: an
  emoji-presentation codepoint that no colour font on the machine carries is
  better drawn monochrome than replaced by U+FFFD. An explicit request gets no
  such pass, because somebody who typed U+FE0E would rather have nothing than
  the colour glyph.

Without the rule, adding the emoji face to that list would have quietly
rerouted ✔ ♥ ➡ ☑ and every other text-presentation symbol Apple Color Emoji
happens to carry, turning monochrome symbols that took the cell's colour into
full-colour bitmaps.

The cascade is asked last and per style, so the CJK face CoreText returns for
bold is the bold one. `FontGridSet` keys its shared grids on the whole
`FontConfig` plus the display scale, so panes that agree about the font still
share one atlas and panes that do not are not silently handed each other's.

**Every fallback is scaled to the face it sits behind.** Two families at the
same point size are not the same apparent size — Courier New's ex height is
three quarters of JetBrains Mono's — so a fallback loaded at the grid's own size
reads as visibly larger or smaller than the text around it. `FaceMetrics`
`scaleFactor` is libghostty's `Collection.scaleFactor`: it compares one metric
between the two faces, normalized to ems so the sizes they were measured at
drop out, and the face is loaded at the grid's size times that ratio. The
metric is `ic_width`, the width of 水, which is what lines a CJK face up on the
grid, and it is what libghostty uses for every fallback it adds.

A font that never states the metric asked for falls through to one more fonts
bother to carry — ex height, then cap height, then line height, which every
font has because it is computed rather than read. That path is the common one
rather than the exotic one: no ordinary Latin monospace font contains an
ideograph, so a Latin fallback is matched on its ex height. The estimate is
never used as a *substitute* for the metric, because scaling by a number
derived from the face being corrected would correct nothing.

Two faces are exempt, both with libghostty's reasoning. The Nerd Font symbols
keep the grid's size, because fitting an icon to its cell is
`NerdFontConstraints`' job and a scale factor would fight it. Colour faces keep
it too: Apple Color Emoji is a bitmap strike whose ex height has nothing to do
with text, so a factor computed from it would resize emoji for no reason.

What is deliberately still missing: reload while running, `font-style`,
`font-feature`, `font-variation`, the `adjust-*` metric modifiers, and
codepoint maps. #39 and #42.

### A translucent terminal, and the bezel that frames it

`background-opacity` is the terminal's alpha and nothing else's. The toolbar,
the tab strip and the breadcrumb stay opaque at any value, which is where
libghostty draws the line too: chrome you can see through is chrome you cannot
find. It is 1 by default, so the app looks the same until somebody asks.

Three things have to agree for one pixel to be see-through, and each of them
was, at some point in writing this, the one that was not:

1. **The renderer leaves the background alone.** A cell with no explicit
   background of its own is written with alpha 0, so the full-screen background
   triangle shows through it at `background-opacity`. This part predates the
   option — it is how libghostty's shaders already worked.
2. **The renderer is given the config.** `TerminalRenderer`'s `config:`
   argument defaults to `RendererConfig()`, and `TerminalSurfaceView` was
   building one without it: the view read the file, used it for its own layer
   colour, and handed the renderer the constants. An opacity of 0.2 was
   pixel-identical to 1.
3. **Nothing opaque is painted behind the surface.** The window stops being
   opaque and its background goes clear, and — the part that is easy to miss —
   the pane draws its bezel as a *ring* rather than a fill. A
   chrome-coloured rectangle behind the card is exactly what
   `background-opacity` would then show you: the frame, at 20%, instead of the
   desktop.
4. **The title bar is painted too.** AppKit insets the toolbar accessory past
   the traffic lights and leaves a sliver at the trailing end, so those two
   strips are the *window's* background rather than ours — and a clear window
   made them the only see-through chrome in the app, the tab strip solid and
   the traffic lights sitting on the desktop. The title bar view itself
   (reached through its close button, the one handle on it AppKit admits to
   owning) gets the colour the accessory is already painting.
5. **Nothing *translucent* is painted behind the surface either.** The surface layer's
   own `backgroundColor` used to carry the opacity too, on the reasoning that
   it is what shows before the first frame. Two translucent fills do not agree
   to disagree, they stack: 0.9 under 0.9 composites to 0.99, so the terminal
   came out very nearly opaque while the breadcrumb above it — a single true
   0.9 — did not, and the seam between them ran across the top of every card.
   The layer's colour is now dropped entirely once the terminal is
   translucent. What that costs is the moment before the first frame, where an
   opaque terminal shows its background colour and a translucent one shows the
   desktop, which is the right way round.

**The bezel** is that frame. A *pane*, so the breadcrumb is inside the card
rather than out on the frame — the cwd, the command and the split controls on
that row all act on the terminal below it, and a header on the frame would
read as belonging to the window. It follows that the header sits on
`Palette.background` at `background-opacity`, the same surface the terminal
draws on, and not on the chrome.

Every number in it is measured off a **light-mode** capture of the reference,
which is the only way to find these edges: in dark mode the chrome and the
terminal are four levels of grey apart and JPEG noise is larger than the
signal. In light mode the card, the frame and the border between them all
separate cleanly. The capture's traffic lights are 16px across against a
known 12pt, which fixes the scale at 4:3, and then:

| | reference | ours |
|---|---|---|
| toolbar height | 52px | 40pt |
| bezel, left / right / bottom | 8px | 6pt |
| bezel, top | 0 | 0 |
| card corner radius | 13px | 10pt |
| card border | 1px | 1pt, `Palette.divider` |
| padding inside the surface, left / right | 11px | 8pt |
| padding inside the surface, top / bottom | 11px | 4pt |

Two of those are worth saying out loud. **The top is flush**: the toolbar ends
and the card's border is the next pixel down, so the card's own edge is what
separates the tab strip from the terminal. There is no hairline under the
toolbar — there used to be, running the full width of the window, and a bezel
plus a divider is two separators doing one job. And **the padding inside the
surface is ours, not libghostty's**: `RendererConfig.windowPadding` defaults to
2 there, which inside a rounded corner reads as text touching the edge.

**The vertical is half the horizontal**, which is the one row of that table
that is not the reference's number. Left and right, the padding is the only
thing between a glyph and the card's border, so it stays at the measured 8.
Top and bottom it is never alone: the breadcrumb already puts 27pt above the
first row, and the bezel and the leftover-row slack already sit below the last
one. Another 8 on each end read as a gap rather than as a margin. The 8pt this
frees is about half a row at the default 13pt, so it buys a tighter margin
rather than reliably another line of output.

That padding is not the bezel and the two are easy to confuse: the bezel is
chrome *outside* the card, and the padding is slack *inside* the surface,
painted in the terminal's own background. In a split each pane carries its own
card, so the gutter between two of them is two bezels with the divider line
down the middle.

**Those numbers are the top and the left; the leftover goes to the bottom and
the right.** A surface is almost never a whole number of cells, and libghostty
either leaves that remainder past the last row and column or splits it between
opposite edges — `window-padding-balance`, which defaults to off. We leave it,
because balancing makes the grid's origin a function of the surface size: the
top padding ramps up by half a cell as a window is dragged and drops back the
moment another row fits, so every glyph on screen — the scrollback being read
included — slides and snaps once per row for as long as the drag lasts. The
price is that the gap under the last row is 4pt plus up to a cell where the gap
above the first is 4pt exactly. Both are the terminal's own background, so it
reads as a slightly deeper gutter at the bottom of the card rather than as an
edge in the wrong place.

**`background-blur` is a radius**, spelled as a bool or a number the way
libghostty spells it, and honoured either way — `true` is 20, which is the
radius it picks for the same word. That it can be honoured at all is why the
blur is `CGSSetWindowBackgroundBlurRadius`, a private CoreGraphics call, and
not `NSVisualEffectView`: the public class blurs behind a *view* at a radius
the system chooses and tints the result with a material, which is right for a
sidebar and wrong for a terminal. The symbols are resolved with `dlsym` rather
than declared with `@_silgen_name` as Ghostty declares them — the call is the
same, but a link-time reference to a private symbol means the day Apple drops
it the app fails to launch, over a blur. This way the lookup returns nil and
the terminal opens unblurred.

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
