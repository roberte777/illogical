#!/usr/bin/env bash
# Measure the server's memory per terminal, live vs parked.
#
# This is the M4 gate. Superlogical publishes 407 KiB per filled 10,000-line
# terminal against tmux's 4.89 MiB (macOS, phys_footprint). We measure the same
# shape: additional server footprint per terminal, filled the same way.
#
# Usage: scripts/bench-memory.sh [terminal-count] [lines-per-terminal]
set -euo pipefail

count="${1:-20}"
lines="${2:-10000}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="$(mktemp -d /tmp/illogical-bench.XXXXXX)"
sock="$state/server.sock"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"

[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }

cleanup() { kill "$pid" 2>/dev/null || true; rm -rf "$state"; }
trap cleanup EXIT

# phys_footprint, in KiB.
#
# NOT `ps -o rss`. libghostty releases compressed scrollback with
# MADV_FREE_REUSABLE, which leaves the pages counted in RSS on macOS until
# there is memory pressure, so RSS shows no win at all. phys_footprint is the
# metric that reflects it -- and is what Superlogical's own charts report.
footprint() {
  vmmap --summary "$pid" 2>/dev/null \
    | awk '/Physical footprint:/ { v=$3; sub(/K$/,"",v); if (v ~ /M$/) { sub(/M$/,"",v); v=v*1024 } ; if (v ~ /G$/) { sub(/G$/,"",v); v=v*1024*1024 }; print int(v); exit }'
}
residency_count() { ILLOGICAL_SOCK="$sock" "$cli" list | grep -c "$1" || true; }

# Wait until `count` terminals report `state`, or give up.
await() {
  local want="$1" state_name="$2" tries="${3:-600}"
  for _ in $(seq 1 "$tries"); do
    [ "$(residency_count "$state_name")" -ge "$want" ] && return 0
    sleep 0.25
  done
  return 1
}

"$daemon" --socket "$sock" --park-after 3 >"$state/daemon.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
sleep 0.5

base=$(footprint)
printf 'server start, no terminals            %8s KiB\n' "$base"

# One awk process per terminal writes the fill in a single pass, so the
# measurement is not dominated by shell startup.
for i in $(seq 1 "$count"); do
  ILLOGICAL_SOCK="$sock" "$cli" new -n "t$i" -- \
    /bin/sh -c "awk 'BEGIN{for(i=0;i<$lines;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'; sleep 600" \
    >/dev/null
done

# The fill is done when everything has gone quiet, which is also when parking
# starts. Measure live at the last moment before that.
echo "filling ${count}x${lines} lines..."
prev=0
while :; do
  now=$(footprint)
  [ "$now" -le "$prev" ] && break
  prev=$now
  sleep 0.5
done
filled=$prev
printf 'with %d filled terminals (live)        %8s KiB   %6s KiB/terminal\n' \
  "$count" "$filled" "$(( (filled - base) / count ))"

if await "$count" parked; then
  parked=$(footprint)
  printf 'all %d parked                          %8s KiB   %6s KiB/terminal\n' \
    "$count" "$parked" "$(( (parked - base) / count ))"
  printf 'reclaimed by parking                  %8s KiB   (%s%%)\n' \
    "$(( filled - parked ))" "$(( (filled - parked) * 100 / (filled - base) ))"
else
  echo "WARNING: only $(residency_count parked)/$count parked before the timeout"
fi

snap=$(du -sk "$state/sessions" 2>/dev/null | cut -f1 || echo 0)
printf 'snapshots on disk                     %8s KiB   %6s KiB/terminal\n' \
  "$snap" "$(( snap / count ))"
