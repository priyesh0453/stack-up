# shellcheck shell=bash
# report.sh - the run log, the screen reporters, the history ledger and the verdict.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file
# Run-log line: "YYYY-MM-DD HH:MM:SS  TAG     message" (tag padded to 7).
# History row:  "YYYY-MM-DD HH:MM:SS<TAB>mode<TAB>outcome<TAB>detail".

[ -n "${_REPORT_SH_LOADED:-}" ] && return 0
_REPORT_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=util.sh
. "$_LIB_DIR/util.sh" || return 1
# shellcheck source=term.sh
. "$_LIB_DIR/term.sh" || return 1

REPORT_RUN_LOG=${REPORT_RUN_LOG-}
REPORT_HISTORY_FILE=${REPORT_HISTORY_FILE-}
REPORT_MODE=${REPORT_MODE:-run}
REPORT_VERSION=${REPORT_VERSION:-unknown}
REPORT_FAILURE_COUNT=0
REPORT_FAILURE_TAGS=""
REPORT_DEFECT_COUNT=0
REPORT_VERDICT_RECORDED=0
_REPORT_LOG_WARNED=0
_REPORT_HISTORY_WARNED=0
_REPORT_FLAT=""
REPORT_STAMP=""
_REPORT_NOW=""

# One record per line is what makes the log and the ledger greppable, so line
# breaks and tabs inside a message become spaces.
_report_flatten() {
  _REPORT_FLAT=$1
  _REPORT_FLAT=${_REPORT_FLAT//$'\n'/ }
  _REPORT_FLAT=${_REPORT_FLAT//$'\r'/ }
  _REPORT_FLAT=${_REPORT_FLAT//$'\t'/ }
}

# Each record otherwise costs one date process, so a caller that writes a burst
# may take the time once into REPORT_STAMP and clear it afterwards; a stale
# stamp is the caller's. A stamp of any other shape is ignored, which keeps the
# line format. REPORT_STAMP is reset at load, so the environment cannot set it.
_report_now() {
  if [ "${REPORT_STAMP//[0123456789]/9}" = "9999-99-99 99:99:99" ]; then
    _REPORT_NOW=$REPORT_STAMP
    return 0
  fi
  _REPORT_NOW=$(date '+%Y-%m-%d %H:%M:%S')
}

report_log() {
  local stamp
  if [ "$#" -ne 2 ] || [ -z "$1" ]; then
    return 2
  fi
  [ -n "$REPORT_RUN_LOG" ] || return 0
  _report_flatten "$2"
  _report_now
  stamp=$_REPORT_NOW
  if { printf '%s  %-7s %s\n' "$stamp" "$1" "$_REPORT_FLAT" >> "$REPORT_RUN_LOG"; } 2>/dev/null; then
    return 0
  fi
  if [ "$_REPORT_LOG_WARNED" = 0 ]; then
    _REPORT_LOG_WARNED=1
    printf 'report: cannot append to the run log %s\n' "$REPORT_RUN_LOG" >&2
  fi
  return 1
}

report_duration() {
  local total
  if [ "$#" -ne 1 ] || ! util_is_uint "$1"; then
    return 2
  fi
  total=$1
  if [ "$total" -lt 60 ]; then
    printf '%ss' "$total"
  elif [ "$total" -lt 3600 ]; then
    printf '%sm %ss' "$((total / 60))" "$((total % 60))"
  else
    printf '%sh %sm %ss' "$((total / 3600))" "$((total % 3600 / 60))" "$((total % 60))"
  fi
}

report_success() {
  [ "$#" -eq 1 ] || return 2
  printf '    %s+%s  %s\n' "$TERM_COLOR_SUCCESS" "$TERM_COLOR_RESET" "$1"
  report_log OK "$1"
  return 0
}

report_warning() {
  [ "$#" -eq 1 ] || return 2
  printf '    %s!%s  %s\n' "$TERM_COLOR_WARNING" "$TERM_COLOR_RESET" "$1"
  report_log WARN "$1"
  return 0
}

report_skipped() {
  [ "$#" -eq 1 ] || return 2
  printf '    %s-  %s%s\n' "$TERM_COLOR_MUTED" "$1" "$TERM_COLOR_RESET"
  report_log SKIP "$1"
  return 0
}

report_detail() {
  [ "$#" -eq 1 ] || return 2
  printf '    %s.  %s%s\n' "$TERM_COLOR_MUTED" "$1" "$TERM_COLOR_RESET"
  report_log INFO "$1"
  return 0
}

report_failure() {
  local tag
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    return 2
  fi
  printf '    %sx%s  %s\n' "$TERM_COLOR_FAILURE" "$TERM_COLOR_RESET" "$1"
  report_log FAIL "$1"
  REPORT_FAILURE_COUNT=$((REPORT_FAILURE_COUNT + 1))
  tag=${2:-}
  if [ -n "$tag" ]; then
    tag=${tag// /_}
    REPORT_FAILURE_TAGS=${REPORT_FAILURE_TAGS:+$REPORT_FAILURE_TAGS }$tag
  fi
  return 0
}

report_known_defect() {
  [ "$#" -eq 1 ] || return 2
  printf '    %s~%s  %s\n' "$TERM_COLOR_ACCENT" "$TERM_COLOR_RESET" "$1"
  report_log DEFECT "$1"
  REPORT_DEFECT_COUNT=$((REPORT_DEFECT_COUNT + 1))
  return 0
}

report_fault() {
  local evidence
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    return 2
  fi
  evidence=${3:-}
  printf '       %sWHO %s   %s\n' "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" "$1"
  printf '       %sWHAT%s   %s\n' "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" "$2"
  if [ -n "$evidence" ]; then
    printf '       %sLOG %s   %s\n' "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" "$evidence"
  fi
  report_log FAULT "$1 | $2 | ${evidence:-no log}"
  return 0
}

report_history() {
  local stamp outcome detail mode
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
    return 2
  fi
  [ -n "$REPORT_HISTORY_FILE" ] || return 0
  _report_flatten "$1"; outcome=$_REPORT_FLAT
  _report_flatten "${2:-}"; detail=$_REPORT_FLAT
  _report_flatten "$REPORT_MODE"; mode=$_REPORT_FLAT
  _report_now
  stamp=$_REPORT_NOW
  if { printf '%s\t%s\t%s\t%s\n' "$stamp" "$mode" "$outcome" "$detail" >> "$REPORT_HISTORY_FILE"; } 2>/dev/null; then
    return 0
  fi
  if [ "$_REPORT_HISTORY_WARNED" = 0 ]; then
    _REPORT_HISTORY_WARNED=1
    printf 'report: cannot append to the history file %s\n' "$REPORT_HISTORY_FILE" >&2
  fi
  return 1
}

# Never returns. A malformed call still ends the run, and never with status 0,
# because a verdict that cannot be read must not look like success.
report_verdict() {
  local outcome status detail
  outcome=${1:-}
  status=${2:-}
  detail=${3:-}
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || [ -z "$outcome" ]; then
    printf 'report_verdict: usage: OUTCOME EXIT [DETAIL]\n' >&2
    outcome=${outcome:-unknown}
    status=1
  fi
  if ! util_is_uint "$status" || [ "$status" -gt 255 ]; then
    printf 'report_verdict: exit status "%s" is not 0-255, recording 1\n' "$status" >&2
    status=1
  fi
  term_close_phase
  report_log VERDICT "$outcome exit=$status${detail:+ $detail}"
  report_history "$outcome" "exit=$status version=$REPORT_VERSION${detail:+ $detail}"
  REPORT_VERDICT_RECORDED=1
  exit "$status"
}
