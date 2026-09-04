# illogical

A terminal multiplexer with persistent sessions, built on
[libghostty-vt](https://github.com/ghostty-org/ghostty).

The server owns the PTYs and keeps a real terminal per session. Clients are
native applications running the same VT engine, so the server can ship them
**unprocessed** output and let them draw it. Attaching paints the current screen
immediately from a binary snapshot, then streams scrollback in behind it. Idle
sessions are snapshotted to disk and cost nothing until they speak again.

> Clean-room build against the public description of Superlogical. See
> [docs/GOALS.md](docs/GOALS.md) for what that means and what it does not.

**Status: scaffold.** Everything builds and the protocol is defined on both
sides; the daemon does not run sessions yet. See [docs/ROADMAP.md](docs/ROADMAP.md).

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
just app               # build the app
just test-swift        # protocol tests; needs neither of the above
```

`just` on its own lists every task.

## How it works

```
child ──► PTY ──► illogicald ──┬──► ghostty-vt terminal ──► snapshot.gsnp (park)
                               │
                               └──► raw bytes ──► client ──► ghostty-vt ──► Metal
```

Both ends run the same terminal implementation, built from the same pinned
ghostty revision. The server's copy exists so that attach is O(screen) instead
of O(history); the client's copy exists so it can draw.

Read in this order:

| Document | |
| --- | --- |
| [docs/GOALS.md](docs/GOALS.md) | what this is for, and how we will know it works |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | components and data flow |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | the wire format and the attach handshake |
| [docs/PARKING.md](docs/PARKING.md) | snapshot-on-idle and rehydration |
| [docs/ROADMAP.md](docs/ROADMAP.md) | milestones and open questions |

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

## Naming

Superlogical is Mitchell Hashimoto's. This is not that, so it is the other
thing.
