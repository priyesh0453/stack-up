# shellcheck shell=bash
# util.sh - small text helpers shared by the other modules.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file

[ -n "${_UTIL_SH_LOADED:-}" ] && return 0
_UTIL_SH_LOADED=1

util_contains_word() {
  [ "$#" -eq 2 ] || return 2
  case $1 in
    ''|*' '*) return 1 ;;
  esac
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The C locale keeps the mapping to A-Z only: in a UTF-8 locale tr also folds
# non-ASCII letters, so the same answer could compare differently per machine.
util_to_lower() {
  [ "$#" -eq 1 ] || return 2
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

UTIL_TRIMMED=""
_UTIL_TAB=$'\t'

# The result goes to UTIL_TRIMMED instead of stdout: parsers call this once per
# line, and a command substitution per line would fork a subshell each time.
util_trim() {
  local text
  [ "$#" -eq 1 ] || return 2
  text=$1
  while :; do
    case $text in
      ' '*|"$_UTIL_TAB"*) text=${text#?} ;;
      *) break ;;
    esac
  done
  while :; do
    case $text in
      *' '|*"$_UTIL_TAB") text=${text%?} ;;
      *) break ;;
    esac
  done
  UTIL_TRIMMED=$text
  return 0
}

# Leading zeros are refused because bash arithmetic reads 010 as octal 8.
util_is_uint() {
  [ "$#" -eq 1 ] || return 2
  case $1 in
    0) return 0 ;;
    ''|0*|*[!0123456789]*) return 1 ;;
  esac
  [ "${#1}" -le 18 ]
}
