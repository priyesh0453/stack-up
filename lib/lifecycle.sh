# shellcheck shell=bash
# lifecycle.sh - signal and exit traps, abort, the run lock, keep-awake and deadlines.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# Reserves file descriptor 9 for the run lock.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file

[ -n "${_LIFECYCLE_SH_LOADED:-}" ] && return 0
_LIFECYCLE_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=report.sh
. "$_LIB_DIR/report.sh" || return 1

LIFECYCLE_INTERRUPT_HINT=${LIFECYCLE_INTERRUPT_HINT-}
LIFECYCLE_ABORT_HOOK=${LIFECYCLE_ABORT_HOOK-}
LIFECYCLE_KILL_GRACE=${LIFECYCLE_KILL_GRACE:-5}
LIFECYCLE_POLL_INTERVAL=${LIFECYCLE_POLL_INTERVAL:-0.2}
LIFECYCLE_LOCK_FILE=""
LIFECYCLE_AWAKE_PID=""
LIFECYCLE_DEADLINE_PGID=""
_LIFECYCLE_MAIN_PID=""
_LIFECYCLE_ABORTING=0

# A child forked by this shell runs these traps too if a signal lands between
# its fork and its exec. $$ cannot tell the two apart and bash 3.2 has no
# BASHPID, so the real pid comes from a process whose parent is this one.
_lifecycle_in_child() {
  local self
  [ -n "$_LIFECYCLE_MAIN_PID" ] || return 1
  self=$(exec sh -c 'printf "%s\n" "$PPID"')
  [ -n "$self" ] && [ "$self" != "$_LIFECYCLE_MAIN_PID" ]
}

_lifecycle_stop_group() {
  local pgid=$1 started
  kill -TERM -- "-$pgid" 2>/dev/null || return 0
  started=$SECONDS
  while kill -0 -- "-$pgid" 2>/dev/null && [ $((SECONDS - started)) -lt "$LIFECYCLE_KILL_GRACE" ]; do
    sleep "$LIFECYCLE_POLL_INTERVAL" 2>/dev/null || sleep 1
  done
  # KILL goes only to a group that is still there after the grace period;
  # one that ended during it needs none.
  if kill -0 -- "-$pgid" 2>/dev/null; then
    kill -KILL -- "-$pgid" 2>/dev/null
  fi
  return 0
}

_lifecycle_on_signal() {
  local name=$1 status=$2
  trap '' INT TERM HUP
  if _lifecycle_in_child; then
    trap - EXIT
    exit "$status"
  fi
  printf '\n\n  %sINTERRUPTED%s  during %s\n' "$TERM_COLOR_WARNING" "$TERM_COLOR_RESET" "$TERM_PHASE_LABEL"
  if [ -n "$LIFECYCLE_INTERRUPT_HINT" ]; then
    printf '  %s%s%s\n' "$TERM_COLOR_MUTED" "$LIFECYCLE_INTERRUPT_HINT" "$TERM_COLOR_RESET"
  fi
  printf '\n'
  report_log ABORT "Interrupted by $name during $TERM_PHASE_LABEL"
  report_verdict interrupted "$status" "signal=$name during $TERM_PHASE_LABEL"
}

_lifecycle_on_exit() {
  local status=${1:-1}
  if _lifecycle_in_child; then
    exit "$status"
  fi
  trap '' INT TERM HUP
  # bash reaps a finished command on its own, before lifecycle_run_with_deadline
  # clears the variable, and a reaped leader's group id is free for reuse. A
  # leader that is gone means the command is over, so its id is not signalled.
  if [ -n "$LIFECYCLE_DEADLINE_PGID" ] && kill -0 "$LIFECYCLE_DEADLINE_PGID" 2>/dev/null; then
    _lifecycle_stop_group "$LIFECYCLE_DEADLINE_PGID"
  fi
  LIFECYCLE_DEADLINE_PGID=""
  lifecycle_release_awake
  if [ "$REPORT_VERDICT_RECORDED" != 1 ]; then
    report_log FAILED "the run ended with status $status before it recorded a verdict"
    [ "$status" -ne 0 ] || status=1
    trap - EXIT
    report_verdict failed "$status" "no verdict was recorded"
  fi
  exit "$status"
}

lifecycle_install_traps() {
  _LIFECYCLE_MAIN_PID=$(exec sh -c 'printf "%s\n" "$PPID"')
  trap '_lifecycle_on_signal INT 130' INT
  trap '_lifecycle_on_signal TERM 143' TERM
  trap '_lifecycle_on_signal HUP 129' HUP
  trap '_lifecycle_on_exit "$?"' EXIT
  return 0
}

lifecycle_abort() {
  local message="$*"
  [ -n "$message" ] || message="stopped without a stated reason"
  if [ "$_LIFECYCLE_ABORTING" = 1 ]; then
    report_verdict stopped 1 "$message"
  fi
  _LIFECYCLE_ABORTING=1
  printf '\n  %sSTOPPED%s  %s\n' "$TERM_COLOR_FAILURE" "$TERM_COLOR_RESET" "$message"
  if [ -n "$REPORT_RUN_LOG" ]; then
    printf '  %sRun log%s  %s\n' "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" "$REPORT_RUN_LOG"
  fi
  printf '\n'
  report_log FAILED "$message"
  if [ -n "$LIFECYCLE_ABORT_HOOK" ] && declare -F "$LIFECYCLE_ABORT_HOOK" >/dev/null 2>&1; then
    "$LIFECYCLE_ABORT_HOOK" "$message"
  fi
  report_verdict stopped 1 "$message"
}

# Status 75 is EX_TEMPFAIL, the lock tool's "held by another process". Any
# other failure aborts, because running on without the lock is the unsafe way
# to fail.
lifecycle_take_lock() {
  local file status
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    return 2
  fi
  file=$1
  if ! { exec 9>>"$file"; } 2>/dev/null; then
    lifecycle_abort "cannot open the run lock $file"
  fi
  if command -v lockf >/dev/null 2>&1; then
    lockf -s -t 0 9
    status=$?
  elif command -v flock >/dev/null 2>&1; then
    flock -n -E 75 9
    status=$?
  else
    exec 9>&-
    lifecycle_abort "cannot take the run lock $file: neither lockf nor flock is on PATH"
  fi
  case $status in
    0)
      LIFECYCLE_LOCK_FILE=$file
      return 0
      ;;
    75)
      exec 9>&-
      return 75
      ;;
  esac
  exec 9>&-
  lifecycle_abort "cannot take the run lock $file (the lock tool exited $status)"
}

lifecycle_release_lock() {
  [ -n "$LIFECYCLE_LOCK_FILE" ] || return 0
  exec 9>&-
  LIFECYCLE_LOCK_FILE=""
  return 0
}

# Call it from the main shell, never from a subshell, a pipeline or a command
# substitution: lifecycle_release_awake looks for the helper among the
# children of $$, and $$ names the main shell even inside a subshell.
lifecycle_keep_awake() {
  [ -z "$LIFECYCLE_AWAKE_PID" ] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 1
  caffeinate -i -w "$$" </dev/null >/dev/null 2>&1 8<&- 9>&- &
  LIFECYCLE_AWAKE_PID=$!
  return 0
}

lifecycle_release_awake() {
  local pid=$LIFECYCLE_AWAKE_PID
  [ -n "$pid" ] || return 0
  LIFECYCLE_AWAKE_PID=""
  # A caffeinate that already exited was reaped, and its PID may now belong
  # to another program, even another child of this shell. No grep -q: under
  # pipefail an early exit could turn into a SIGPIPE status.
  pgrep -P "$$" -x caffeinate 2>/dev/null | LC_ALL=C grep -x -e "$pid" >/dev/null || return 0
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

# The command runs in its own process group (set -m), so the deadline can stop
# everything it started, and stdin is /dev/null because a background group
# that reads the terminal is stopped by the kernel instead of timing out.
# Redirect inside COMMAND (for example a wrapper that runs `exec >>LOG 2>&1`
# before the real command), never around the call: a signal trap runs with the
# caller's redirections, so the interrupt banner would land in the log.
lifecycle_run_with_deadline() {
  local seconds pid status started timed_out=0 monitor_was_on=0
  if [ "$#" -lt 2 ] || ! util_is_uint "$1" || [ "$1" -eq 0 ]; then
    printf 'lifecycle_run_with_deadline: usage: SECONDS COMMAND [ARGS...]\n' >&2
    return 2
  fi
  seconds=$1
  shift
  case $- in
    *m*) monitor_was_on=1 ;;
  esac
  set -m
  "$@" </dev/null 8<&- 9>&- &
  pid=$!
  [ "$monitor_was_on" = 1 ] || set +m
  LIFECYCLE_DEADLINE_PGID=$pid
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -gt "$seconds" ]; then
      timed_out=1
      _lifecycle_stop_group "$pid"
      break
    fi
    sleep "$LIFECYCLE_POLL_INTERVAL" 2>/dev/null || sleep 1
  done
  wait "$pid" 2>/dev/null
  status=$?
  LIFECYCLE_DEADLINE_PGID=""
  if [ "$timed_out" = 1 ]; then
    return 124
  fi
  return "$status"
}
