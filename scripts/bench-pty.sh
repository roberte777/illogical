#!/usr/bin/env bash
# What the two PTY IO regimes cost. This is optimization A3.
#
# A hot PTY owns a dedicated OS thread blocked on read(); a parked one is a
# descriptor in a poller shared with every other parked PTY. Superlogical
# reports the second costing 5-10% of IO throughput [MEM t=504] and takes the
# trade because "that 5 to 10% speed isn't going to matter as much when a human
# isn't judging it". Two numbers follow from that claim and both are here:
#
#   1. Throughput, hot vs polled. Should be within ~10%.
#   2. Threads vs terminals. Should flatten, not track.
#
# Usage: scripts/bench-pty.sh [lines] [terminal-count] [repeats]
set -euo pipefail

lines="${1:-400000}"
terminals="${2:-32}"
repeats="${3:-3}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"

[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }

state=""
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  if [ -n "$state" ]; then rm -rf "$state"; fi
  return 0
}
trap cleanup EXIT

now() { printf '%s' "$EPOCHREALTIME"; }
elapsed_ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", (b - a) * 1000 }'; }

# Spin until a file appears. Spun rather than slept because these runs are
# under a second and a `sleep 0.05` would be a visible part of the answer.
#
# A `while` loop rather than `for _ in $(seq ...)`: bash materialises that
# whole list before the first iteration, and an earlier version of this script
# reported a flat 5455 ms for every workload because two million lines of `seq`
# output is what it was actually timing.
await_file() {
  local spins=0
  while [ ! -f "$1" ]; do
    spins=$((spins + 1))
    if [ "$spins" -gt 200000 ]; then return 1; fi
  done
}

# Thread count, without an entitlement.
#
# `ps -M` and `top -stats th` both need one on current macOS and refuse to
# answer. Every thread has a stack, and vmmap lists them -- which is the same
# tool scripts/bench-memory.sh already leans on for phys_footprint.
threads() { vmmap "$1" 2>/dev/null | grep -c '^Stack '; }

start_daemon() {
  state="$(mktemp -d /tmp/illogical-pty.XXXXXX)"
  # Never park to disk: this measures the descriptor's regime, and a terminal
  # that parked mid-run would be measuring something else entirely.
  "$daemon" --socket "$state/server.sock" --park-after 86400 \
    --pty-park-after "$1" >"$state/daemon.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do [ -S "$state/server.sock" ] && break; sleep 0.1; done
  sleep 0.3
}

stop_daemon() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
  rm -rf "$state"
  state=""
}

ilg() { ILLOGICAL_SOCK="$state/server.sock" "$cli" "$@"; }

# The regime column of `illogical list` for terminal $1.
regime_of() { ilg list | awk -v id="$1" '$1 == id { print $5 }'; }

await_regime() {
  local id="$1" want="$2"
  for _ in $(seq 1 200); do
    if [ "$(regime_of "$id")" = "$want" ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

# One timed run in a pinned regime. Prints milliseconds.
#
# The child gates on one file and signals completion with another, so the
# daemon is never asked anything while the clock runs. A pty writer blocks when
# its reader falls behind, so the time for the child to finish writing *is* the
# read path's throughput.
#
# Asking the daemon instead does not work, and the way it fails is worth
# recording: `illogical peek` takes the terminal's lock, the reader thread
# takes and drops that same lock once per chunk, and a pthread mutex is not
# fair. The peek loses every race for as long as the burst lasts, so an earlier
# version of this script reported 15 seconds for a workload that takes 170
# milliseconds -- it was timing lock starvation, in both regimes equally.
#
# The gate also exists so the clock starts only once the descriptor is
# definitely in the regime under test. Letting the child write immediately
# would measure the first maintenance tick in whichever regime it started in.
throughput_run() {
  local want="$1"
  local gate="$state/go" done_file="$state/done"
  local out
  out=$(ilg new -s Bench -n io -- /bin/sh -c \
    "while [ ! -f '$gate' ]; do sleep 0.02; done
     awk 'BEGIN{for(i=0;i<$lines;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'
     touch '$done_file'
     sleep 600")
  local id
  id=$(printf '%s' "$out" | grep -oE '[0-9]+' | head -1)

  await_regime "$id" "$want" || {
    echo "terminal $id never reached '$want' (is $(regime_of "$id"))" >&2
    return 1
  }

  local start finish
  start=$(now)
  touch "$gate"
  await_file "$done_file"
  finish=$(now)

  # It must not have drifted out of the regime under test while we watched.
  [ "$(regime_of "$id")" = "$want" ] || {
    echo "terminal $id left '$want' mid-run" >&2
    return 1
  }

  ilg kill "$id" >/dev/null 2>&1 || true
  rm -f "$gate" "$done_file"
  elapsed_ms "$start" "$finish"
}

# The same thing with `fleet` terminals writing at once. Prints milliseconds.
#
# This is the shape the 5-10% figure should show up in, if it shows up at all:
# one PTY never contends for the poller thread, because with a single
# descriptor a kqueue wake is lost in the noise of parsing what it announced.
# Many at once is where a shared thread has to serialize what many dedicated
# threads would have done in parallel.
throughput_fleet() {
  local want="$1" fleet="$2"
  local gate="$state/fleet-go"
  # The same total work as the single-pty run, split across the fleet, so the
  # two tables are comparable rather than merely adjacent.
  local each=$((lines / fleet))
  local ids=()
  for i in $(seq 1 "$fleet"); do
    ids+=("$(ilg new -s Fleet -n "io$i" -- /bin/sh -c \
      "while [ ! -f '$gate' ]; do sleep 0.02; done
       awk 'BEGIN{for(i=0;i<$each;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'
       touch '$state/fleet-done.$i'
       sleep 600" | grep -oE '[0-9]+' | head -1)")
  done
  for id in "${ids[@]}"; do
    await_regime "$id" "$want" || {
      echo "terminal $id never reached '$want'" >&2
      return 1
    }
  done

  # The paths to wait on, resolved once. Anything that forks inside the spin
  # below -- `ls`, `grep`, a `$(seq)` -- costs more than the thing being timed.
  local want=()
  for i in $(seq 1 "$fleet"); do want+=("$state/fleet-done.$i"); done

  local start finish
  start=$(now)
  touch "$gate"
  local missing=1 spins=0
  while [ "$missing" -ne 0 ]; do
    missing=0
    for f in "${want[@]}"; do
      if [ ! -f "$f" ]; then missing=1; fi
    done
    spins=$((spins + 1))
    if [ "$spins" -gt 2000000 ]; then break; fi
  done
  finish=$(now)

  for id in "${ids[@]}"; do ilg kill "$id" >/dev/null 2>&1 || true; done
  rm -f "$gate" "$state"/fleet-done.*
  elapsed_ms "$start" "$finish"
}

median() { printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

echo "illogical — PTY IO regimes (A3)"
echo
printf 'workload: %s lines through one pty, median of %s\n\n' "$lines" "$repeats"

declare -a hot_ms polled_ms
for regime in hot polled; do
  # A huge threshold never demotes; a zero one demotes on the first tick.
  if [ "$regime" = hot ]; then start_daemon 86400; else start_daemon 0; fi
  for r in $(seq 1 "$repeats"); do
    ms=$(throughput_run "$regime")
    printf '  %-8s run %s/%s  %8s ms\n' "$regime" "$r" "$repeats" "$ms"
    if [ "$regime" = hot ]; then hot_ms+=("$ms"); else polled_ms+=("$ms"); fi
  done
  stop_daemon
done
echo

hot=$(median "${hot_ms[@]}")
polled=$(median "${polled_ms[@]}")
printf '%-30s %8s ms\n' "one pty, hot" "$hot"
printf '%-30s %8s ms\n' "one pty, polled" "$polled"
printf '%-30s %8s%%\n' "cost of polling" \
  "$(awk -v h="$hot" -v p="$polled" 'BEGIN { printf "%+.1f", (p - h) / h * 100 }')"

echo
fleet=8
fleet_threads="?"
for regime in hot polled; do
  if [ "$regime" = hot ]; then start_daemon 86400; else start_daemon 0; fi
  fleet_threads=$(sed -n 's/.*, \([0-9]*\) poller threads.*/\1/p' "$state/daemon.log" | head -1)
  ms=$(throughput_fleet "$regime" "$fleet")
  if [ "$regime" = hot ]; then fleet_hot=$ms; else fleet_polled=$ms; fi
  stop_daemon
done
printf '%-30s %8s ms\n' "$fleet ptys at once, hot" "$fleet_hot"
printf '%-30s %8s ms\n' "$fleet ptys at once, polled" "$fleet_polled"
printf '%-30s %8s%%\n' "cost of polling" \
  "$(awk -v h="$fleet_hot" -v p="$fleet_polled" 'BEGIN { printf "%+.1f", (p - h) / h * 100 }')"
printf '  (%s poller threads for all of them)\n' "$fleet_threads"

echo
echo "threads vs terminals"
echo

# Idle shells, so the only thing being measured is what watching them costs.
start_daemon 3
# A moment for the client threads of the calls above to be retired, which
# happens on the maintenance tick. Otherwise they are counted as the daemon's.
sleep 0.6
baseline=$(threads "$pid")
printf '%-30s %8s threads\n' "server, no terminals" "$baseline"

for n in 1 "$terminals"; do
  while [ "$(ilg list | grep -c ' live ')" -lt "$n" ]; do
    ilg new -s Fleet -n idle -- /bin/sh -c 'sleep 600' >/dev/null
  done

  # Every one of them is observed by nobody, but the demotion delay has not
  # run yet, so this is what a thread-per-PTY server costs.
  sleep 0.6
  printf '%-30s %8s threads   (%s hot)\n' "$n terminals, hot" \
    "$(threads "$pid")" "$(ilg list | grep -c ' hot ')"

  # And now past it.
  sleep 3.5
  printf '%-30s %8s threads   (%s polled)\n' "$n terminals, unobserved" \
    "$(threads "$pid")" "$(ilg list | grep -c ' polled ')"
done
stop_daemon

cat <<NOTE

Read the thread table as a difference, not a total. $baseline of those threads are
the daemon itself -- the accept loop, the maintenance tick, the $fleet_threads poller
threads and the std.Io pool -- and it has all of them whether it is holding one
terminal or ten thousand. What the last row says is that the terminals add none.
NOTE
