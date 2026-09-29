# shellcheck shell=bash
# gate.sh - static checks over shell source: a normalized denylist and
# assertions about where a line sits inside a function.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
#
# Rules file (one rule per line; blank lines and # lines are ignored):
#   deny  ID  EXTENDED-REGEX     a normalized line matching it is a hit
#   allow ID  EXTENDED-REGEX     a hit for rule ID matching this is not a hit
# The pattern is the rest of the line, so it may contain spaces, | and =.
#
# Function ranges follow the column-0 convention: "name() {" starts at column 0
# and the first later line that is exactly "}" ends it, or the whole function is
# one line ending in "; }".

[ -n "${_GATE_SH_LOADED:-}" ] && return 0
_GATE_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=util.sh
. "$_LIB_DIR/util.sh" || return 1

GATE_HIT_COUNT=0
_GATE_DENY_IDS=()
_GATE_DENY_PATTERNS=()
_GATE_ALLOW_IDS=()
_GATE_ALLOW_PATTERNS=()
_GATE_COUNT=0
_GATE_START=0
_GATE_STOP=0
_GATE_WHY=""
_GATE_NL=$'\n'
_GATE_TAB=$'\t'

# Absolute tool paths and shell keywords in command position are removed so a
# rule anchored on command position also sees "/bin/rm", "if rm" and
# "command rm". Whole-line comments become blank lines, keeping line numbers.
gate_normalize() {
  LC_ALL=C sed -E \
    -e 's/^[[:space:]]*#.*$//' \
    -e 's#(^|[[:space:];&|(`])/(usr/)?s?bin/#\1#g' \
    -e ':k' \
    -e 's/(^|[;&|(`]|\$\()([[:space:]]*)(if|then|elif|else|do|while|until|!|command|exec|time)[[:space:]]+/\1\2/' \
    -e 'tk'
}

_gate_ere_ok() {
  [ -n "$1" ] || return 1
  LC_ALL=C grep -E -e "$1" </dev/null >/dev/null 2>&1
  [ "$?" -ne 2 ]
}

_gate_rules_error() {
  printf 'gate: %s:%s: %s\n' "$1" "$2" "$3" >&2
  return 2
}

_gate_load_rules() {
  local file=$1 raw line number=0 directive rest id pattern i known
  _GATE_DENY_IDS=(); _GATE_DENY_PATTERNS=(); _GATE_ALLOW_IDS=(); _GATE_ALLOW_PATTERNS=()
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'gate: cannot read the rules file %s\n' "$file" >&2
    return 2
  fi
  while IFS= read -r raw || [ -n "$raw" ]; do
    number=$((number + 1))
    raw=${raw%$'\r'}
    util_trim "$raw"
    line=$UTIL_TRIMMED
    case $line in
      ''|'#'*) continue ;;
    esac
    directive=${line%%[ $_GATE_TAB]*}
    util_trim "${line#"$directive"}"
    rest=$UTIL_TRIMMED
    id=${rest%%[ $_GATE_TAB]*}
    util_trim "${rest#"$id"}"
    pattern=$UTIL_TRIMMED
    case $directive in
      deny|allow) ;;
      *) _gate_rules_error "$file" "$number" "unknown directive \"$directive\"; use deny or allow"; return 2 ;;
    esac
    case $id in
      ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
        _gate_rules_error "$file" "$number" "bad rule id \"$id\""
        return 2
        ;;
    esac
    if [ -z "$pattern" ]; then
      _gate_rules_error "$file" "$number" "rule $id has no pattern"
      return 2
    fi
    if ! _gate_ere_ok "$pattern"; then
      _gate_rules_error "$file" "$number" "rule $id: not a valid extended regular expression"
      return 2
    fi
    known=0
    i=0
    while [ "$i" -lt "${#_GATE_DENY_IDS[@]}" ]; do
      [ "${_GATE_DENY_IDS[$i]}" != "$id" ] || known=1
      i=$((i + 1))
    done
    if [ "$directive" = deny ]; then
      if [ "$known" = 1 ]; then
        _gate_rules_error "$file" "$number" "rule $id is denied twice"
        return 2
      fi
      _GATE_DENY_IDS[${#_GATE_DENY_IDS[@]}]=$id
      _GATE_DENY_PATTERNS[${#_GATE_DENY_PATTERNS[@]}]=$pattern
    else
      if [ "$known" = 0 ]; then
        _gate_rules_error "$file" "$number" "allow for rule $id comes before any deny $id"
        return 2
      fi
      _GATE_ALLOW_IDS[${#_GATE_ALLOW_IDS[@]}]=$id
      _GATE_ALLOW_PATTERNS[${#_GATE_ALLOW_PATTERNS[@]}]=$pattern
    fi
  done < "$file"
  if [ "${#_GATE_DENY_IDS[@]}" -eq 0 ]; then
    printf 'gate: %s: no deny rules, so the gate would pass anything\n' "$file" >&2
    return 2
  fi
  return 0
}

# grep reads all of its input here (no -q), so a pipe under pipefail cannot
# turn an early exit into a SIGPIPE status.
_gate_scan() {
  local label=$1 text=$2 normalized r=0 a hits rest hit number content allowed original
  normalized=$(printf '%s\n' "$text" | gate_normalize)
  while [ "$r" -lt "${#_GATE_DENY_IDS[@]}" ]; do
    hits=$(printf '%s\n' "$normalized" | LC_ALL=C grep -n -E -e "${_GATE_DENY_PATTERNS[$r]}")
    rest=$hits
    while [ -n "$rest" ]; do
      hit=${rest%%"$_GATE_NL"*}
      case $rest in
        *"$_GATE_NL"*) rest=${rest#*"$_GATE_NL"} ;;
        *) rest="" ;;
      esac
      number=${hit%%:*}
      content=${hit#*:}
      allowed=0
      a=0
      while [ "$a" -lt "${#_GATE_ALLOW_IDS[@]}" ]; do
        if [ "${_GATE_ALLOW_IDS[$a]}" = "${_GATE_DENY_IDS[$r]}" ] &&
           printf '%s\n' "$content" | LC_ALL=C grep -E -e "${_GATE_ALLOW_PATTERNS[$a]}" >/dev/null 2>&1; then
          allowed=1
          break
        fi
        a=$((a + 1))
      done
      [ "$allowed" = 0 ] || continue
      original=$(printf '%s\n' "$text" | sed -n "${number}p")
      printf 'DENY %s %s:%s: %s\n' "${_GATE_DENY_IDS[$r]}" "$label" "$number" "$original"
      GATE_HIT_COUNT=$((GATE_HIT_COUNT + 1))
    done
    r=$((r + 1))
  done
}

gate_check_denylist() {
  local rules target text
  [ "$#" -ge 1 ] || return 2
  rules=$1
  shift
  _gate_load_rules "$rules" || return 2
  GATE_HIT_COUNT=0
  if [ "$#" -eq 0 ]; then
    text=$(cat)
    _gate_scan stdin "$text"
  else
    for target in "$@"; do
      if [ ! -f "$target" ] || [ ! -r "$target" ]; then
        printf 'gate: cannot read %s\n' "$target" >&2
        return 2
      fi
    done
    for target in "$@"; do
      text=$(cat -- "$target")
      _gate_scan "$target" "$text"
    done
  fi
  [ "$GATE_HIT_COUNT" -eq 0 ]
}

_gate_name_ok() {
  case $1 in
    ''|[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_]*) return 1 ;;
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:.-]*) return 1 ;;
  esac
  return 0
}

# Sets _GATE_COUNT, _GATE_START and _GATE_STOP, or _GATE_WHY on failure.
_gate_locate() {
  local range
  range=$(printf '%s\n' "$1" | LC_ALL=C awk -v name="$2" '
    BEGIN { head = name "() {"; count = 0; start = 0; stop = 0 }
    index($0, head) == 1 {
      rest = substr($0, length(head) + 1)
      if (rest == "" || rest ~ /^[ \t]/) {
        count++
        if (count == 1) {
          start = NR
          if (rest ~ /[;&][ \t]*[}][ \t]*$/) stop = NR
        }
        next
      }
    }
    count == 1 && stop == 0 && /^[}][ \t]*$/ { stop = NR }
    END { print count, start, stop }')
  _GATE_COUNT=${range%% *}
  range=${range#* }
  _GATE_START=${range%% *}
  _GATE_STOP=${range#* }
  if [ "$_GATE_COUNT" -eq 0 ]; then
    _GATE_WHY="no function $2"
    return 1
  fi
  if [ "$_GATE_COUNT" -gt 1 ]; then
    _GATE_WHY="function $2 is defined $_GATE_COUNT times"
    return 1
  fi
  if [ "$_GATE_STOP" -eq 0 ]; then
    _GATE_WHY="function $2 has no closing brace at column 0"
    return 1
  fi
  return 0
}

gate_function_body() {
  [ "$#" -eq 2 ] || return 2
  _gate_name_ok "$2" || return 2
  if ! _gate_locate "$1" "$2"; then
    printf 'gate: %s\n' "$_GATE_WHY" >&2
    return 1
  fi
  printf '%s\n' "$1" | sed -n "${_GATE_START},${_GATE_STOP}p"
}

gate_count_inside_function() {
  local count line
  if [ "$#" -ne 3 ] || [ -z "$2" ] || ! _gate_name_ok "$3"; then
    return 2
  fi
  count=$(printf '%s\n' "$1" | LC_ALL=C grep -c -F -e "$2")
  if [ "$count" -ne 1 ]; then
    printf 'count=%s\n' "$count"
    return 1
  fi
  line=$(printf '%s\n' "$1" | LC_ALL=C grep -n -F -e "$2")
  line=${line%%:*}
  if ! _gate_locate "$1" "$3"; then
    printf '%s\n' "$_GATE_WHY"
    return 1
  fi
  if [ "$_GATE_START" -eq "$_GATE_STOP" ]; then
    [ "$line" -eq "$_GATE_START" ] && return 0
  elif [ "$line" -gt "$_GATE_START" ] && [ "$line" -lt "$_GATE_STOP" ]; then
    return 0
  fi
  printf 'outside %s\n' "$3"
  return 1
}

gate_order_in_function() {
  local first second
  if [ "$#" -ne 3 ] || [ -z "$2" ] || [ -z "$3" ]; then
    return 2
  fi
  first=$(printf '%s\n' "$1" | LC_ALL=C grep -n -m 1 -F -e "$2")
  second=$(printf '%s\n' "$1" | LC_ALL=C grep -n -m 1 -F -e "$3")
  if [ -z "$first" ]; then
    printf 'missing "%s"\n' "$2"
    return 1
  fi
  if [ -z "$second" ]; then
    printf 'missing "%s"\n' "$3"
    return 1
  fi
  [ "${first%%:*}" -lt "${second%%:*}" ] && return 0
  printf '"%s" comes after "%s"\n' "$2" "$3"
  return 1
}

gate_lint_function_columns() {
  [ "$#" -eq 1 ] || return 2
  printf '%s\n' "$1" | LC_ALL=C awk '
    /^[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*[(][)][ \t]*[{]/ {
      printf "line %d: function defined with leading whitespace\n", NR; bad++; next
    }
    /^[ \t]*function[ \t]+[A-Za-z_]/ {
      printf "line %d: function keyword form; write name() { at column 0\n", NR; bad++; next
    }
    /^[A-Za-z_][A-Za-z0-9_:.-]*[ \t]+[(][)]/ {
      printf "line %d: space before (); write name() { at column 0\n", NR; bad++; next
    }
    /^[A-Za-z_][A-Za-z0-9_:.-]*[(][)][ \t]*[{]/ {
      if (open) { printf "line %d: function %s has no closing brace at column 0\n", open, fname; bad++ }
      open = 0
      rest = $0
      sub(/^[^{]*[{]/, "", rest)
      if (rest !~ /[;&][ \t]*[}][ \t]*$/) { open = NR; fname = $0; sub(/[(][)].*$/, "", fname) }
      next
    }
    open && /^[}][ \t]*$/ { open = 0 }
    END {
      if (open) { printf "line %d: function %s has no closing brace at column 0\n", open, fname; bad++ }
      exit (bad > 0)
    }'
}
