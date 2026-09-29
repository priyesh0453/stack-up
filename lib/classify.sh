# shellcheck shell=bash
# classify.sh - maps a failed process's log to an owner and a plain explanation.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file
# Signatures are tried in the order they were added and the first match wins.
# A signature with a second pattern needs both to match somewhere in the log.

[ -n "${_CLASSIFY_SH_LOADED:-}" ] && return 0
_CLASSIFY_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=util.sh
. "$_LIB_DIR/util.sh" || return 1

CLASSIFY_EMPTY_OWNER=${CLASSIFY_EMPTY_OWNER:-this-machine}
CLASSIFY_EMPTY_EXPLAIN=${CLASSIFY_EMPTY_EXPLAIN:-the log is empty or missing, so the process stopped before it wrote anything}
CLASSIFY_FALLBACK_OWNER=${CLASSIFY_FALLBACK_OWNER:-needs-a-look}
CLASSIFY_FALLBACK_EXPLAIN=${CLASSIFY_FALLBACK_EXPLAIN:-no known signature matched; read the last lines of the log}
CLASSIFY_ID=""
CLASSIFY_OWNER=""
CLASSIFY_EXPLAIN=""
_CLASSIFY_IDS=()
_CLASSIFY_OWNERS=()
_CLASSIFY_EXPLAINS=()
_CLASSIFY_MATCHES=()
_CLASSIFY_ALSOS=()
_CLASSIFY_APPLIES=()
_CLASSIFY_IGNORES=()
_CLASSIFY_ID_CHARS=abcdefghijklmnopqrstuvwxyz0123456789._-

_classify_ere_ok() {
  [ -n "$1" ] || return 1
  LC_ALL=C grep -E -e "$1" </dev/null >/dev/null 2>&1
  [ "$?" -ne 2 ]
}

_classify_id_ok() {
  case $1 in
    ''|[!abcdefghijklmnopqrstuvwxyz0123456789]*|*[!$_CLASSIFY_ID_CHARS]*) return 1 ;;
  esac
  return 0
}

_classify_result() {
  CLASSIFY_ID=$1
  CLASSIFY_OWNER=$2
  CLASSIFY_EXPLAIN=$3
  printf '%s|%s|%s\n' "$1" "$2" "$3"
}

classify_reset() {
  _CLASSIFY_IDS=(); _CLASSIFY_OWNERS=(); _CLASSIFY_EXPLAINS=()
  _CLASSIFY_MATCHES=(); _CLASSIFY_ALSOS=(); _CLASSIFY_APPLIES=(); _CLASSIFY_IGNORES=()
  CLASSIFY_ID=""; CLASSIFY_OWNER=""; CLASSIFY_EXPLAIN=""
  return 0
}

classify_add() {
  local id owner explain match also applies i=0 n
  if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    return 2
  fi
  id=$1
  owner=$2
  explain=$3
  match=$4
  also=${5:-}
  applies=${6:-}
  _classify_id_ok "$id" || return 2
  _classify_id_ok "$owner" || return 2
  [ -n "$explain" ] || return 2
  _classify_ere_ok "$match" || return 2
  if [ -n "$also" ]; then
    _classify_ere_ok "$also" || return 2
  fi
  while [ "$i" -lt "${#_CLASSIFY_IDS[@]}" ]; do
    [ "${_CLASSIFY_IDS[$i]}" != "$id" ] || return 2
    i=$((i + 1))
  done
  n=${#_CLASSIFY_IDS[@]}
  _CLASSIFY_IDS[n]=$id
  _CLASSIFY_OWNERS[n]=$owner
  _CLASSIFY_EXPLAINS[n]=$explain
  _CLASSIFY_MATCHES[n]=$match
  _CLASSIFY_ALSOS[n]=$also
  _CLASSIFY_APPLIES[n]=$applies
  return 0
}

classify_ignore() {
  [ "$#" -eq 1 ] || return 2
  _classify_ere_ok "$1" || return 2
  _CLASSIFY_IGNORES[${#_CLASSIFY_IGNORES[@]}]=$1
  return 0
}

# grep runs in the C locale because in a UTF-8 locale one invalid byte makes
# it report "no match" for the whole log. It reads all of its input (no -q),
# so a pipe under pipefail cannot turn an early exit into a SIGPIPE status.
classify_log() {
  local log kind text i=0 args
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
    return 2
  fi
  log=$1
  kind=${2:-}
  if [ ! -s "$log" ] || [ ! -r "$log" ]; then
    _classify_result empty-log "$CLASSIFY_EMPTY_OWNER" "$CLASSIFY_EMPTY_EXPLAIN"
    return 1
  fi
  if [ "${#_CLASSIFY_IGNORES[@]}" -gt 0 ]; then
    args=()
    while [ "$i" -lt "${#_CLASSIFY_IGNORES[@]}" ]; do
      args[${#args[@]}]=-e
      args[${#args[@]}]=${_CLASSIFY_IGNORES[$i]}
      i=$((i + 1))
    done
    text=$(LC_ALL=C grep -v -E "${args[@]}" -- "$log")
  else
    text=$(cat -- "$log")
  fi
  i=0
  while [ "$i" -lt "${#_CLASSIFY_IDS[@]}" ]; do
    if [ -n "$kind" ] && [ -n "${_CLASSIFY_APPLIES[$i]}" ] && ! util_contains_word "$kind" "${_CLASSIFY_APPLIES[$i]}"; then
      i=$((i + 1))
      continue
    fi
    if printf '%s\n' "$text" | LC_ALL=C grep -E -e "${_CLASSIFY_MATCHES[$i]}" >/dev/null 2>&1; then
      if [ -z "${_CLASSIFY_ALSOS[$i]}" ] || printf '%s\n' "$text" | LC_ALL=C grep -E -e "${_CLASSIFY_ALSOS[$i]}" >/dev/null 2>&1; then
        _classify_result "${_CLASSIFY_IDS[$i]}" "${_CLASSIFY_OWNERS[$i]}" "${_CLASSIFY_EXPLAINS[$i]}"
        return 0
      fi
    fi
    i=$((i + 1))
  done
  _classify_result no-match "$CLASSIFY_FALLBACK_OWNER" "$CLASSIFY_FALLBACK_EXPLAIN"
  return 1
}
