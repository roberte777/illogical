#!/usr/bin/env bash
# What the remote transport costs.
#
# This is the M5 gate's number (docs/ROADMAP.md). `illogicald --stdio` is a
# splice: it copies bytes between an SSH pipe and the host's own unix socket
# and parses nothing. So attaching *through* it should cost what attaching
# directly costs, plus one copy in each direction — and if it does not, the
# bridge is doing something it should not be.
#
# Two rows, from the same daemon and the same terminal:
#
#   direct    the app on the unix socket, as it has always been
#   bridged   the app on `ssh <dest> illogicald --stdio`, which lands on
#             that same socket at the far end
#
# `ssh` itself is stood in for. A real one measures a network, which is a
# different question with no reference number and no repeatable answer; this
# measures the bridge, which is the part we wrote. Point ILLOGICAL_SSH at a
# real ssh and pass a real destination if you want the other one.
#
# Usage: scripts/bench-remote.sh [runs] [scrollback-lines]
set -euo pipefail

runs="${1:-5}"
lines="${2:-20000}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/clients/macos/.build/xcode/Build/Products/Debug/Illogical.app/Contents/MacOS/Illogical"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"
[ -x "$app" ] || { echo "build first: just app" >&2; exit 1; }
[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }

# After the guards above, so a missing binary does not leave a temp directory
# behind, and before anything that needs cleaning up.
state="$(mktemp -d /tmp/illogical-remote.XXXXXX)"
pids=()
cleanup() {
  pkill -f "$app" 2>/dev/null || true
  pkill -f "illogicald --stdio --socket $state" 2>/dev/null || true
  # Children first: a daemon sitting in a PTY read does not die until that
  # read returns. Same note as bench-attach.sh.
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

# Sets `daemon_sock`. Deliberately not printed on stdout and read back with
# `$(...)`: that runs the function in a subshell, where the `pids+=` below
# would be appended to a copy and the cleanup trap would find nothing to kill.
# A daemon holding a terminal does not die on its own.
daemon_sock=""
start_daemon() {
  local name="$1" fill="$2"
  local sock="$state/$name.sock"
  # Parking pushed out of reach: attaching to a parked terminal serves the
  # compressed park file off disk instead of encoding a live one, and timing
  # one path against the other would call the difference "the bridge".
  "$daemon" --socket "$sock" --park-after 86400 >"$state/$name-daemon.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
  if [ "$fill" -gt 0 ]; then
    ILLOGICAL_SOCK="$sock" "$cli" new -s "$name" -n "$name" -- \
      /bin/sh -c "awk 'BEGIN{for(i=0;i<$fill;i++) print \"line \" i \" ---- filler text to make this a realistic terminal line\"}'; sleep 86400" \
      >/dev/null
  fi
  daemon_sock="$sock"
}

# The `since-attach=NNms` field of the first line matching $1.
since_attach() {
  awk -v want="$1" '$0 ~ want {
      for (i = 1; i <= NF; i++) if ($i ~ /^since-attach=/) {
        sub(/since-attach=/, "", $i); sub(/ms$/, "", $i); print $i; exit
      }
    }' "$2"
}

median() {
  tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR] = $1 } END {
    if (NR == 0) { print "nan"; exit }
    printf "%.1f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
  }'
}

# One launch. Prints "<attach->ready ms> <attach->end ms>".
run() { # trace-file, then the environment already exported by the caller
  local trace="$1"
  : >"$trace"
  ILLOGICAL_TRACE="$trace" "$app" >/dev/null 2>&1 &
  local app_pid=$!
  for _ in $(seq 1 300); do
    grep -q "milestone snapshot-end" "$trace" 2>/dev/null && break
    sleep 0.1
  done
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  local ready done_
  ready=$(since_attach 'milestone snapshot-ready' "$trace")
  done_=$(since_attach 'milestone snapshot-end' "$trace")
  # `${x:-nan}`, not `|| echo nan`: `since_attach` is a bare awk, which exits 0
  # whether or not it matched, so the `||` never fired. A run that never
  # reached the milestone printed an empty first field and `read -r r e` then
  # put the *second* number in the first column.
  echo "${ready:-nan} ${done_:-nan}"
}

echo "runs=$runs scrollback=$lines lines"
echo

start_daemon full "$lines"
full_sock="$daemon_sock"

# Wait for the filler to stop writing before anything attaches. Not politeness,
# and the reason is the same one bench-attach.sh gives: the reader thread holds
# the terminal lock while it applies PTY output, so attaching to a terminal that
# is still a firehose measures how long the filler has left to run rather than
# what the bridge costs. Without this the table below was timing the writer.
wait_idle() {
  local sock="$1"
  local rows idle empty=0
  for _ in $(seq 1 2400); do
    # `|| true` on both: a bare `x=$(...)` takes the pipeline's exit status as
    # its own, and under `set -euo pipefail` that ends the script -- silently,
    # because the `2>/dev/null` here is exactly for the seconds while the
    # daemon is still coming up and `list` cannot connect. The whole benchmark
    # exited 1 with no output and looked like a build failure.
    # The status is kept, because an empty `rows` has two very different
    # causes and the diagnosis below is now load-bearing: `list` answered and
    # said there is nothing, or `list` could not connect at all and its
    # complaint went to /dev/null.
    rows=$(ILLOGICAL_SOCK="$sock" "$cli" list 2>/dev/null | awk 'NR > 1')
    rc=$?
    if [ -z "$rows" ]; then
      # Ten seconds of this is not a slow filler; it is a daemon that never
      # got a terminal, or one that has since died. Waiting the full twenty
      # minutes to say so wastes the run -- the long ceiling below is for a
      # genuinely large scrollback, which only applies once one exists.
      empty=$((empty + 1))
      if [ "$empty" -ge 20 ]; then
        if [ "$rc" -ne 0 ]; then
          echo "cannot list $sock after 10s; the daemon is not answering" >&2
        else
          echo "no terminals on $sock after 10s; the daemon never got one" >&2
        fi
        exit 1
      fi
      sleep 0.5
      continue
    fi
    empty=0
    idle=$(printf '%s\n' "$rows" |
      awk '{ gsub(/s$/, "", $NF); print $NF }' | sort -n | head -1)
    # An IDLE column that is not an integer would make the comparison below
    # false forever -- `rows` is non-empty, so the ten-second guard above never
    # trips either, and the whole thing becomes a twenty-minute wait ending in
    # a message about a filler that in fact finished. `cli list` prints `{d}s`
    # today; this is what notices if that ever changes.
    case "$idle" in
      '' | *[!0-9]*)
        echo "unexpected IDLE column '$idle' from $sock; cannot tell when it went idle" >&2
        exit 1
        ;;
    esac
    [ "$idle" -ge 2 ] && return 0
    sleep 0.5
  done
  # Not a warning. Attaching to a terminal that is still a firehose measures
  # the filler, so carrying on here prints a table of numbers that mean
  # something other than what its heading says.
  echo "terminals on $sock never went idle; refusing to measure" >&2
  exit 1
}
wait_idle "$full_sock"

# And that it is `live`: attaching to a parked terminal serves a compressed
# park file off disk instead of encoding, which is a different code path with
# different numbers and no hint in the table which one it timed.
residency=$(ILLOGICAL_SOCK="$full_sock" "$cli" list | awk 'NR > 1 { print $4 }' | sort -u)
[ "$residency" = "live" ] || {
  echo "refusing to measure: terminal is '$residency', not live" >&2
  exit 1
}
# An empty daemon for the local host in the bridged case, so the *front* tab
# is the remote terminal. The client attaches to whatever is in front.
start_daemon empty 0
empty_sock="$daemon_sock"

# A stand-in for ssh: ignores every option and runs the bridge against the
# daemon above, which is what `ssh <dest> illogicald --stdio` lands on.
cat >"$state/ssh" <<EOF
#!/bin/sh
exec $daemon --stdio --socket "$full_sock"
EOF
chmod +x "$state/ssh"

direct_ready="" direct_end="" bridged_ready="" bridged_end=""
for i in $(seq 1 "$runs"); do
  read -r r e < <(ILLOGICAL_SOCK="$full_sock" run "$state/direct-$i.log")
  direct_ready+="$r "
  direct_end+="$e "

  read -r r e < <(
    ILLOGICAL_SOCK="$empty_sock" \
    ILLOGICAL_SSH="$state/ssh" \
    ILLOGICAL_HOSTS="bench-host" \
      run "$state/bridged-$i.log"
  )
  bridged_ready+="$r "
  bridged_end+="$e "
done

printf '| %-9s | %14s | %13s |\n' "transport" "attach → ready" "attach → end"
printf '| %-9s | %14s | %13s |\n' "---" "---" "---"
printf '| %-9s | %11s ms | %10s ms |\n' \
  "direct" "$(echo "$direct_ready" | median)" "$(echo "$direct_end" | median)"
printf '| %-9s | %11s ms | %10s ms |\n' \
  "bridged" "$(echo "$bridged_ready" | median)" "$(echo "$bridged_end" | median)"
echo
echo "The attach-to-ready column is the gate: a splice that parses nothing"
echo "should not move it between the two rows. attach-to-end carries the whole"
echo "snapshot, and is where a per-frame cost in the bridge would show up."
