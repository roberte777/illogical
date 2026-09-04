# Research: what Superlogical actually does

Everything in this repository's design is derived from public statements by
Mitchell Hashimoto and from libghostty's own source and commit history. This
document is the evidence base. Every design decision elsewhere should be
traceable to a claim here, and every claim here should be traceable to a source.

**Nothing here comes from Superlogical source code.** None is public. Where we
have had to invent, this document says so.

## Sources

| Key | Source | Notes |
| --- | --- | --- |
| **[ARCH]** | ["Superlogical Terminal Multiplexer High-Level Architecture"](https://www.youtube.com/watch?v=Y6nFMmUPzXM), Mitchell Hashimoto, 10:39 | The architectural primary source |
| **[MEM]** | ["Superlogical Server Memory Optimizations Overview"](https://www.youtube.com/watch?v=T5gV6anSt-4), Mitchell Hashimoto, 11:43, 2026-09-02 | The performance primary source |
| **[SBC]** | ["Ghostty Scrollback Compression Demo"](https://www.youtube.com/watch?v=ZVAnhimPh8k), 3:30 | About **Ghostty**, not Superlogical |
| **[ANN]** | [superlogical.com](https://www.superlogical.com/) and [mitchellh.com/writing/superlogical](https://mitchellh.com/writing/superlogical) | Product contract; deliberately vague on tech |
| **[GH]** | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) commit history and `include/ghostty/vt/*.h` | The strongest evidence of all — the actual code |
| **[X]** | [@mitchellh](https://x.com/mitchellh) threads, notably [2095218879714996629](https://x.com/mitchellh/status/2095218879714996629) | x.com blocks fetching; text and chart images recovered via the syndication API |
| **[MASTO]** | [@mitchellh@hachyderm.io](https://hachyderm.io/@mitchellh) | He cross-posts, and the Mastodon wording is sometimes *more* precise than X |

Videos are on his channel [@Mitchellh3](https://www.youtube.com/@Mitchellh3). Note
that the video in X post `2082936029426892960` is the same 640 s recording as
[ARCH] — confirmed by exact duration match.

Timestamps are cited as `[ARCH t=203]`.

### Corroboration

[ARCH] and [MEM] were transcribed independently three times — once via YouTube's
InnerTube caption API and twice via third-party transcript providers (kome.ai,
notegpt.io). The provider outputs are byte-identical (11,421 vs 11,422 chars),
confirming a single underlying ASR track. Every quote in this document was read
back against those transcripts.

One author-endorsed secondary source exists:
[Samat Galimov's recap](https://x.com/samat/status/2082949278553563437) of the
architecture video, to which Mitchell replied *"Thank you, I would've written
something but I was lazy!"* It says **libghostty** in both places the ASR says
"libvte", which is the direct confirmation of the correction below.

### Reading the transcripts

[ARCH] and [MEM] are transcribed from YouTube auto-captions, which mangle proper
nouns badly. **"libvte", "libgo C", "libgoasty", "Ghost T" and "Ghostly" all mean
libghostty**; "Superlogic"/"Superlog" mean Superlogical. This matters: a literal
reading of [ARCH t=238] would have you believe Superlogical is built on GNOME's
VTE. It is not.

### Confidence

- **Verified** — stated directly in a primary source, quoted below.
- **Strong inference** — not stated, but forced by something that is.
- **Ours** — our decision. Superlogical may well do something else.

## 1. Why traditional multiplexers are slow

> "you have your terminal emulator and then your terminal emulator runs the
> multiplexer and then the multiplexer runs the final PTY … you end up getting
> double parsing, double state processing, just duplicated work."
> — [ARCH t=50] *(verbatim)*

> "tmux, Zellij, screen, these types of multiplexers, their terminal emulator
> like IO part is fairly slow … compared to a modern terminal like Ghostty or
> Kitty or even Alacritty that are sometimes 100 plus times faster. And so, when
> you put something in front of it, you're just sort of getting that slow
> experience in a fast terminal."
> — [ARCH t=66] *(verbatim)*

Two distinct costs, and it is worth keeping them apart:

1. **Structural** — the work is done twice, once by the multiplexer's emulator
   and once by yours.
2. **Constant-factor** — the multiplexer's emulator is the slow one, so you are
   paying twice and the second copy is the bad one.

A third, from the same source: multiplexers are slow to adopt terminal features,
so the multiplexer becomes the feature ceiling — tmux still has no Kitty
graphics protocol support [ARCH t=556].

**Status: verified.**

## 2. The wire carries raw PTY bytes, not screen diffs

This is the central architectural claim.

> "instead of sending down screen diffs — tmux, zellij, all these things, what
> they do is they keep track of the screen, and they send down a diff of what's
> changing on the screen. Instead of that, we take the PTY bytes, we tee them
> off to all the clients, and we send them raw, like SSH, to all the clients,
> and we assume that everybody is running a compliant, performant, correct
> terminal emulator."
> — [ARCH t=203] *(verbatim, "libvte" corrected to libghostty)*

> "There is no internal parsing. If the server actually starts parsing slower,
> the client is still parsing at full speed. It doesn't matter."
> — [ARCH t=255] *(verbatim)*

The consequence he draws is the design's actual shape:

> "there's still sort of one writer, there's multiple readers, and we just
> assume we have this sort of distributed system of synchronized finite state
> machines in these terminal emulators. If one of the terminal emulators starts
> processing incorrectly, you're just going to see the wrong data on the client
> side, but the authoritative side doesn't depend on any of that."
> — [ARCH t=273] *(verbatim)*

And the recovery model:

> "if a client is ever sort of out of sync for any reason, it could just restart
> this process, start from the beginning, reset the terminal frames."
> — [ARCH t=356] *(verbatim)*

**Status: verified.** This is the single most important thing to get right.

## 3. The attach handshake

> "when a client connects to the server, the server part that actually is
> connected to the PTY pauses processing at that moment of the current PTY
> bytes … we send down a binary protocol, a custom hand-signed bit by bit binary
> protocol … The binary protocol is constructed in a way that we send down just
> enough terminal state, screen state, what's currently visible on the screen,
> dimensions, mouse cursor state … so that the client can start rendering as
> quickly as possible. We defer for later things like scrollback history."
> — [ARCH t=118] *(verbatim)*

> "we send a frame type called a ready frame. When the client reaches the ready
> frame, they're able to immediately show the terminal, and the user could start
> doing selection, could start typing on their keyboard, could start scrolling …
> and then the core server part unpauses, starts processing PTY bytes"
> — [ARCH t=185] *(verbatim)*

> "we sort of send the history back newest to oldest, so the most recent
> scrollback is there, just chunk by chunk … you could scroll, and you're just
> going to see blank with sort of a loading state, like it's just not there yet."
> — [ARCH t=308] *(verbatim)*

So the ordering is: **pause → state → READY → unpause → raw bytes, with history
streaming underneath, newest first, and a loading state for gaps.**

**Status: verified.** Note this maps exactly onto libghostty-vt's snapshot format
(`TERMINAL → SCREEN → PAGE… → CONTINUATION → READY → HISTORY → PAGE… → FINISH`),
which is not a coincidence — see §7.

## 4. Every client owns its own viewport

> "famously and infamously in tmux, if you have multiple clients attached to the
> same tmux session, when one of them scrolls, it scrolls everybody's window.
> Very annoying. So you're going to actually be able to scroll on your own
> because the client fully owns the viewport state."
> — [ARCH t=323] *(verbatim)*

Selection is likewise per-client [ARCH t=323].

**Status: verified.**

## 5. Splits are native widgets, one connection per PTY

> "we represent each split using native tabs, native windows, native splits. And
> each one has its own connection to this binary protocol … they're their own
> standalone systems, one-to-one to a PTY. You're not going to get the
> multiplexing within a window like you normally do."
> — [ARCH t=440] *(verbatim)*

A compatibility mode for terminals that cannot speak the protocol is planned,
and he is explicit that it gives up the advantage:

> "we will have a compatibility mode that does what traditional multiplexers do,
> which is we put a libghostty terminal in the middle and that's the same
> trade-off as other multiplexers … architecturally it's going to be identical
> there if you're in this legacy mode."
> — [ARCH t=507] *(verbatim)*

Also planned: attach to a single terminal by ID from any terminal [ARCH t=474].

The protocol is intended to be **open and shipped as part of libghostty**
[ARCH t=524].

**Status: verified.**

## 6. Three levels of parking

This is [MEM]'s payload, and the most valuable material we found. All three are
separate mechanisms with separate triggers.

### 6.1 Terminal parking

> "if a terminal is idle for 60 seconds … we take a binary snapshot of the entire
> terminal emulator state and put it to disk … the cost of a terminal that's
> parked to disk is only basically the minimal resources to monitor the file
> descriptor so that it could unpark, rehydrate when activity comes back."
> — [MEM t=246] *(verbatim)*

The definition of "idle" is narrower than you would guess, and it matters:

> "When I say idle, I'm really talking about read bytes on the PTY, bytes that
> would update the terminal emulator screen or history state."
> — [MEM t=246] *(verbatim)*

> "it is really only on PTY read. You could still type keys and send data right
> to the PTY, but if that isn't updating the actual terminal emulator state, the
> PTY read, we don't need to unpark this. So this parking terminals works even
> when clients are attached. If I have my Superlogical app open and I have 10
> terminals, but all 10 terminals are sitting on idle shells, all 10 terminals
> are going to be parked."
> — [MEM t=296] *(verbatim)*

Unpark cost:

> "even for a 64 MB … full compressed scrollback, it takes us about 200
> microseconds to unpark that, **not counting the disk speed**."
> — [MEM t=369] *(verbatim, emphasis ours)*

> "once we have the data, we can decompress and decode streaming from disk. We
> don't have to wait for all of it to be in memory. This is designed to be a
> streaming binary protocol."
> — [MEM t=384] *(verbatim)*

Snapshots are encrypted, because scrollback contains secrets. He explicitly
defers the scheme: *"We'll talk about that another time"* [MEM t=278].

> ⚠️ **Do not cite "20 microseconds."** The captions read *"it only takes about
> 20 20 microseconds"* immediately after the 200 µs claim [MEM t=384]. Both
> caption tracks are byte-identical so this cannot be disambiguated; it is
> probably a stutter restating 200 µs. Use **200 µs, excluding disk I/O**, and
> note that he separately calls unparking *"really bound by your disk speed"*
> [MEM t=352].

**Status: verified, with the caveats above.**

### 6.2 PTY parking

This one is a genuine surprise and it contradicts the obvious design.

> "we discovered in Ghostty … that the fastest way to get IO performance is to
> put each PTY in its own dedicated OS thread blocked on the read syscall. We
> found early on and we've re-verified this time and time again that if you
> throw multiple PTY FDs into kqueue or epoll or io_uring, there is a very
> noticeable hit to latency, to IO throughput. You cannot put these all into an
> evented system. It's better to just block on the read with an OS thread."
> — [MEM t=399] *(verbatim)*

But threads do not scale to server workloads:

> "OS threads are expensive, relatively … it's meant for a server scale of
> terminals, which could be thousands, tens of thousands. The OS thread
> overhead, the stack size, and the accounting around a kernel thread, it gets
> very, very expensive."
> — [MEM t=443] *(verbatim)*

So the fd migrates between two regimes:

> "if the PTY is idle, or if a client isn't attached to it, and maximum
> throughput isn't important, then what we do is we park the PTY … we have a
> single OS thread that does use kqueue and epoll, and we move the file
> descriptor out from its dedicated OS thread, tear that down, and we put it into
> the evented system. Slightly higher latency, way lower resource usage as the
> number of file descriptors increase."
> — [MEM t=473] *(verbatim)*

Two triggers, and a measured cost:

> "if the terminal gets parked, we throw that into the centralized poller. Two,
> if there's no clients observing the terminal at that moment, we also move it
> because you get about a 5 to 10% hit in IO throughput, but that's worth it when
> you're not looking at it."
> — [MEM t=504] *(verbatim)*

**Status: verified.** This directly invalidated our first architecture draft,
which had a single libxev loop owning every PTY.

### 6.3 Client buffer parking

> "when a client attaches, in order to optimize the speed at which a client could
> read data from the server, we have a bunch of buffers … it adds up. It's
> kilobytes of buffers. When a client is mostly idle after a period of time,
> after the initial synchronization, we park the buffers, which is basically we
> free them. We free the buffers and then the next time there's a bunch of
> activity we reallocate them."
> — [MEM t=551] *(verbatim)*

**Status: verified.**

### 6.4 Attaching to a parked terminal does not unpark it

The best detail in either video:

> "if a client connects to a parked terminal, we actually stream the binary
> snapshot from disk directly to the client. We don't need to unpark the terminal
> because a client attached. So if you have a client that's just hammering attach
> attach attach attach, on off on off on off, the server is just on disk and
> we're just streaming from disk."
> — [MEM t=660] *(verbatim)*

This works precisely because the on-disk park format and the attach payload are
the same bytes. It is the strongest argument for not inventing a separate wire
format for attach.

**Status: verified.**

## 7. Numbers

The four benchmark charts attached to [X 2095218879714996629] were recovered and
read directly. **All figures below are transcribed from those charts**, not from
the spoken commentary — Mitchell deliberately withheld them verbally (*"I'm going
to let you look at the numbers on your own"* [MEM t=170]).

Methodology as printed on every chart: **macOS 26.6.2, Apple M4 Max,
`phys_footprint`**. Zellij is shown twice because its defaults ship plugins;
"plugin-free explicitly removes all plugins."

### Total server footprint — server start, one session

| | |
| --- | --- |
| tmux 3.5a | **2.50 MiB** |
| Superlogical | 10.6 MiB |
| zellij 0.45.0 plugin-free | 35.3 MiB |
| zellij 0.45.0 default | 53.6 MiB |

### Additional footprint per empty 80×24 terminal

| | |
| --- | --- |
| tmux 3.5a | **15 KiB** |
| Superlogical | 68 KiB |
| zellij 0.45.0 plugin-free | 2.30 MiB |
| zellij 0.45.0 default | 7.88 MiB |

### Additional footprint per terminal filled with 10,000 lines

80×24 terminal filled with 10,000 numbered 72-column prose lines.

| | |
| --- | --- |
| Superlogical | **407 KiB** |
| tmux 3.5a | 4.89 MiB |
| zellij 0.45.0 plugin-free | 22.7 MiB |

### Additional footprint per client connection, with 50 filled terminals

| | |
| --- | --- |
| Superlogical | **85 KiB** |
| tmux 3.5a | 157 KiB |
| zellij 0.45.0 plugin-free | 21.7 MiB |
| zellij 0.45.0 default | 1.56 GiB |

### Reading these honestly

**tmux wins two of the four.** Superlogical is 4× worse on the empty terminal and
4× worse at server start. Mitchell says so on camera and says it is fixable:
*"For empty terminals, they are a little bit less, but I know what that is and
we'll be able to match that"* [MEM t=197].

The two it wins are the ones that scale: **12× better per filled terminal** and
**1.8× better per client connection**. The whole design is a trade of fixed
overhead for marginal cost, which is the correct trade if you believe the scale
argument in [MEM t=139].

Zellij's default-config numbers are a cautionary tale about per-tab runtimes
rather than a fair comparison. His diagnosis, verbatim from [X]:

> "Out of the box (zero config) Zellij has a tab bar and status bar plugin. These
> are wasm-plugins and each tab gets an instantiation. Each instantiation is its
> own wasm runtime. Huge memory explosion."

### Non-memory numbers

| Metric | Value | Source |
| --- | --- | --- |
| Unpark, 64 MB compressed scrollback | ~200 µs, **excluding disk I/O** | [MEM t=369] |
| IO throughput cost of a parked PTY | 5–10% | [MEM t=504] |
| Terminal park threshold | 60 s of PTY-read idle | [MEM t=246] |

CPU, IO throughput and security benchmarks are explicitly deferred to future
videos [MEM t=92]. There are **no latency or throughput numbers** for Superlogical
anywhere yet.

### Scale target

> "It's not a multiplexer for one person attaching to one server at a time with
> 10 terminal sessions. It's dozens of people, hundreds of people with an order
> of magnitude, hundreds of thousands of agents or more, spawning even more
> terminals than that." — [MEM t=139] *(verbatim)*

> "if we design for excessive, then the low end will work really great."
> — [MEM t=155] *(verbatim)*

The driver is stated plainly in [X]: *"we're seeing unprecedented terminal usage
and client attachment mainly due to AI. They like to spawn more sessions than
we've ever seen, and they are all their own clients."*

### Deployment

Self-hosted, not a service. Embedded in the Mac app and started automatically for
new users; also runs standalone on Linux [MEM t=14]. The vision is *"a
Superlogical server on every machine you own, on every server component … on
every Kubernetes pod potentially"* [MEM t=46].

From [MASTO] replies to the demo: a Linux CLI and a **NixOS module** are planned;
the server has **built-in Tailscale/Headscale support and acts like a node**;
*"everything you saw including input is API driven"*; and *"Nothing you see here
requires any services and we're not launching any hosted services."*

## 8. The libghostty-vt evidence

The strongest corroboration is not anything Mitchell said — it is what has been
merged into ghostty. These APIs exist because this multiplexer needs them, and
several commits say so outright.

> "This enables reliable stream restart across serialization states … For me,
> this is used for multiplexers. :)"
> — ghostty `f5880782f`, *terminal: add stream continuation tracking for replay
> (#13544)* *(verbatim)*

The binary snapshot format PR names the use case directly: *"replay software
(like asciinema), multiplexers (like zmx), scrollback-saving on disk"*
(`154ddc2a2`, #13534).

And the single most important enabling property, which explains why snapshotting
is fast enough to do every 60 seconds at all — [MASTO], 2026-07-09:

> "our memory is directly serializable because we only store pointer offsets, not
> full pointers, so we need this to be able to do disk offload (can write
> compressed data direct to disk)" *(verbatim)*

Ghostty's page memory is position-independent by construction. Encoding a
snapshot is therefore much closer to a copy than to a traversal-and-serialize,
and compressed pages can go to disk without being decompressed first. This is
years-old groundwork that the multiplexer is now cashing in — as he puts it,
*"all this work we've thought about for years is paying off in a big way here"*
[MEM t=645].

See [OPTIMIZATIONS.md](OPTIMIZATIONS.md) for the full inventory with commit
references and measured numbers.

## 9. What we could not verify

Listed so nobody later mistakes a guess for a finding.

| Question | Status |
| --- | --- |
| Snapshot **encryption** scheme for parked terminals | Explicitly deferred by Mitchell [MEM t=278] |
| Which **compressor** Superlogical uses for parked snapshots | Never named. He says "full compressed scrollback". Ghostty's *scrollback page* compression is LZ4 [GH #13264]; for *snapshots* he has recommended zstd in a ghostty discussion. These are different things — do not conflate them |
| Exact **wire framing** of the binary protocol | Never shown. Ours is invented |
| **Per-client** memory figures | "Cheaper", no number [MEM t=214] |
| CPU, IO throughput, security benchmarks | Explicitly deferred to future videos [MEM t=92] |
| The four on-screen **benchmark charts** | Spoken numbers only |
| Whether a session groups **multiple terminals** server-side or client-side | [ANN] says "multiple terminal blocks organized inside a long-lived session"; [ARCH t=440] says each split is a separate connection 1:1 with a PTY. We infer the grouping is a server-side concept with client-side layout, but this is **strong inference**, not verified |
| How **terminal queries** (DA, DSR, XTWINOPS) are answered with 0 or N clients attached | Never addressed. Ours — see [ARCHITECTURE.md](ARCHITECTURE.md#terminal-queries) |
| Flow control for slow clients | Never addressed. Ours |
| The "**memory wall**" phrasing that appears in some secondary write-ups | **Not found in any primary source** — not in the X thread text, the Mastodon cross-post, either transcript, or search. Do not attribute it to Mitchell |
| Superlogical latency or IO throughput numbers | None exist publicly [MEM t=92] |

There is also no Superlogical blog, docs site, protocol spec, or public source as
of 2026-09-04. `superlogical.com/blog` and `/docs` are 404. Hacker News contains
**no** comments from Mitchell about Superlogical at all — we checked his full
comment history; the announcement thread is about funding and hiring, not
architecture.

## 10. Prior art

Other people are building this, publicly, on the same foundation. Worth watching
because their tradeoffs are visible in a way Superlogical's are not.

| Project | Language | Approach |
| --- | --- | --- |
| [zmx](https://github.com/neurosnap/zmx) (neurosnap) | Zig | Session attach/detach, native scrollback, multiple clients. Restores via libghostty's **VT formatter** — replays a reconstructed byte stream, not a binary snapshot |
| [boo](https://github.com/coder/boo) (Coder) | Zig | `screen`-style. Client puts the TTY in raw mode, daemon owns PTY + `ghostty-vt` stream. Also replays via `TerminalFormatter`. Answers DSR/DA/XTWINOPS **while detached** so TUIs don't hang. Strong agent-automation surface (`send`/`peek`/`wait`/`--json`) |
| [hauntty](https://github.com/seruman/hauntty) | Go | Ghostty VT compiled to WASM |

Note that **zmx is not Mitchell's project** — it is neurosnap's, and it appears
in ghostty commit messages only as a downstream consumer.

The formatter-replay approach (zmx, boo) is the main alternative to ours. It
reconstructs a VT byte stream that repaints the screen; the receiving end can be
any terminal. The binary-snapshot approach requires a libghostty-speaking client
but transfers state directly and is what makes park-and-stream-from-disk
possible. Superlogical takes the snapshot path, and so do we.

boo's detached-query answering is a real requirement we would otherwise have
missed.
