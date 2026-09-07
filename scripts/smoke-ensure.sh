#!/usr/bin/env bash
# Prove that a daemon started by `illogicald --ensure` outlives whatever
# started it.
#
# This is G1 at the level the unit tests cannot reach. `stdio.zig` already
# tests that `spawnDetached`'s grandchild survives its parent's exit and
# inherits no descriptors, but "exit" is the polite case. What the Mac app
# actually does to the process that ran `--ensure` is ⌘Q, a crash, or Xcode's
# Stop button -- and Stop kills the debuggee's whole *process group*. So the
# thing worth asserting is the one the tests cannot: put the starter in a
# process group of its own, SIGKILL that entire group, and see whether the
# daemon is still answering.
#
# It survives because `spawnDetached` calls `setsid()` in the intermediate
# child, so the daemon is in a session and a process group of its own, with no
# controlling terminal to send it SIGHUP and no descriptor tying it to anyone.
# The assertions below check both halves: that the group really was different,
# and that the daemon really did survive the kill.
#
# Usage: scripts/smoke-ensure.sh   (or `just smoke-ensure`, which builds first)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
daemon="$root/zig-out/bin/illogicald"
cli="$root/zig-out/bin/illogical"

[ -x "$daemon" ] || { echo "build first: zig build" >&2; exit 1; }
[ -x "$cli" ] || { echo "build first: zig build" >&2; exit 1; }

state="$(mktemp -d /tmp/illogical-ensure.XXXXXX)"
sock="$state/server.sock"

cleanup() {
  # The daemon is nobody's child, so there is no pid to have kept: find it by
  # the socket path, which is unique to this run. It holds no terminals, so it
  # is not wedged in a PTY read and a plain TERM is enough -- unlike
  # bench-launch.sh, which has to close the other end instead.
  pkill -f -- "--socket $sock" 2>/dev/null || true
  sleep 0.2
  pkill -9 -f -- "--socket $sock" 2>/dev/null || true
  rm -rf "$state"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. start one, from a process group we are about to destroy -------------

# `set -m` gives the background job a process group of its own, with the pgid
# equal to the job's pid. Without it the job stays in this script's group and
# the kill below would take the script with it.
set -m
{ "$daemon" --ensure --socket "$sock" >"$state/ensure-1.out" 2>"$state/ensure-1.err"; } &
starter=$!
set +m

status=0
wait "$starter" || status=$?
[ "$status" -eq 0 ] || fail "--ensure exited $status: $(cat "$state/ensure-1.err")"
grep -q "started, listening on $sock" "$state/ensure-1.out" ||
  fail "expected 'started, listening on', got: $(cat "$state/ensure-1.out")"

# --- 2. the daemon is not in that group -------------------------------------

daemon_pid="$(pgrep -f -- "--socket $sock" | head -1)"
[ -n "$daemon_pid" ] || fail "no daemon process after --ensure"
daemon_pgid="$(ps -o pgid= -p "$daemon_pid" | tr -d ' ')"
[ "$daemon_pgid" != "$starter" ] ||
  fail "daemon is in the starter's process group ($daemon_pgid) -- setsid did not happen"
printf 'daemon pid %s, pgid %s, ppid %s (starter pgid was %s)\n' \
  "$daemon_pid" "$daemon_pgid" "$(ps -o ppid= -p "$daemon_pid" | tr -d ' ')" "$starter"

# --- 3. destroy the starter's group, and check the daemon is still there -----

# SIGKILL to the whole group, the way Xcode's Stop button ends a debug session.
# The starter has already exited, so this is a no-op unless something it left
# behind is still in there -- which is exactly what must not be true.
kill -9 -- "-$starter" 2>/dev/null || true
sleep 0.5

kill -0 "$daemon_pid" 2>/dev/null || fail "the daemon died with its starter's process group"
"$cli" --socket "$sock" list >"$state/list.out" 2>&1 ||
  fail "the daemon is not answering: $(cat "$state/list.out")"

# --- 4. a second --ensure leaves it alone ------------------------------------

# The one that matters for correctness: a second call must never start a second
# daemon, because the daemon that owns the socket owns every terminal behind it
# (D3.1). `Server.listen`'s probe is the backstop; this is the common path.
"$daemon" --ensure --socket "$sock" >"$state/ensure-2.out" 2>&1 ||
  fail "the second --ensure failed: $(cat "$state/ensure-2.out")"
grep -q "already running on $sock" "$state/ensure-2.out" ||
  fail "expected 'already running', got: $(cat "$state/ensure-2.out")"
[ "$(pgrep -f -- "--socket $sock" | wc -l | tr -d ' ')" = "1" ] ||
  fail "more than one daemon on $sock"

# --- 5. --no-spawn still refuses ---------------------------------------------

if "$daemon" --ensure --no-spawn --socket "$state/absent.sock" >/dev/null 2>&1; then
  fail "--ensure --no-spawn succeeded against a socket nothing is listening on"
fi

# --- 6. and it refuses in one sentence ---------------------------------------

# This text is not only for whoever ran the command: the Mac app quotes the last
# line of it verbatim into "No server". Before this, stderr was `std.log.err`'s
# `error: ` prefix, then `error: NoServer`, then a three-frame Zig return trace
# naming absolute paths inside src/daemon (REVIEW F4) — all of it in front of a
# person who wanted to know why their terminals were not there. So the assertion
# is on the shape of the whole of stderr, not only on what it says.
status=0
"$daemon" --ensure --no-spawn --socket "$state/absent.sock" \
  >"$state/refuse.out" 2>"$state/refuse.err" || status=$?
[ "$status" -eq 1 ] || fail "--ensure --no-spawn exited $status, expected 1"

lines="$(grep -c . "$state/refuse.err" | tr -d ' ')"
[ "$lines" = "1" ] ||
  fail "expected one line on stderr, got $lines: $(cat "$state/refuse.err")"
grep -q "^illogicald --ensure: nothing is listening on " "$state/refuse.err" ||
  fail "unexpected refusal: $(cat "$state/refuse.err")"
# Each of these was in the sentence the app used to show a person.
! grep -q "error:" "$state/refuse.err" || fail "stderr still carries a log prefix"
! grep -q "\.zig:" "$state/refuse.err" || fail "stderr still carries a Zig return trace"
! grep -q "info(" "$state/refuse.err" || fail "stderr still carries a progress line"

echo "OK: --ensure starts a daemon that survives its starter, starts no second one, and refuses in one line"
