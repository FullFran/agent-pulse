#!/usr/bin/env bash
# agent-pulse test suite.
#
# Runs against a REAL throwaway tmux server on its own socket, because every
# interesting behaviour here (pane options, rollups, visibility) is tmux
# semantics. Mocking tmux would only test the mock.
#
#   usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="agent-pulse-tests-$$"
TM=(tmux -L "$SOCKET")

pass=0
fail=0

cleanup() { "${TM[@]}" kill-server 2>/dev/null; }
trap cleanup EXIT

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[32mPASS\033[0m  %-52s %s\n' "$label" "$actual"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-52s expected=%s got=%s\n' "$label" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

# agent-report insists on running inside tmux. Point it at the test server.
report() {
  local state="$1" msg="${2:-}" pane="$3"
  TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),$("${TM[@]}" display-message -p '#{pid}'),0" \
    "$ROOT/scripts/agent-report" "$state" "$msg" "$pane"
}
heal() {
  TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),$("${TM[@]}" display-message -p '#{pid}'),0" \
    "$ROOT/scripts/agent-heal"
}
pane_state() { "${TM[@]}" show-options -pqv -t "$1" @agent_state 2>/dev/null; }
win_state()  { "${TM[@]}" show-options -wqv -t "$1" @win_agent_state 2>/dev/null; }

# Sound would fire on every transition and make the suite audible.
export AGENT_PULSE_SOUND=0

"${TM[@]}" new-session -d -s t -n w1
P1="$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | head -1)"

echo "── canonical states ────────────────────────────────────────────────"
for st in working blocked error idle; do
  report "$st" "m-$st" "$P1"
  check "pane state: $st" "$st" "$(pane_state "$P1")"
done
report clear "" "$P1"
check "clear unsets pane state" "" "$(pane_state "$P1")"

echo
echo "── unknown input is ignored ────────────────────────────────────────"
report working "" "$P1"
report banana "" "$P1"
check "unknown state leaves value intact" "working" "$(pane_state "$P1")"

echo
echo "── monotonic sequence guard ────────────────────────────────────────"
report idle "" "$P1"
# A stale report must not win. Pretend a much newer one already landed.
"${TM[@]}" set-option -p -t "$P1" @agent_seq "$(( $(date +%s) + 3600 ))000000000"
report working "late" "$P1"
check "older event does not overwrite newer" "idle" "$(pane_state "$P1")"
"${TM[@]}" set-option -pu -t "$P1" @agent_seq
report working "" "$P1"
check "fresh event applies again" "working" "$(pane_state "$P1")"

echo
echo "── window rollup: worst pane wins, regardless of pane order ────────"
"${TM[@]}" split-window -d -t t:w1
P2="$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | tail -1)"

# The ordering here is the regression that motivated the rank table: tmux lists
# panes in creation order, so an early idle must not mask a later working.
report idle    "" "$P1"; report working "" "$P2"
check "idle + working" "working" "$(win_state t:w1)"

report working "" "$P1"; report blocked "" "$P2"
check "working + blocked" "blocked" "$(win_state t:w1)"

report blocked "" "$P1"; report error "" "$P2"
check "blocked + error" "error" "$(win_state t:w1)"

report idle "" "$P1"; report idle "" "$P2"
check "idle + idle" "idle" "$(win_state t:w1)"

echo
echo "── self-heal clears seen attention states ──────────────────────────"
report blocked "" "$P1"
check "blocked before heal" "blocked" "$(pane_state "$P1")"
# No client is attached to the test server, so nothing is "on screen" and the
# heal must be a no-op. This is the guard against clearing unseen alerts.
heal
check "unattended blocked survives heal" "blocked" "$(pane_state "$P1")"

echo
echo "── session rollup ──────────────────────────────────────────────────"
ses_state() { "${TM[@]}" show-options -qv -t "$1" @session_agent_state 2>/dev/null; }

report idle "" "$P1"; report idle "" "$P2"
check "all idle" "idle" "$(ses_state t)"
report blocked "" "$P2"
check "one blocked pane raises the session" "blocked" "$(ses_state t)"

# A second window must not mask a blocked one in the first.
"${TM[@]}" new-window -d -t t -n w2
P3="$("${TM[@]}" list-panes -t t:w2 -F '#{pane_id}' | head -1)"
report working "" "$P3"
check "second window does not lower it" "blocked" "$(ses_state t)"
report idle "" "$P2"
check "clearing the blocker lowers it" "working" "$(ses_state t)"

echo
echo "── agent-sessions listing ──────────────────────────────────────────"
sessions() {
  TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),$("${TM[@]}" display-message -p '#{pid}'),0" \
    "$ROOT/scripts/agent-sessions" "$@"
}
report blocked "" "$P2"
check "compact marks a blocked session" "●t" "$(sessions)"
check "only-attention includes it" "● t" "$(sessions --format marked --only-attention | tr -d '\n')"
report idle "" "$P2"; report idle "" "$P3"
check "only-attention drops calm sessions" "" "$(sessions --only-attention)"

echo
echo "── pane death cannot leak state ────────────────────────────────────"
report blocked "" "$P2"
"${TM[@]}" kill-pane -t "$P2" 2>/dev/null
report idle "" "$P1"
check "rollup ignores dead pane" "idle" "$(win_state t:w1)"

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
