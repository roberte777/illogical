#!/usr/bin/env bash
# Measure the server's memory per terminal, live vs parked.
#
# This is the M4 gate. Superlogical publishes 407 KiB per filled 10,000-line
# terminal against tmux's 4.89 MiB (macOS, phys_footprint). We measure the same
# shape: additional server footprint per terminal, filled the same way.
#
# It also measures what a *client connection* costs, which is the other row
# Superlogical publishes: 85 KiB per connection against tmux's 157, with 50
# filled terminals in the server. A connection's cost is its pipeline buffers,
# so the same figure is taken twice -- once with the clients live and once
# after they have gone quiet and level 3 of docs/PARKING.md has freed them.
#
# ⚠ This measures a RELEASE build, and builds one itself.
#
# A debug build is not off by a little, it is off by an order of magnitude, and
# not in a direction that flatters anything. Zig fills `undefined` with 0xAA, so
# every buffer a debug binary declares is written before it is ever used --
# including libghostty's four preheated ~390 KiB pages per terminal, which it
# allocates precisely because they are demand-paged and "only cost us address
# space". An empty terminal measures 1743 KiB debug against 105 KiB release.
# Every figure this compares against is from a release build.
#
# Usage: scripts/bench-memory.sh [terminal-count] [lines-per-terminal] [clients]
set -euo pipefail

count="${1:-20}"
lines="${2:-10000}"
clients="${3:-50}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="$(mktemp -d /tmp/illogical-bench.XXXXXX)"
sock="$state/server.sock"

# Its own prefix, so this never overwrites the debug binaries everything else
# in the repo expects to find in zig-out.
out="$root/.zig-bench"
daemon="$out/bin/illogicald"
cli="$out/bin/illogical"
echo "building release..." >&2
(cd "$root" && zig build -Doptimize=ReleaseFast --prefix "$out")

[ -x "$daemon" ] || { echo "no release binary at $daemon" >&2; exit 1; }

attached_pids=()
cleanup() {
  for p in ${attached_pids+"${attached_pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  kill "$pid" 2>/dev/null || true
  rm -rf "$state"
  return 0
}
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

"$daemon" --socket "$sock" --park-after 3 --client-park-after 3 >"$state/daemon.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
sleep 0.5

base=$(footprint)
printf 'server start, no terminals            %8s KiB\n' "$base"

# --- an empty terminal ------------------------------------------------------
#
# The fixed cost, before a byte of content: a pty, a libghostty terminal and
# whatever we hang off it. tmux is 15 KiB here and Superlogical 68, and both of
# them beat the two rows below that actually scale, so this is the row where
# being honest matters most.
for i in $(seq 1 "$count"); do
  ILLOGICAL_SOCK="$sock" "$cli" new -n "empty$i" -- /bin/sh -c 'sleep 600' >/dev/null
done
sleep 1.5
empty=$(footprint)
printf '%d empty 80x24 terminals (hot)         %8s KiB   %6s KiB/terminal\n' \
  "$count" "$empty" "$(( (empty - base) / count ))"

# --- what a client connection costs -----------------------------------------
#
# Measured here, against an empty terminal, rather than after the fill. What
# this row is meant to be is the standing cost of a connection: two threads and
# the pipeline buffers of docs/PARKING.md level 3. Attaching to a *filled*
# terminal instead measures the snapshot -- a megabyte per client through the
# queue, freed by A4 but kept on the release allocator's free list -- which
# reports 689 KiB/client and is an answer to a different question.
before_clients=$(footprint)
target=$(ILLOGICAL_SOCK="$sock" "$cli" list | awk 'NR == 2 { print $1 }')
for _ in $(seq 1 "$clients"); do
  ILLOGICAL_SOCK="$sock" "$cli" attach "$target" </dev/null >/dev/null 2>&1 &
  attached_pids+=("$!")
done
for _ in $(seq 1 200); do
  [ "$(ILLOGICAL_SOCK="$sock" "$cli" list | awk -v id="$target" '$1 == id { print $6 }')" -ge "$clients" ] && break
  sleep 0.25
done
sleep 1
with_clients=$(footprint)
printf '%d clients attached                    %8s KiB   %6s KiB/client\n' \
  "$clients" "$with_clients" "$(( (with_clients - before_clients) / clients ))"

sleep 5
parked_clients=$(footprint)
printf '%d clients idle, buffers parked        %8s KiB   %6s KiB/client\n' \
  "$clients" "$parked_clients" "$(( (parked_clients - before_clients) / clients ))"

for p in ${attached_pids+"${attached_pids[@]}"}; do kill "$p" 2>/dev/null || true; done
attached_pids=()
sleep 1

# Kill the terminals off again so the filled measurement below starts clean.
for id in $(ILLOGICAL_SOCK="$sock" "$cli" list | awk 'NR > 1 { print $1 }'); do
  ILLOGICAL_SOCK="$sock" "$cli" kill "$id" >/dev/null 2>&1 || true
done
for _ in $(seq 1 60); do
  [ "$(ILLOGICAL_SOCK="$sock" "$cli" list | grep -c ' live \| polled ')" -eq 0 ] && break
  sleep 0.25
done
sleep 1
base=$(footprint)
printf 'after killing them                    %8s KiB\n' "$base"

# One awk process per terminal writes the fill in a single pass, so the
# measurement is not dominated by shell startup.
for i in $(seq 1 "$count"); do
  ILLOGICAL_SOCK="$sock" "$cli" new -n "t$i" -- \
    /bin/sh -c "awk 'BEGIN{for(i=0;i<$lines;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'; sleep 600" \
    >/dev/null
done

# Wait for the footprint to *settle*, not merely to stop climbing.
#
# The fill and A5's incremental scrollback compression race each other, and
# which one wins depends on the build. An earlier version of this loop stopped
# at the first sample that was not higher than the last, which in a debug build
# landed after compression had kept up and in a release build landed on the raw
# peak -- 1876 KiB/terminal against 9979, from the same code. Neither was
# wrong; they were answers to different questions. This waits for three
# consecutive samples within 2% of each other, which is the settled figure.
echo "filling ${count}x${lines} lines..."
prev=0
stable=0
for _ in $(seq 1 120); do
  now=$(footprint)
  if [ "$prev" -gt 0 ] && [ "$(( (now > prev ? now - prev : prev - now) * 100 ))" -le "$(( prev * 2 ))" ]; then
    stable=$((stable + 1))
    [ "$stable" -ge 3 ] && break
  else
    stable=0
  fi
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

cat <<'NOTE'

Two things this cannot show you, both worth knowing before reading a zero as a
failure.

Freeing is not returning. A4 frees a quiet client's buffers and parking frees a
terminal outright -- the tests assert both directly, on capacity -- but whether
that shows up in phys_footprint depends on whether the allocator hands those
pages back to the kernel. The debug allocator does; the release one keeps them
on a free list for the next client.

And A5 gets there first. By the time the fill has settled, scrollback
compression has already released the physical pages with MADV_FREE_REUSABLE, so
parking has little left to reclaim in this metric. The live row is a terminal
that is already compressed, not a raw one.
NOTE
