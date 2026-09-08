# illogical

[![CI](https://github.com/roberte777/illogical/actions/workflows/ci.yml/badge.svg)](https://github.com/roberte777/illogical/actions/workflows/ci.yml)

A terminal multiplexer with persistent sessions, built on
[libghostty-vt](https://github.com/ghostty-org/ghostty).

The server owns the PTYs and keeps a real terminal per terminal. Clients are
native applications running the same VT engine, so the server can tee them
**unprocessed** PTY bytes — like SSH — and let them draw. Attaching paints the
current screen immediately from a binary snapshot, then streams scrollback in
behind it, newest first. Idle terminals are snapshotted to disk and cost nothing
until they speak again.

> Clean-room build against the public description of Superlogical. No Superlogical
> source is public; everything here derives from Mitchell Hashimoto's own talks
> and posts, and from libghostty's source. The evidence is written down with
> citations in [docs/RESEARCH.md](docs/RESEARCH.md).

**Status: M6.** The daemon runs sessions, parks idle terminals to disk, and the
Mac client attaches to them — on this machine or on another one over SSH,
several at a time in one window. The app carries the server and starts one when
there is none, and the same server ships on its own for any other box. What is
measured and what is not is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Remote hosts

```bash
illogical --host build-box list          # the same CLI, another machine
illogical --host build-box new -s api
```

The client runs `ssh <dest> illogicald --stdio` and speaks the same frames over
the pipe. Your existing SSH config, keys, jump hosts and agent forwarding apply;
there is no listening socket, no TLS, and no credential of ours to configure —
the app remembers a destination and the remote binary's name, and nothing else.

`--stdio` is a **bridge**, not a server. The process SSH starts owns no
terminals: it connects to that host's own long-lived daemon, starting one
detached if there is none, and splices bytes between it and the pipe. A server
started by SSH would die with the session and take its terminals with it.

The Mac app holds as many hosts at once as you add, and gets them back on its
own when a network goes away. That recovery is the desync path with a new socket
in front of it: the same `attach`, because the terminal on the far side never
stopped.

## Install

**The Mac app.** Download
[`Illogical.dmg`](https://github.com/roberte777/illogical/releases/download/latest/Illogical.dmg),
open it, drag Illogical to Applications. That is the whole install: the app
carries the server inside it and starts one when there is none, so there is
nothing to install first and nothing to start. Universal, so it runs on both
Apple Silicon and Intel.

> The DMG is not signed or notarized yet — that needs an Apple Developer ID,
> and the pipeline turns both on the moment one exists (see **Releases**
> below). Until then macOS refuses it on the first open: right-click Illogical
> → **Open**, once, and it will launch normally afterwards. Tracked in
> [#47](https://github.com/roberte777/illogical/issues/47) along with
> auto-updates.

**The server, on any other box.** One tarball, two static binaries, no runtime
dependencies:

```bash
curl -fsSL https://github.com/roberte777/illogical/releases/download/latest/illogicald-linux-x86_64.tar.gz \
  | tar xz -C ~/.local/bin illogicald illogical terminfo
```

Those three by name, because the tarball also carries `LICENSE` and
`THIRD_PARTY_NOTICES` and those do not belong on a `PATH`.

`terminfo/` is the compiled database for `xterm-ghostty`, and it travels beside
the daemon rather than into a `share/` because `illogicald` looks for it in its
own directory. Leaving it out is not fatal — the daemon notices, says so in its
log, and tells the shells it starts `TERM=xterm-256color` — but the terminals on
that box are then a smaller terminal than the ones at home.

`releases/download/latest/…`, naming the tag, rather than the
`releases/latest/download/…` redirect that looks equivalent and is not: that
redirect resolves to the newest release **that is not a prerelease**, and the
rolling one is a prerelease by definition. Every URL through it 404s until the
first `v` tag exists. Naming the tag works in both worlds and keeps working
after one does.

Nothing needs starting after that. `illogical --host <box>` runs
`ssh <box> illogicald --stdio`, which starts a daemon there if there is none —
it only has to be on the `PATH` of a login shell on that machine, or named with
`--remote-bin`. To start one by hand, `illogicald --ensure`.

Releases carry `macos-universal`, `linux-x86_64` and `linux-aarch64` tarballs
plus `SHA256SUMS`; the Linux binaries are statically linked against musl, so
they impose no glibc floor. Locally, `just dist` builds all three.

**The CLI, from the app.** It is not inside the bundle — `Contents/MacOS/`
already holds the app's own `Illogical` executable and the default macOS volume
is case-insensitive, so a file called `illogical` in there *is* that file. Take
it from the tarball, or from `zig-out/bin` in a build tree.

## Configuration

Ghostty's format, and Ghostty's option names. The app reads two files, both
optional, and applies them in this order:

```
~/.config/illogical/config                              # or $XDG_CONFIG_HOME
~/Library/Application Support/dev.illogical.Illogical/config
```

If neither exists, the app writes a commented template to the second one on
first launch, so there is a file to open rather than a path to guess.

```ini
# Key and value. Spacing around the = does not matter, and a line starting
# with # is a comment — but a # after a value is part of the value.
font-family = Berkeley Mono

# Repeat it to add fallbacks. The first family with the character wins; the
# system's own cascade is asked only after every one of them has missed.
font-family = Noto Sans CJK

# Because repeating appends, clearing the list needs an empty value first.
font-family = ""
font-family = Iosevka

# Styles are looked for inside the family above unless you name one, and a
# family with no italic gets a synthesized one rather than another family's.
font-family-bold = Iosevka Bold
font-family-italic = Iosevka Oblique
font-family-bold-italic = Iosevka Bold Oblique

# Points. Fractional sizes are real — the cell is measured in pixels, so 13.5
# at 2x is a 27px cell. Default 13.
font-size = 13

# How opaque the terminal is. Only the terminal — the toolbar, the tabs and
# the breadcrumb stay solid at any value, so the window is still something you
# can aim at. Default 1.
background-opacity = 0.9

# Blur what shows through, in pixels. Does nothing on its own: with an opaque
# terminal there is nothing behind it to blur. `true` is 20, the radius
# Ghostty picks for the same word, or write your own.
background-blur = true
```

### Themes

A theme is a file of colours, and the app ships the same ~600 of them Ghostty
does — the [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
collection, from Ghostty's own pinned tarball, under the same names.

```ini
# Applied underneath everything else in the file, so anything you set
# yourself still wins — wherever in the file you set it.
theme = Catppuccin Mocha

# Two of them, picked by whether the system is in light or dark mode. Both
# halves are required; the order does not matter.
theme = light:Rose Pine Dawn,dark:Rose Pine
```

`theme = <name>` looks in three places, first hit winning, so a file of your own
beats one we shipped by having the same name:

```
~/.config/illogical/themes/<name>                                # or $XDG_CONFIG_HOME
~/Library/Application Support/dev.illogical.Illogical/themes/<name>
Illogical.app/Contents/Resources/themes/<name>
```

An absolute path skips the search (`theme = ~/dotfiles/mine`); a relative one
may not contain a `/` at all. A theme that is not found names every path it
tried. A theme file is an ordinary config file — the same syntax, the same
seven colour keys below — and the only thing it may not set is another
`theme`.

A theme repaints the whole window, not just the terminal: the toolbar, the tab
strip, the find bar and the session menu are all derived from the theme's
background and foreground, and the tab badge and the selected menu row take
the theme's own green and blue. `window-theme` decides the appearance macOS
draws its own parts of the window in.

The light/dark pair is resolved at launch, so switching the system between
light and dark needs the app restarted for now.

### Colours

Ghostty's colour vocabulary, which is XParseColor's plus a couple of
conveniences: hex with or without the `#`, an X11 name, `rgb:` or `rgbi:`.
`background = red`, `background = f00` and `background = rgb:ff/00/00` are the
same red.

```ini
# The terminal's own two, for cells that carry no colour of their own.
background = #1e1e2e
foreground = #cdd6f4

# The 16 ANSI colours, and any of the other 240. Repeat the key; the index may
# be decimal, or 0x, 0o or 0b prefixed.
palette = 0=#45475a
palette = 1=#f38ba8
palette = 0xF=#a6adc8

# Derive 16–255 from the 16 above instead of using xterm's cube, so a palette
# of your own stays in keeping with itself. Off by default: plenty of software
# assumes it knows what xterm's indices are. `palette-harmonious` runs the
# generated cube the other way round under a light theme.
palette-generate = true

# The cursor's block, and the character under it. Unset, the cursor is the
# foreground colour and the character under it is the background.
cursor-color = #f5e0dc
cursor-text = #1e1e2e

# The selection. Unset, it inverts the terminal's two colours.
selection-background = #f5e0dc
selection-foreground = #1e1e2e

# Any of those four can be `cell-foreground` or `cell-background` instead —
# the colour the cell already has rather than a fixed one. A selection that
# keeps each token's colour instead of flattening them; a cursor that inverts
# whatever it is standing on. (`cursor-invert-fg-bg` and
# `selection-invert-fg-bg` are the older spellings, and still read.)
cursor-color = cell-foreground
cursor-text = cell-background

# Whether macOS draws its own parts of the window — the traffic lights, a
# sheet, the buttons on the "no terminals" screen — light or dark. The chrome
# Illogical draws itself always follows the theme; this is for the rest.
# `auto` reads the theme's background, `system` follows the desktop, and
# `light`/`dark` force one. Default `auto`.
window-theme = auto

# Force a WCAG contrast ratio between text and its own background, 1 to 21.
# 1 is off, and off is the default — this overrides the colour a program
# asked for. 1.1 avoids invisible text; 3 or more pushes towards black
# and white.
minimum-contrast = 1.1
```

Every one of these is parsed by a port of libghostty's own
`terminal/color.zig`, checked against `ghostty_color_parse` itself over every
X11 name and every 3- and 6-digit hex value in
[`ColorParityTests`](clients/macos/Tests/ColorParityTests.swift) — because a
theme is a config file somebody else wrote against that parser, and agreeing
with it in the cases we thought of is not the same as agreeing with it.

The font, the window and the colours are what there is so far;
[#39](https://github.com/roberte777/illogical/issues/39) tracks the rest.
Unknown keys and unparseable values are warnings — they go to the unified log
(`log stream --predicate 'subsystem == "dev.illogical.Illogical"'`) and the
rest of the file still applies. Nothing here reloads while the app runs yet.

`ILLOGICAL_CONFIG` names one file to read instead of both, and reads nothing
when set to empty.

## Releases

Every merge to `main` rebuilds everything and moves the
[`latest`](https://github.com/roberte777/illogical/releases/tag/latest)
prerelease onto it, so the download links above are permanent and always point
at the newest build. There are no version numbers yet on purpose: there is one
release, and asking somebody to choose between one thing is ceremony around
nothing. Pushing a `v*` tag publishes the same artifacts as a real release that
stops moving.

The trigger is CI going green rather than the push itself, so a merge that
broke the build cannot replace a working download with one that does not run.

The macOS daemon tarball is built first and the app bundle carries **that same
build** rather than a second one — which is what stops an Intel Mac getting an
app whose daemon cannot run, and what stops every release app reporting version
skew against the tarball beside it.

Not quite byte-identical, and it cannot be: Xcode re-signs the daemon on the way
into the bundle (`CodeSignOnCopy`), so the copy differs from the tarball's in
its signature and fat-header padding — measured at 14 bytes in 4 MB, with
identical `__TEXT` and an identical `--version`. Same build, two signatures.

Locally: `just dist-app` builds and packages the DMG, `just dist` builds the
three server tarballs.

### Signing

`scripts/dist-app.sh` signs and notarizes when these repository secrets exist
and builds an ad-hoc signed DMG when they do not, so the packaging path runs on
every build rather than only where a certificate lives:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PWD` | its export password |
| `MACOS_CERTIFICATE_NAME` | the identity, `Developer ID Application: … (TEAM)` |
| `MACOS_KEYCHAIN_PWD` | any password; names the throwaway CI keychain |
| `APPLE_API_ISSUER` | App Store Connect API issuer UUID |
| `APPLE_API_KEY_ID` | its key id |
| `APPLE_API_KEY` | base64 of the `AuthKey_<id>.p8` |

Set all seven and the next merge produces a DMG that opens with a double-click.
The app and the DMG are notarized and stapled separately — a ticket is fetched
by the cdhash of the artifact it is stapled to, so stapling only the DMG leaves
the app a user drags to Applications needing Apple's servers on first launch.
The reasoning for each step is in the script's header.

## Getting started

Requires [Nix](https://nixos.org/download) with flakes, and Xcode for the macOS
client. Everything else comes from the devshell.

```bash
git clone --recurse-submodules <this repo>
cd illogical
nix develop            # or `direnv allow` if you use direnv
```

Then:

```bash
just build             # illogicald + illogical
just test              # Zig tests
just serve             # run the daemon in the foreground
```

For the Mac client:

```bash
just xcframework       # build ghostty-vt.xcframework from vendor/ghostty (~1 min)
just xcodeproj         # generate Illogical.xcodeproj from project.yml
just app               # build the app, with illogicald inside it
just run-app           # ...and launch it. No daemon to start first.
just test-swift        # protocol tests; needs neither of the above
```

`just app` stages `zig-out/bin/illogicald` into the bundle (`just stage-daemon`,
which `xcodeproj` and `app` both depend on), so the app you build carries the
server built from the same ghostty pin. Running it is enough — if nothing is
listening on the socket, the app starts one, and that server outlives the app.

`just` on its own lists every task.

## How it works

```
child ──► PTY ──► illogicald ──┬──► ghostty-vt terminal ──► snapshot.gsnp (park)
                               │                                    │
                               │         attach to a parked terminal │
                               │         is served straight from it ─┘
                               │
                               └──► raw bytes ──► client ──► ghostty-vt ──► Metal
```

Both ends run the same terminal implementation, built from the same pinned
ghostty revision — "a distributed system of synchronized finite state machines".
The server's copy is authoritative and makes attach O(screen) instead of
O(history); the client's copy lets it draw at full speed no matter what the
server is doing.

A **session** is a named container of **terminals**. Each terminal is 1:1 with a
PTY and gets its own connection; splits and tabs are native widgets in the
client, not something the server draws.

Read in this order:

| Document | |
| --- | --- |
| [docs/GOALS.md](docs/GOALS.md) | what this is for, and how we will know it works |
| [docs/RESEARCH.md](docs/RESEARCH.md) | what Superlogical actually does, with citations |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | components and data flow |
| [docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md) | every performance technique, and whether we adopt it |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | the wire format and the attach handshake |
| [docs/PARKING.md](docs/PARKING.md) | the three levels of parking |
| [docs/CLIENT.md](docs/CLIENT.md) | macOS client design |
| [docs/ROADMAP.md](docs/ROADMAP.md) | milestones, benchmarks and open questions |

## Layout

```
build.zig  build.zig.zon   Zig workspace
flake.nix  justfile        dev environment and tasks

src/core/                  protocol, session, pty, park — shared
src/daemon/                illogicald
src/cli/                   illogical

clients/macos/
  project.yml              XcodeGen source of truth (.xcodeproj is generated)
  Illogical/               the app
  Illogical/Supporting/Fonts/  JetBrains Mono and the Nerd Font symbols, shipped
  Packages/IllogicalKit/   pure-Swift protocol core

scripts/                   build-xcframework.sh, dist-daemon.sh, dist-app.sh
vendor/ghostty             submodule — the pin for both sides
docs/
```

## The ghostty pin

`vendor/ghostty` is a submodule at a fixed commit. Both the server's Zig module
and the client's XCFramework are built from it, which is what guarantees the two
sides agree on the snapshot format — a format that carries **no compatibility
guarantee** yet.

The pin is part of the version string, so `illogicald --version` reads
`0.0.0-dev+g<pin>` — and the app says so when the daemon answering the socket
was built from a different one. It is a marker in the session dropdown and
nothing more: whatever is running owns the terminals behind it, and a snapshot
that genuinely does not match fails loudly on its own.

Bumping the submodule is a protocol change. Rebuild both sides:

```bash
git -C vendor/ghostty checkout <new-sha>
just clean && just build && just xcframework
```

If `vendor/ghostty` is empty after a clone:

```bash
git submodule update --init --recursive
```

## Benchmarks

Superlogical has published memory numbers. They are the bar, and two of the four
are ones tmux currently wins — see
[docs/ROADMAP.md](docs/ROADMAP.md#the-benchmark-suite).

## Naming

Superlogical is Mitchell Hashimoto's. This is not that, so it is the other
thing.

## Licence

MIT — see [LICENSE](LICENSE). The binaries are statically linked, so
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) carries the terms of everything
compiled into them; both files ship inside the release tarball.
