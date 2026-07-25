# shellcheck shell=bash
# agent-pulse — shared helpers.
#
# Sourced by agent-report and agent-heal. The window rollup lives here because
# both need it and a second copy would inevitably drift out of sync.

# Urgency ranking. Higher wins. Anything unrecognised ranks 0 and is ignored.
#
#   error   an agent failed and you have to look
#   blocked an agent is waiting on you right now
#   working an agent is busy, nothing required of you
#   idle    an agent finished
ap_rank() {
  case "$1" in
    error)   printf '4' ;;
    blocked) printf '3' ;;
    working) printf '2' ;;
    idle)    printf '1' ;;
    *)       printf '0' ;;
  esac
}

# Recompute @win_agent_state for a window as the worst state across its panes.
#
# Ranking by value rather than by arrival order matters: tmux lists panes in
# creation order, so an early "idle" pane must not mask a later "blocked" one.
ap_recompute_rollup() {
  local win="$1" best=0 best_state="" s r
  [ -n "$win" ] || return 0

  while read -r s; do
    r=$(ap_rank "$s")
    if [ "$r" -gt "$best" ]; then
      best="$r"
      best_state="$s"
    fi
  done < <(tmux list-panes -t "$win" -F '#{@agent_state}' 2>/dev/null)

  if [ -n "$best_state" ]; then
    tmux set-option -w -t "$win" @win_agent_state "$best_state" 2>/dev/null
  else
    tmux set-option -wu -t "$win" @win_agent_state 2>/dev/null
  fi
}

# Recompute @session_agent_state for a session as the worst state across its
# windows.
#
# This is what makes a many-session workflow legible: the tab bar answers "which
# window in THIS session needs me", and the session rollup answers "which of my
# ten sessions needs me at all" — which is the question you actually have when
# the session is not on screen.
ap_recompute_session() {
  local ses="$1" best=0 best_state="" s r
  [ -n "$ses" ] || return 0

  while read -r s; do
    r=$(ap_rank "$s")
    if [ "$r" -gt "$best" ]; then
      best="$r"
      best_state="$s"
    fi
  done < <(tmux list-windows -t "$ses" -F '#{@win_agent_state}' 2>/dev/null)

  if [ -n "$best_state" ]; then
    tmux set-option -t "$ses" @session_agent_state "$best_state" 2>/dev/null
  else
    tmux set-option -ut "$ses" @session_agent_state 2>/dev/null
  fi
}

# True when `candidate` is strictly older than what the pane already recorded.
#
# Values come from `date +%s%N`, so they are 19-digit decimals. Bash arithmetic
# is int64 and would overflow on a longer or malformed value, which is why this
# validates both sides and fails OPEN: a report we cannot order is better
# delivered late than silently dropped.
ap_seq_is_stale() {
  local candidate="$1" recorded="$2"
  [ -n "$recorded" ] || return 1
  case "$candidate" in ''|*[!0-9]*) return 1 ;; esac
  case "$recorded"  in ''|*[!0-9]*) return 1 ;; esac
  [ "${#candidate}" -le 18 ] || [ "${#recorded}" -le 18 ] || {
    # Both are 19+ digits: compare as strings of equal length, else by length.
    if [ "${#candidate}" -ne "${#recorded}" ]; then
      [ "${#candidate}" -lt "${#recorded}" ] && return 0 || return 1
    fi
    [[ "$candidate" < "$recorded" ]] && return 0 || return 1
  }
  [ "$candidate" -lt "$recorded" ]
}
