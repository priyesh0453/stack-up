# shellcheck shell=bash
# prompt.sh - consent, choices and timed questions that fail closed.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file
# Questions go to stderr; answers are read from PROMPT_TTY on file descriptor 8,
# which stays open between questions so a file of scripted answers is read one
# line per question. Every answer is written to the run log as an ASK record.

[ -n "${_PROMPT_SH_LOADED:-}" ] && return 0
_PROMPT_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=report.sh
. "$_LIB_DIR/report.sh" || return 1

# An exported value came from the environment, where any shell could have left
# it, so it may answer questions only in a test that sets PROMPT_TEST_SEAM=1.
# A tool's own value, set without export before or after sourcing, is kept.
_prompt_from_environment() {
  local attributes
  [ -n "${!1+set}" ] || return 1
  attributes=$(declare -p "$1" 2>/dev/null) || return 1
  attributes=${attributes#declare -}
  case ${attributes%% *} in
    *x*) return 0 ;;
  esac
  return 1
}
if [ "${PROMPT_TEST_SEAM-}" != 1 ]; then
  _prompt_from_environment PROMPT_TTY && unset PROMPT_TTY
  _prompt_from_environment PROMPT_INTERACTIVE && unset PROMPT_INTERACTIVE
fi
PROMPT_TTY=${PROMPT_TTY:-/dev/tty}
PROMPT_INTERACTIVE=${PROMPT_INTERACTIVE-}
PROMPT_ANSWER=""
PROMPT_OUTCOME=""
_PROMPT_FD_PATH=""

prompt_is_interactive() {
  case $PROMPT_INTERACTIVE in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -t 0 ] && [ -t 1 ]
}

# The trial open in a subshell keeps a failed open from ending the shell when
# bash runs in POSIX mode, where a failed exec redirection is fatal.
_prompt_open() {
  if [ -n "$_PROMPT_FD_PATH" ] && [ "$_PROMPT_FD_PATH" = "$PROMPT_TTY" ]; then
    return 0
  fi
  prompt_close
  ( exec 8<"$PROMPT_TTY" ) 2>/dev/null || return 1
  { exec 8<"$PROMPT_TTY"; } 2>/dev/null || return 1
  _PROMPT_FD_PATH=$PROMPT_TTY
  return 0
}

prompt_close() {
  if [ -n "$_PROMPT_FD_PATH" ]; then
    exec 8<&-
    _PROMPT_FD_PATH=""
  fi
  return 0
}

prompt_consent() {
  local question default hint answer
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
    printf 'prompt_consent: usage: QUESTION [yes|no]\n' >&2
    return 2
  fi
  question=$1
  default=$(util_to_lower "${2:-no}")
  case $default in
    yes|no) ;;
    *)
      printf 'prompt_consent: default must be yes or no, not "%s"\n' "$default" >&2
      return 2
      ;;
  esac
  PROMPT_ANSWER=no
  if ! prompt_is_interactive; then
    report_log ASK "$question (no terminal, so the answer is no)"
    return 1
  fi
  if [ "$default" = yes ]; then hint="Yes/no"; else hint="yes/No"; fi
  printf '    %s?%s  %s  %s[%s]%s ' "$TERM_COLOR_ACCENT" "$TERM_COLOR_RESET" "$question" "$TERM_COLOR_MUTED" "$hint" "$TERM_COLOR_RESET" >&2
  if ! _prompt_open || ! read -r answer <&8; then
    printf '\n' >&2
    report_log ASK "$question (no answer could be read, so the answer is no)"
    return 1
  fi
  answer=$(util_to_lower "$answer")
  [ -n "$answer" ] || answer=$default
  report_log ASK "$question answered: $answer"
  case $answer in
    y|yes)
      PROMPT_ANSWER=yes
      return 0
      ;;
  esac
  return 1
}

prompt_choice() {
  local question default choices answer attempt=0
  if [ "$#" -lt 3 ] || [ -z "$1" ]; then
    printf 'prompt_choice: usage: QUESTION DEFAULT CHOICE [CHOICE...]\n' >&2
    return 2
  fi
  question=$1
  default=$2
  shift 2
  choices="$*"
  if ! util_contains_word "$default" "$choices"; then
    printf 'prompt_choice: default "%s" is not one of: %s\n' "$default" "$choices" >&2
    return 2
  fi
  PROMPT_ANSWER=$default
  if ! prompt_is_interactive; then
    report_log ASK "$question (no terminal, so the default $default applies)"
    return 0
  fi
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    printf '    %s?%s  %s  %s[%s; default %s]%s ' "$TERM_COLOR_ACCENT" "$TERM_COLOR_RESET" "$question" "$TERM_COLOR_MUTED" "$choices" "$default" "$TERM_COLOR_RESET" >&2
    if ! _prompt_open || ! read -r answer <&8; then
      printf '\n' >&2
      report_log ASK "$question (no answer could be read, so the default $default applies)"
      return 0
    fi
    answer=$(util_to_lower "$answer")
    [ -n "$answer" ] || answer=$default
    if util_contains_word "$answer" "$choices"; then
      PROMPT_ANSWER=$answer
      report_log ASK "$question answered: $answer"
      return 0
    fi
    printf '    %s!%s  "%s" is not one of: %s\n' "$TERM_COLOR_WARNING" "$TERM_COLOR_RESET" "$answer" "$choices" >&2
  done
  report_log ASK "$question (3 answers did not match, so the default $default applies)"
  return 0
}

# Free text is kept as typed, not lowercased. Status 1 means nothing could be
# read, so a caller that validates the answer and asks again can stop asking.
prompt_text() {
  local question default hint answer
  if [ "$#" -ne 2 ] || [ -z "$1" ]; then
    printf 'prompt_text: usage: QUESTION DEFAULT\n' >&2
    return 2
  fi
  question=$1
  default=$2
  PROMPT_ANSWER=$default
  if ! prompt_is_interactive; then
    report_log ASK "$question (no terminal, so the default \"$default\" applies)"
    return 1
  fi
  if [ -n "$default" ]; then hint="default $default"; else hint="blank for none"; fi
  printf '    %s?%s  %s  %s[%s]%s ' "$TERM_COLOR_ACCENT" "$TERM_COLOR_RESET" "$question" "$TERM_COLOR_MUTED" "$hint" "$TERM_COLOR_RESET" >&2
  if ! _prompt_open || ! read -r answer <&8; then
    printf '\n' >&2
    report_log ASK "$question (no answer could be read, so the default \"$default\" applies)"
    return 1
  fi
  [ -n "$answer" ] || answer=$default
  PROMPT_ANSWER=$answer
  report_log ASK "$question answered: \"$answer\""
  return 0
}

# The wall-clock check after the read catches an answer typed after a sleep:
# the read timer can outlast the window it was meant to bound.
prompt_timed() {
  local question seconds answer started elapsed
  if [ "$#" -ne 2 ] || [ -z "$1" ] || ! util_is_uint "$2" || [ "$2" -eq 0 ]; then
    printf 'prompt_timed: usage: QUESTION SECONDS\n' >&2
    return 2
  fi
  question=$1
  seconds=$2
  PROMPT_ANSWER=no
  if ! prompt_is_interactive; then
    PROMPT_OUTCOME=no-terminal
    report_log ASK "$question (no terminal, so the answer is no)"
    return 1
  fi
  started=$(date +%s)
  printf '    %s?%s  %s  %s[yes/No]%s ' "$TERM_COLOR_ACCENT" "$TERM_COLOR_RESET" "$question" "$TERM_COLOR_MUTED" "$TERM_COLOR_RESET" >&2
  if ! _prompt_open || ! read -r -t "$seconds" answer <&8; then
    printf '\n' >&2
    PROMPT_OUTCOME=no-answer
    report_log ASK "$question (no answer within $seconds seconds, so the answer is no)"
    return 1
  fi
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -gt "$seconds" ]; then
    PROMPT_OUTCOME=late
    report_log ASK "$question (answered after the $seconds second window closed, so the answer is no)"
    return 1
  fi
  answer=$(util_to_lower "$answer")
  case $answer in
    y|yes)
      PROMPT_ANSWER=yes
      PROMPT_OUTCOME=yes
      report_log ASK "$question answered: yes"
      return 0
      ;;
  esac
  PROMPT_OUTCOME=declined
  report_log ASK "$question answered: ${answer:-nothing}, so the answer is no"
  return 1
}
