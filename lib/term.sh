# shellcheck shell=bash
# term.sh - colour palette, banner and phase headings.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file

[ -n "${_TERM_SH_LOADED:-}" ] && return 0
_TERM_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=report.sh
. "$_LIB_DIR/report.sh" || return 1

TERM_PHASE_LABEL=${TERM_PHASE_LABEL:-startup}
TERM_PHASE_OPEN=0
TERM_PHASE_STARTED_AT=0

term_init_palette() {
  local mode=${1:-auto} use_colour=0
  [ "$#" -le 1 ] || return 2
  case $mode in
    always) use_colour=1 ;;
    never) use_colour=0 ;;
    auto)
      if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        use_colour=1
      fi
      ;;
    *) return 2 ;;
  esac
  if [ "$use_colour" -eq 1 ]; then
    TERM_COLOR_HEADING=$'\033[1;38;5;39m'
    TERM_COLOR_SUCCESS=$'\033[38;5;42m'
    TERM_COLOR_WARNING=$'\033[38;5;214m'
    TERM_COLOR_MUTED=$'\033[38;5;244m'
    TERM_COLOR_FAILURE=$'\033[38;5;203m'
    TERM_COLOR_ACCENT=$'\033[1;38;5;213m'
    TERM_COLOR_BOLD=$'\033[1m'
    TERM_COLOR_RESET=$'\033[0m'
  else
    TERM_COLOR_HEADING=""; TERM_COLOR_SUCCESS=""; TERM_COLOR_WARNING=""; TERM_COLOR_MUTED=""
    TERM_COLOR_FAILURE=""; TERM_COLOR_ACCENT=""; TERM_COLOR_BOLD=""; TERM_COLOR_RESET=""
  fi
  return 0
}

term_banner() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    return 2
  fi
  printf '\n  %s%s%s\n' "$TERM_COLOR_ACCENT" "$1" "$TERM_COLOR_RESET"
  if [ -n "${2:-}" ]; then
    printf '  %s%s%s\n' "$TERM_COLOR_MUTED" "$2" "$TERM_COLOR_RESET"
  fi
  if [ -n "$REPORT_RUN_LOG" ]; then
    printf '  %sRun log%s  %s\n' "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" "$REPORT_RUN_LOG"
  fi
  return 0
}

term_close_phase() {
  local elapsed
  [ "$TERM_PHASE_OPEN" = 1 ] || return 0
  elapsed=$(( $(date +%s) - TERM_PHASE_STARTED_AT ))
  [ "$elapsed" -ge 0 ] || elapsed=0
  TERM_PHASE_OPEN=0
  report_log PHASE "$TERM_PHASE_LABEL finished in $(report_duration "$elapsed")"
  return 0
}

term_phase_heading() {
  [ "$#" -eq 2 ] || return 2
  term_close_phase
  TERM_PHASE_LABEL=$2
  TERM_PHASE_STARTED_AT=$(date +%s)
  TERM_PHASE_OPEN=1
  printf '\n  %s%s  %s%s\n' "$TERM_COLOR_HEADING" "$1" "$2" "$TERM_COLOR_RESET"
  report_log PHASE "$2 started"
  return 0
}

term_section_heading() {
  [ "$#" -eq 1 ] || return 2
  printf '\n  %s%s%s\n' "$TERM_COLOR_HEADING" "$1" "$TERM_COLOR_RESET"
  report_log SECTION "$1"
  return 0
}

term_init_palette auto
