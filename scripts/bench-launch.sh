#!/usr/bin/env bash
# Measure the client's launch budget, and whether the first frame cares about
# scrollback.
#
# This is the M3 gate, and it is two numbers (docs/GOALS.md G7):
#
#   process exec -> window on screen. Nothing on screen may wait for the
#   network, so this must not move when the server is slow or absent.
#
#   snapshot_ready -> the frame that shows it. This must not vary with
#   scrollback size. If it does, something is buffering that should be
#   streaming.
#
# The app emits both as os_signpost events for Instruments and, when
# ILLOGICAL_TRACE is set, as `milestone <name> <seconds>` lines. This reads
# the latter, because a gate has to be runnable without a GUI.
#
# Two daemons rather than two terminals on one: the client attaches to what it
# is given, and giving it exactly one terminal is simpler than teaching it to
# be told which.
#
# Usage: scripts/bench-launch.sh [runs] [scrollback-lines]
set -euo pipefail

runs="${1:-5}"
lines="${2:-20000}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/clients/macos/.build/xcode/Build/Products/Debug/Illogical.app/Contents/MacOS/Illogical"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"
state="$(mktemp -d /tmp/illogical-launch.XXXXXX)"

[ -x "$app" ] || { echo "build first: just app" >&2; exit 1; }
[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }

pids=()
cleanup() {
  pkill -f "$app" 2>/dev/null || true

  # Children first, then the daemon. A daemon holding a terminal sits in an
  # uninterruptible PTY read and does not die on SIGTERM *or* SIGKILL until
  # that read returns, so killing it first leaves it around for as long as
  # its child runs -- ten minutes, for our filler.
  #
  # Close the other end instead and the daemon exits cleanly on its own,
  # with no signal to it at all: shutdown works, it just cannot be asked for
  # first. And the child needs SIGKILL, not SIGTERM: `pkill -P` sends TERM,
  # which an interactive `sh` ignores outright.
  for p in "${pids[@]:-}"; do
    [ -n "$p" ] || continue
    pkill -9 -P "$p" 2>/dev/null || true
  done
  sleep 0.3
  for p in "${pids[@]:-}"; do
    [ -n "$p" ] || continue
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$state"
}
trap cleanup EXIT

# A daemon holding exactly one terminal, filled with `$2` lines. Sets
# `daemon_sock`, and records the pid, rather than printing: a command
# substitution would put the pid in a subshell where cleanup cannot see it.
daemon_sock=""
start_daemon() {
  local name="$1"
  local fill="$2"
  local sock="$state/$name.sock"

  "$daemon" --socket "$sock" >"$state/$name-daemon.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done

  if [ "$fill" -gt 0 ]; then
    ILLOGICAL_SOCK="$sock" "$cli" new -s "$name" -n "$name" -- \
      /bin/sh -c "awk 'BEGIN{for(i=0;i<$fill;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'; sleep 120" \
      >/dev/null
  else
    ILLOGICAL_SOCK="$sock" "$cli" new -s "$name" -n "$name" >/dev/null
  fi
  daemon_sock="$sock"
}

# One launch against a socket. Prints "<window-visible s> <since-ready ms>".
run() {
  local sock="$1" trace="$2"
  : >"$trace"
  ILLOGICAL_SOCK="$sock" ILLOGICAL_TRACE="$trace" "$app" >/dev/null 2>&1 &
  local app_pid=$!
  for _ in $(seq 1 150); do
    grep -q "milestone first-frame" "$trace" 2>/dev/null && break
    sleep 0.1
  done
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true

  local visible decoded ready
  visible=$(awk '/milestone window-visible/ { print $4; exit }' "$trace")
  decoded=$(since_ready 'milestone snapshot-decoded' "$trace")
  ready=$(since_ready 'milestone first-frame' "$trace")
  echo "${visible:-nan} ${decoded:-nan} ${ready:-nan}"
}

# The `since-ready=NNms` field of the first line matching `$1`.
since_ready() {
  awk -v want="$1" '$0 ~ want {
      for (i = 1; i <= NF; i++) if ($i ~ /^since-ready=/) {
        sub(/since-ready=/, "", $i); sub(/ms$/, "", $i); print $i; exit
      }
    }' "$2"
}

median() {
  tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR] = $1 } END {
    if (NR == 0) { print "nan"; exit }
    printf "%.1f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
  }'
}

# Three shapes, because two would not separate the two costs. "screenful"
# has a full screen of text and almost no scrollback, so the difference
# between it and "empty" is glyph work on the first frame, and the difference
# between it and "filled" is scrollback. Only the second one is the gate.
start_daemon empty 0
empty_sock="$daemon_sock"
start_daemon screenful 200
screenful_sock="$daemon_sock"
start_daemon filled "$lines"
filled_sock="$daemon_sock"
# Let the filler finish writing before anything attaches.
sleep 3

printf 'runs: %s, scrollback: %s lines\n\n' "$runs" "$lines"
printf '%-8s  %14s  %14s  %19s\n' \
  '' 'launch->window' 'ready->decoded' 'ready->first frame'

for group in "empty:$empty_sock" "screenful:$screenful_sock" "filled:$filled_sock"; do
  name="${group%%:*}"
  sock="${group#*:}"
  visible=""
  decoded=""
  ready=""
  for i in $(seq 1 "$runs"); do
    read -r v d r <<<"$(run "$sock" "$state/$name-$i.log")"
    visible="$visible $(awk -v x="$v" 'BEGIN { printf "%.1f", x * 1000 }')"
    decoded="$decoded $d"
    ready="$ready $r"
  done
  printf '%-8s  %11s ms  %11s ms  %16s ms\n' \
    "$name" "$(echo "$visible" | median)" "$(echo "$decoded" | median)" \
    "$(echo "$ready" | median)"
done

cat <<'NOTE'

The gate is "screenful" against "filled": the same screen of text with and
without a large history behind it. Those two must not differ, because the
first frame is the snapshot's active screen and history arrives after it.

"empty" against "screenful" is expected to differ, and is not the gate: an
empty first frame has almost no glyphs to shape or rasterize.

"ready->decoded" says where any difference came from. "launch->window" is a
Debug build unless you built Release, so treat it as a ceiling.
NOTE
