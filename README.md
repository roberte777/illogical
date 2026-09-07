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

**Status: M5.** The daemon runs sessions, parks idle terminals to disk, and the
Mac client attaches to them — on this machine or on another one over SSH,
several at a time in one window. What is measured and what is not is in
[docs/ROADMAP.md](docs/ROADMAP.md).

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
  Illogical/Supporting/Fonts/  JetBrains Mono, shipped as the default face
  Packages/IllogicalKit/   pure-Swift protocol core

scripts/                   build-xcframework.sh
vendor/ghostty             submodule — the pin for both sides
docs/
```

## The ghostty pin

`vendor/ghostty` is a submodule at a fixed commit. Both the server's Zig module
and the client's XCFramework are built from it, which is what guarantees the two
sides agree on the snapshot format — a format that carries **no compatibility
guarantee** yet.

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
