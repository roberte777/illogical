#!/usr/bin/env bash
# Build a release tarball of the server for one target.
#
# The server is one binary and it ships on its own: `illogicald` for the box
# you want sessions on, plus the `illogical` CLI beside it, in a tarball you
# unpack onto a `PATH`. That is the whole install — nothing to start, because
# `ssh <box> illogicald --stdio` starts a daemon there when there is none, and
# `illogicald --ensure` does the same by hand.
#
# In a release the app embeds this script's output: the app job stages the
# `macos-universal` artifact rather than building its own, so the daemon in the
# bundle and the one in the tarball are the same compile. (Not byte-identical —
# Xcode re-signs it on the way into the bundle.)
#
# Locally they still differ, and should: `just stage-daemon` falls back to the
# Debug host-arch binary `just build` produced, which is what the dev loop
# wants, while this script produces ReleaseFast, stripped and lipo'd. A release
# daemon under a dev app reads as version skew in the app's dropdown, which is
# correct — it really is a different build.
#
# **musl, not gnu, for Linux.** Statically linked against musl runs on any
# distribution and imposes no glibc floor. For something whose install story is
# "drop this on the box", that is worth more than the few megabytes; and it is
# what was actually tested cross-compiling.
#
# Targets:
#   native        this machine
#   universal     both macOS arches, lipo'd into one binary (macOS host only)
#   <zig triple>  e.g. x86_64-linux-musl, aarch64-linux-musl
#
# Cross-compiling to Linux from a Mac works at the current ghostty pin and is
# the local convenience; the release builds Linux natively on Linux runners,
# because a native build gets a smoke run of the artifact for free and a future
# pin bump that stops cross-compiling should not stop the release.
#
# Usage: scripts/dist-daemon.sh [target] [version]
set -euo pipefail

target="${1:-native}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${2:-}"
if [ -z "$version" ]; then
  version="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)"
fi
# Tags are `v0.1.0`; versions are not. Without this `--version` reads
# `v0.1.0+g492300cad104`, and a `v` in the middle of a version string is a
# thing every tool that parses one has to be told about.
version="${version#v}"

# The revision the binary is built against, stamped into `--version` and into
# every `welcome` frame. It is what decides whether two builds agree about a
# snapshot, so a release with `unknown` in it cannot be compared with anything.
pin="$(git -C vendor/ghostty rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
[ "$pin" != "unknown" ] || { echo "vendor/ghostty is not checked out" >&2; exit 1; }

dist="$root/dist"
work="$(mktemp -d "${TMPDIR:-/tmp}/illogical-dist.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dist"

# `zig build` into a prefix of its own. Never `zig-out`: that is what `just
# stage-daemon` reads, and a release build landing there would put a
# ReleaseFast stripped binary into somebody's Debug app bundle without
# saying so.
build() {
  local triple="$1" prefix="$2"
  local args=(
    -Doptimize=ReleaseFast
    -Dstrip=true
    -Dversion="$version"
    -Dghostty-pin="$pin"
    --prefix "$prefix"
  )
  [ "$triple" = "native" ] || args+=(-Dtarget="$triple")
  echo "==> building $triple ($version+g$pin)"
  zig build "${args[@]}"
}

# What the tarball is called, and what the binaries in it can run on.
case "$target" in
  universal)
    [ "$(uname -s)" = "Darwin" ] || { echo "universal needs a macOS host" >&2; exit 1; }
    label="macos-universal"
    build aarch64-macos "$work/arm64"
    build x86_64-macos "$work/x86_64"
    mkdir -p "$work/out"
    for binary in illogicald illogical; do
      # One file for both Macs. The bundle carries this, so a user on an Intel
      # machine gets a daemon that runs rather than a bundle that does not
      # launch.
      lipo -create -output "$work/out/$binary" \
        "$work/arm64/bin/$binary" "$work/x86_64/bin/$binary"
    done
    # One database for both Macs: it is compiled terminfo, not machine code.
    prefix="$work/arm64"
    ;;
  native)
    # Spelled the way the zig triples are, so `native` and an explicit target
    # for the same machine produce the same filename rather than two.
    case "$(uname -s)" in
      Darwin) label_os="macos" ;;
      *) label_os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac
    case "$(uname -m)" in
      arm64) label_arch="aarch64" ;;
      *) label_arch="$(uname -m)" ;;
    esac
    label="$label_os-$label_arch"
    build native "$work/native"
    mkdir -p "$work/out"
    cp "$work/native/bin/illogicald" "$work/native/bin/illogical" "$work/out/"
    prefix="$work/native"
    ;;
  *)
    # `x86_64-linux-musl` -> `linux-x86_64`. The abi is not in the name: musl
    # is the only Linux flavour shipped, and saying so in every filename
    # invites the question of where the gnu one is.
    arch="${target%%-*}"
    rest="${target#*-}"
    os="${rest%%-*}"
    label="$os-$arch"
    build "$target" "$work/$target"
    mkdir -p "$work/out"
    cp "$work/$target/bin/illogicald" "$work/$target/bin/illogical" "$work/out/"
    prefix="$work/$target"
    ;;
esac

# The terminfo database travels with them too. `illogicald` tells every child
# TERM=xterm-ghostty and points its TERMINFO at this, which is the only way that
# name resolves on a host that has never had ghostty on it -- and a child with
# no terminfo at all cannot move its own cursor, so its shell redraws a prompt
# by printing a second one. Beside the binaries rather than in a `share/`,
# because the tarball is unpacked onto a PATH: `src/core/pty.zig` looks for it
# in the directory holding the daemon.
cp -R "$prefix/share/terminfo" "$work/out/terminfo"

# The licences travel with the binaries, because MIT's one condition is that
# the notice accompanies copies -- and `illogicald` statically links ghostty,
# simdutf and highway, none of which are ours to ship bare.
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES" "$work/out/"

# No version in the name. The release page already carries the tag and
# `--version` carries the rest, and a name with the tag in it cannot be reached
# through `releases/latest/download/...` -- which is the URL the README hands
# people, and which 404'd against every name this script used to produce.
tarball="$dist/illogicald-$label.tar.gz"
tar -czf "$tarball" -C "$work/out" illogicald illogical terminfo LICENSE THIRD_PARTY_NOTICES
echo "==> $tarball"

# Beside the tarballs rather than inside one, and rewritten from whatever is in
# `dist/` each time, so `just dist` leaves one file covering everything it
# built. Bare names rather than `./name`: `shasum -c` and `sha256sum -c` both
# read the path as written, and `./x` fails for anyone who fetched `x`.
(cd "$dist" && shasum -a 256 -- *.tar.gz > SHA256SUMS)
ls -la "$dist"
