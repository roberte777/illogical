#!/usr/bin/env bash
# Measure attach latency against scrollback size.
#
# This is the M2 gate (docs/ROADMAP.md): the time from `attach` to
# `snapshot_ready` must not vary with how much scrollback the terminal has.
# The server encodes the active screen, sends the ready marker, and only then
# sends history, so the client can paint after O(screen) bytes no matter how
# many megabytes follow.
#
# Two numbers per shape, from the same run:
#
#   attach -> ready   what the user waits for. Must be flat.
#   attach -> end     the whole snapshot, history included. Grows with
#                     scrollback, and is supposed to.
#
# The gap between them is the change. Before it, they were the same number.
#
# The app emits both as `milestone` lines when ILLOGICAL_TRACE is set, which
# is what this reads: a gate has to be runnable without a GUI.
#
# Usage: scripts/bench-attach.sh [runs] [lines...]
set -euo pipefail

runs="${1:-5}"
shift || true
sizes=("${@:-200 20000 200000}")
# shellcheck disable=SC2206
sizes=(${sizes[*]})

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/clients/macos/.build/xcode/Build/Products/Debug/Illogical.app/Contents/MacOS/Illogical"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"
state="$(mktemp -d /tmp/illogical-attach.XXXXXX)"

[ -x "$app" ] || { echo "build first: just app" >&2; exit 1; }
[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }

pids=()
cleanup() {
  pkill -f "$app" 2>/dev/null || true
  # Children first: a daemon sitting in a PTY read does not die until that
  # read returns. See the same note in bench-launch.sh.
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

daemon_sock=""
start_daemon() {
  local name="$1"
  local fill="$2"
  local sock="$state/$name.sock"

  "$daemon" --socket "$sock" >"$state/$name-daemon.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done

  ILLOGICAL_SOCK="$sock" "$cli" new -s "$name" -n "$name" -- \
    /bin/sh -c "awk 'BEGIN{for(i=0;i<$fill;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'; sleep 600" \
    >/dev/null
  daemon_sock="$sock"
}

# The `since-attach=NNms` field of the first line matching `$1`.
since_attach() {
  awk -v want="$1" '$0 ~ want {
      for (i = 1; i <= NF; i++) if ($i ~ /^since-attach=/) {
        sub(/since-attach=/, "", $i); sub(/ms$/, "", $i); print $i; exit
      }
    }' "$2"
}

# The `bytes=N` field of the snapshot-ready line: how much the client had to
# read before it could paint.
ready_bytes() {
  awk '/milestone snapshot-ready/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^bytes=/) {
        sub(/bytes=/, "", $i); print $i; exit
      }
    }' "$1"
}

# One launch against a socket. Prints "<attach->ready ms> <attach->end ms> <ready bytes>".
run() {
  local sock="$1" trace="$2"
  : >"$trace"
  ILLOGICAL_SOCK="$sock" ILLOGICAL_TRACE="$trace" "$app" >/dev/null 2>&1 &
  local app_pid=$!
  for _ in $(seq 1 300); do
    grep -q "milestone snapshot-end" "$trace" 2>/dev/null && break
    sleep 0.1
  done
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true

  local ready done_ bytes
  ready=$(since_attach 'milestone snapshot-ready' "$trace")
  done_=$(since_attach 'milestone snapshot-end' "$trace")
  bytes=$(ready_bytes "$trace")
  echo "${ready:-nan} ${done_:-nan} ${bytes:-nan}"
}

median() {
  tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR] = $1 } END {
    if (NR == 0) { print "nan"; exit }
    printf "%.1f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
  }'
}

socks=()
for lines in "${sizes[@]}"; do
  start_daemon "n$lines" "$lines"
  socks+=("$lines:$daemon_sock")
done

# Wait for every filler to stop writing, using the daemon's own idle clock
# rather than a fixed sleep. This is not politeness: the reader thread holds
# the terminal lock while it applies PTY output, so attaching to a terminal
# that is still a firehose measures how long the filler has left to run and
# nothing else. At a few hundred thousand lines that dwarfs the number we are
# actually after.
wait_idle() {
  local sock="$1"
  for _ in $(seq 1 600); do
    local idle
    idle=$(ILLOGICAL_SOCK="$sock" "$cli" list 2>/dev/null |
      awk 'NR > 1 { gsub(/s$/, "", $NF); print $NF }' | sort -n | head -1)
    [ -n "$idle" ] && [ "$idle" -ge 2 ] 2>/dev/null && return 0
    sleep 0.5
  done
  echo "warning: terminals on $sock never went idle" >&2
}
for entry in "${socks[@]}"; do wait_idle "${entry#*:}"; done

printf 'runs: %s\n\n' "$runs"
printf '%-12s  %16s  %16s  %14s\n' \
  'scrollback' 'attach->ready' 'attach->end' 'bytes at ready'

for entry in "${socks[@]}"; do
  lines="${entry%%:*}"
  sock="${entry#*:}"
  readys=""
  ends=""
  bytes=""
  for i in $(seq 1 "$runs"); do
    read -r r e b <<<"$(run "$sock" "$state/trace-$lines-$i.txt")"
    readys="$readys $r"
    ends="$ends $e"
    bytes="$bytes $b"
  done
  printf '%-12s  %14s ms  %14s ms  %14s\n' \
    "$lines lines" \
    "$(echo "$readys" | median)" \
    "$(echo "$ends" | median)" \
    "$(echo "$bytes" | median)"
done

cat <<'EOF'

The gate is the first column: it must not move across rows. The second one
should, and by roughly the ratio of the scrollback sizes -- that is the
history the client is no longer waiting on. "bytes at ready" is how much of
the snapshot the client had read when it painted.
EOF
