# shellcheck shell=bash
# conf.sh - reader and validator for sectioned "key = value" config files.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
#
# File format:
#   # a comment: the first non-blank character of the line is #
#   [kind]            a section with no name
#   [kind name]       a named section
#   key = value       the value is the rest of the line after the first =,
#                     trimmed; quotes are kept, and |, = and # are literal
#
# The tool declares its schema with conf_schema_kind and conf_schema_key, then
# calls conf_load. Rows are held in memory as "kind|name|key|value"; the value
# is the last field, so `IFS='|' read -r kind name key value` keeps it whole.
# shellcheck disable=SC2034 # globals set here are read by the scripts that source this file

[ -n "${_CONF_SH_LOADED:-}" ] && return 0
_CONF_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=util.sh
. "$_LIB_DIR/util.sh" || return 1

CONF_FILE=""
CONF_ERRORS=""
CONF_ERROR_COUNT=0
CONF_ROWS=()
CONF_ROW_LINES=()
CONF_SECTIONS=()
CONF_SECTION_LINES=()
_CONF_KIND_NAMES=()
_CONF_KIND_CARDS=()
_CONF_KIND_RULES=()
_CONF_KEY_KINDS=()
_CONF_KEY_NAMES=()
_CONF_KEY_TYPES=()
_CONF_KEY_FLAGS=()
_CONF_INDEX=0
_CONF_WHY=""
_CONF_NAME_SET=""
_CONF_NAME_FIRST=""
_CONF_NAME_REST=""
_CONF_NAME_MAX=0
_CONF_NAME_HINT=""
_CONF_TAB=$'\t'
_CONF_NL=$'\n'
# Explicit character lists, not ranges: bash 3.2 matches [a-z] against
# capital letters in a UTF-8 locale.
_CONF_LOWER=abcdefghijklmnopqrstuvwxyz
_CONF_DIGITS=0123456789
_CONF_UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ

_conf_token_ok() {
  local value=$1 first_chars=$2 rest_chars=$3 first
  [ -n "$value" ] || return 1
  first=${value%"${value#?}"}
  case $first in
    [!$first_chars]) return 1 ;;
  esac
  case $value in
    *[!$rest_chars]*) return 1 ;;
  esac
  return 0
}

_conf_ere_ok() {
  [ -n "$1" ] || return 1
  LC_ALL=C grep -E -e "$1" </dev/null >/dev/null 2>&1
  [ "$?" -ne 2 ]
}

# grep reads all of its input here (no -q), so a pipe under pipefail cannot
# turn an early exit into a SIGPIPE status.
_conf_full_match() {
  printf '%s\n' "$1" | LC_ALL=C grep -E -e "^($2)\$" >/dev/null 2>&1
}

# The name type checks in bash, with no process per value. Its lists accept
# a-z, A-Z and 0-9 as whole ranges and . _ + @ - as themselves; - goes last
# so the bracket expressions below read it as a character, not a range.
_conf_name_set() {
  local spec=$1 set="" dash=""
  [ -n "$spec" ] || return 1
  while [ -n "$spec" ]; do
    case $spec in
      a-z*) set=$set$_CONF_LOWER; spec=${spec#a-z} ;;
      A-Z*) set=$set$_CONF_UPPER; spec=${spec#A-Z} ;;
      0-9*) set=$set$_CONF_DIGITS; spec=${spec#0-9} ;;
      -*) dash=-; spec=${spec#-} ;;
      [._+@]*) set=$set${spec%"${spec#?}"}; spec=${spec#?} ;;
      *) return 1 ;;
    esac
  done
  _CONF_NAME_SET=$set$dash
  return 0
}

# Parses FIRST:REST:MAX into _CONF_NAME_FIRST, _CONF_NAME_REST, _CONF_NAME_MAX
# and _CONF_NAME_HINT.
_conf_name_spec() {
  local spec=$1 first rest max
  case $spec in
    *:*:*) ;;
    *) return 1 ;;
  esac
  first=${spec%%:*}
  spec=${spec#*:}
  rest=${spec%%:*}
  max=${spec#*:}
  util_is_uint "$max" && [ "$max" -ge 1 ] || return 1
  _conf_name_set "$first" || return 1
  _CONF_NAME_FIRST=$_CONF_NAME_SET
  _conf_name_set "$rest" || return 1
  _CONF_NAME_REST=$_CONF_NAME_SET
  _CONF_NAME_MAX=$max
  _CONF_NAME_HINT="must be 1 to $max characters, the first from $first and the rest from $rest"
  return 0
}

_conf_name_ok() {
  local value=$1
  [ -n "$value" ] && [ "${#value}" -le "$_CONF_NAME_MAX" ] || return 1
  case ${value%"${value#?}"} in
    [!$_CONF_NAME_FIRST]) return 1 ;;
  esac
  case ${value#?} in
    *[!$_CONF_NAME_REST]*) return 1 ;;
  esac
  return 0
}

_conf_kind_index() {
  local i=0
  while [ "$i" -lt "${#_CONF_KIND_NAMES[@]}" ]; do
    if [ "${_CONF_KIND_NAMES[$i]}" = "$1" ]; then
      _CONF_INDEX=$i
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

_conf_key_index() {
  local i=0
  while [ "$i" -lt "${#_CONF_KEY_NAMES[@]}" ]; do
    if [ "${_CONF_KEY_KINDS[$i]}" = "$1" ] && [ "${_CONF_KEY_NAMES[$i]}" = "$2" ]; then
      _CONF_INDEX=$i
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

_conf_type_ok() {
  local spec rest minimum maximum
  case $1 in
    text|int|regex) return 0 ;;
    int:*:*)
      rest=${1#int:}
      minimum=${rest%%:*}
      maximum=${rest#*:}
      util_is_uint "$minimum" && util_is_uint "$maximum" && [ "$minimum" -le "$maximum" ]
      return
      ;;
    enum:*)
      spec=${1#enum:}
      case ",$spec," in
        *,,*|*' '*) return 1 ;;
      esac
      return 0
      ;;
    match:*|list:*)
      _conf_ere_ok "${1#*:}"
      return
      ;;
    name:*)
      _conf_name_spec "${1#name:}"
      return
      ;;
  esac
  return 1
}

_conf_check_value() {
  local type=$1 value=$2 rest minimum maximum spec words="" word bad
  _CONF_WHY=""
  case $type in
    text) return 0 ;;
    int)
      util_is_uint "$value" && return 0
      _CONF_WHY="must be a whole number without leading zeros, got \"$value\""
      return 1
      ;;
    int:*)
      rest=${type#int:}
      minimum=${rest%%:*}
      maximum=${rest#*:}
      if util_is_uint "$value" && [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]; then
        return 0
      fi
      _CONF_WHY="must be a whole number from $minimum to $maximum, got \"$value\""
      return 1
      ;;
    enum:*)
      spec=${type#enum:}
      case $value in
        ''|*,*) ;;
        *)
          case ",$spec," in
            *",$value,"*) return 0 ;;
          esac
          ;;
      esac
      _CONF_WHY="must be one of ${spec//,/, }, got \"$value\""
      return 1
      ;;
    match:*)
      _conf_full_match "$value" "${type#match:}" && return 0
      _CONF_WHY="does not have the expected form, got \"$value\""
      return 1
      ;;
    name:*)
      _conf_name_spec "${type#name:}" && _conf_name_ok "$value" && return 0
      _CONF_WHY="$_CONF_NAME_HINT, got \"$value\""
      return 1
      ;;
    list:*)
      rest=$value
      while :; do
        util_trim "$rest"
        rest=$UTIL_TRIMMED
        [ -n "$rest" ] || break
        word=${rest%%[ $_CONF_TAB]*}
        rest=${rest#"$word"}
        words=$words$word$_CONF_NL
      done
      [ -n "$words" ] || return 0
      bad=$(printf '%s' "$words" | LC_ALL=C grep -E -v -e "^(${type#list:})\$")
      [ -n "$bad" ] || return 0
      _CONF_WHY="has an item without the expected form: \"${bad%%"$_CONF_NL"*}\""
      return 1
      ;;
    regex)
      if [ -z "$value" ]; then
        _CONF_WHY="must not be empty, because an empty pattern matches every line"
        return 1
      fi
      _conf_ere_ok "$value" && return 0
      _CONF_WHY="is not a valid extended regular expression: \"$value\""
      return 1
      ;;
  esac
  _CONF_WHY="has an unknown type $type"
  return 1
}

conf_schema_reset() {
  _CONF_KIND_NAMES=(); _CONF_KIND_CARDS=(); _CONF_KIND_RULES=()
  _CONF_KEY_KINDS=(); _CONF_KEY_NAMES=(); _CONF_KEY_TYPES=(); _CONF_KEY_FLAGS=()
  CONF_FILE=""; CONF_ERRORS=""; CONF_ERROR_COUNT=0
  CONF_ROWS=(); CONF_ROW_LINES=(); CONF_SECTIONS=(); CONF_SECTION_LINES=()
  return 0
}

conf_schema_kind() {
  local n
  [ "$#" -eq 3 ] || return 2
  _conf_token_ok "$1" "$_CONF_LOWER" "$_CONF_LOWER$_CONF_DIGITS"_- || return 2
  case $2 in
    one|optional|many) ;;
    *) return 2 ;;
  esac
  case $3 in
    -) ;;
    name:*) _conf_name_spec "${3#name:}" || return 2 ;;
    *) _conf_ere_ok "$3" || return 2 ;;
  esac
  if _conf_kind_index "$1"; then
    return 2
  fi
  n=${#_CONF_KIND_NAMES[@]}
  _CONF_KIND_NAMES[n]=$1
  _CONF_KIND_CARDS[n]=$2
  _CONF_KIND_RULES[n]=$3
  return 0
}

conf_schema_key() {
  local kind key type flags=" " flag n
  [ "$#" -ge 3 ] || return 2
  kind=$1
  key=$2
  type=$3
  shift 3
  _conf_kind_index "$kind" || return 2
  _conf_token_ok "$key" "$_CONF_LOWER" "$_CONF_LOWER$_CONF_DIGITS"_ || return 2
  _conf_type_ok "$type" || return 2
  for flag in "$@"; do
    case $flag in
      required|repeat) flags="$flags$flag " ;;
      *) return 2 ;;
    esac
  done
  if _conf_key_index "$kind" "$key"; then
    return 2
  fi
  n=${#_CONF_KEY_NAMES[@]}
  _CONF_KEY_KINDS[n]=$kind
  _CONF_KEY_NAMES[n]=$key
  _CONF_KEY_TYPES[n]=$type
  _CONF_KEY_FLAGS[n]=$flags
  return 0
}

conf_error() {
  local where
  [ "$#" -eq 2 ] || return 2
  case $1 in
    '') where=${CONF_FILE:-config} ;;
    *[!0123456789]*) return 2 ;;
    *) where=${CONF_FILE:-config}:$1 ;;
  esac
  printf '%s: %s\n' "$where" "$2" >&2
  if [ -n "$CONF_ERRORS" ]; then
    CONF_ERRORS=$CONF_ERRORS$_CONF_NL
  fi
  CONF_ERRORS="$CONF_ERRORS$where: $2"
  CONF_ERROR_COUNT=$((CONF_ERROR_COUNT + 1))
  return 0
}

_conf_find_section() {
  local i=0
  while [ "$i" -lt "${#CONF_SECTIONS[@]}" ]; do
    if [ "${CONF_SECTIONS[$i]}" = "$1" ]; then
      _CONF_INDEX=$i
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

_conf_find_kind_section() {
  local i=0
  while [ "$i" -lt "${#CONF_SECTIONS[@]}" ]; do
    case ${CONF_SECTIONS[$i]} in
      "$1|"*)
        _CONF_INDEX=$i
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# Sets _CONF_SECTION_OK, _CONF_SECTION_KIND, _CONF_SECTION_NAME, _CONF_SECTION_LABEL.
_conf_open_section() {
  local line=$1 number=$2 inner kind name label card rule n
  _CONF_SECTION_OK=0
  _CONF_SECTION_KIND=""
  _CONF_SECTION_NAME=""
  inner=${line#\[}
  inner=${inner%\]}
  util_trim "$inner"
  inner=$UTIL_TRIMMED
  if [ -z "$inner" ]; then
    conf_error "$number" "empty section header []"
    return 1
  fi
  kind=${inner%%[ $_CONF_TAB]*}
  util_trim "${inner#"$kind"}"
  name=$UTIL_TRIMMED
  _CONF_SECTION_KIND=$kind
  case $name in
    *[" $_CONF_TAB"]*)
      conf_error "$number" "section header [$inner] has more than a kind and a name"
      return 1
      ;;
  esac
  if ! _conf_kind_index "$kind"; then
    conf_error "$number" "unknown section kind $kind"
    return 1
  fi
  card=${_CONF_KIND_CARDS[$_CONF_INDEX]}
  rule=${_CONF_KIND_RULES[$_CONF_INDEX]}
  if [ "$rule" = - ]; then
    if [ -n "$name" ]; then
      conf_error "$number" "section [$kind] takes no name, got \"$name\""
      return 1
    fi
    label="[$kind]"
  else
    if [ -z "$name" ]; then
      conf_error "$number" "section [$kind] needs a name"
      return 1
    fi
    case $name in
      *'|'*)
        conf_error "$number" "bad name \"$name\" for [$kind]: | is not allowed"
        return 1
        ;;
    esac
    case $rule in
      name:*)
        if ! _conf_name_spec "${rule#name:}" || ! _conf_name_ok "$name"; then
          conf_error "$number" "bad name \"$name\" for [$kind]: it $_CONF_NAME_HINT"
          return 1
        fi
        ;;
      *)
        if ! _conf_full_match "$name" "$rule"; then
          conf_error "$number" "bad name \"$name\" for [$kind]"
          return 1
        fi
        ;;
    esac
    label="[$kind $name]"
  fi
  if [ "$card" != many ] && _conf_find_kind_section "$kind"; then
    conf_error "$number" "only one [$kind] section is allowed, first at line ${CONF_SECTION_LINES[$_CONF_INDEX]}"
    return 1
  fi
  if _conf_find_section "$kind|$name"; then
    conf_error "$number" "duplicate section $label, first at line ${CONF_SECTION_LINES[$_CONF_INDEX]}"
    return 1
  fi
  n=${#CONF_SECTIONS[@]}
  CONF_SECTIONS[n]="$kind|$name"
  CONF_SECTION_LINES[n]=$number
  _CONF_SECTION_OK=1
  _CONF_SECTION_NAME=$name
  _CONF_SECTION_LABEL=$label
  return 0
}

_conf_add_key() {
  local line=$1 number=$2 key value prefix i n flags type
  key=${line%%=*}
  value=${line#*=}
  util_trim "$key"
  key=$UTIL_TRIMMED
  util_trim "$value"
  value=$UTIL_TRIMMED
  if [ -z "$key" ]; then
    conf_error "$number" "missing key before ="
    return 1
  fi
  if ! _conf_token_ok "$key" "$_CONF_LOWER" "$_CONF_LOWER$_CONF_DIGITS"_; then
    conf_error "$number" "bad key \"$key\": use lowercase letters, digits and _"
    return 1
  fi
  if ! _conf_key_index "$_CONF_SECTION_KIND" "$key"; then
    conf_error "$number" "unknown key $key in $_CONF_SECTION_LABEL"
    return 1
  fi
  type=${_CONF_KEY_TYPES[$_CONF_INDEX]}
  flags=${_CONF_KEY_FLAGS[$_CONF_INDEX]}
  prefix="$_CONF_SECTION_KIND|$_CONF_SECTION_NAME|$key|"
  case $flags in
    *' repeat '*) ;;
    *)
      i=$_CONF_SECTION_FIRST_ROW
      while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
        case ${CONF_ROWS[$i]} in
          "$prefix"*)
            conf_error "$number" "duplicate key $key in $_CONF_SECTION_LABEL, first at line ${CONF_ROW_LINES[$i]}"
            return 1
            ;;
        esac
        i=$((i + 1))
      done
      ;;
  esac
  # A rejected value is still stored, so a key that is present but wrong is
  # not reported a second time as a missing required key.
  n=${#CONF_ROWS[@]}
  CONF_ROWS[n]="$prefix$value"
  CONF_ROW_LINES[n]=$number
  if ! _conf_check_value "$type" "$value"; then
    conf_error "$number" "$key in $_CONF_SECTION_LABEL $_CONF_WHY"
    return 1
  fi
  return 0
}

_conf_check_required() {
  local s=0 k kind name label
  while [ "$s" -lt "${#CONF_SECTIONS[@]}" ]; do
    kind=${CONF_SECTIONS[$s]%%|*}
    name=${CONF_SECTIONS[$s]#*|}
    if [ -n "$name" ]; then label="[$kind $name]"; else label="[$kind]"; fi
    k=0
    while [ "$k" -lt "${#_CONF_KEY_NAMES[@]}" ]; do
      if [ "${_CONF_KEY_KINDS[$k]}" = "$kind" ]; then
        case ${_CONF_KEY_FLAGS[$k]} in
          *' required '*)
            if ! conf_has "$kind" "$name" "${_CONF_KEY_NAMES[$k]}"; then
              conf_error "${CONF_SECTION_LINES[$s]}" "$label is missing required key ${_CONF_KEY_NAMES[$k]}"
            fi
            ;;
        esac
      fi
      k=$((k + 1))
    done
    s=$((s + 1))
  done
  k=0
  while [ "$k" -lt "${#_CONF_KIND_NAMES[@]}" ]; do
    if [ "${_CONF_KIND_CARDS[$k]}" = one ] && ! _conf_find_kind_section "${_CONF_KIND_NAMES[$k]}"; then
      conf_error "" "missing required section [${_CONF_KIND_NAMES[$k]}]"
    fi
    k=$((k + 1))
  done
}

conf_load() {
  local file raw line number=0 in_section=0
  [ "$#" -eq 1 ] || return 2
  file=$1
  CONF_FILE=$file
  CONF_ERRORS=""
  CONF_ERROR_COUNT=0
  CONF_ROWS=(); CONF_ROW_LINES=(); CONF_SECTIONS=(); CONF_SECTION_LINES=()
  _CONF_SECTION_OK=0
  _CONF_SECTION_KIND=""
  _CONF_SECTION_NAME=""
  _CONF_SECTION_LABEL=""
  _CONF_SECTION_FIRST_ROW=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    conf_error "" "cannot read the config file"
    return 2
  fi
  while IFS= read -r raw || [ -n "$raw" ]; do
    number=$((number + 1))
    raw=${raw%$'\r'}
    util_trim "$raw"
    line=$UTIL_TRIMMED
    case $line in
      ''|'#'*) continue ;;
      '['*']')
        in_section=1
        _CONF_SECTION_FIRST_ROW=${#CONF_ROWS[@]}
        _conf_open_section "$line" "$number"
        continue
        ;;
      '['*)
        in_section=1
        _CONF_SECTION_OK=0
        conf_error "$number" "section header is missing its closing ]"
        continue
        ;;
    esac
    if [ "$in_section" = 0 ]; then
      conf_error "$number" "key = value line outside any section"
      continue
    fi
    [ "$_CONF_SECTION_OK" = 1 ] || continue
    case $line in
      *=*) _conf_add_key "$line" "$number" ;;
      *) conf_error "$number" "expected key = value" ;;
    esac
  done < "$file"
  _conf_check_required
  [ "$CONF_ERROR_COUNT" -eq 0 ] && return 0
  return 1
}

conf_get() {
  local i=0 prefix
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    return 2
  fi
  prefix="$1|$2|$3|"
  while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
    case ${CONF_ROWS[$i]} in
      "$prefix"*)
        printf '%s\n' "${CONF_ROWS[$i]#"$prefix"}"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$#" -eq 4 ]; then
    printf '%s\n' "$4"
  fi
  return 1
}

conf_get_all() {
  local i=0 prefix found=1
  [ "$#" -eq 3 ] || return 2
  prefix="$1|$2|$3|"
  while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
    case ${CONF_ROWS[$i]} in
      "$prefix"*)
        printf '%s\n' "${CONF_ROWS[$i]#"$prefix"}"
        found=0
        ;;
    esac
    i=$((i + 1))
  done
  return "$found"
}

conf_has() {
  local i=0 prefix
  [ "$#" -eq 3 ] || return 2
  prefix="$1|$2|$3|"
  while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
    case ${CONF_ROWS[$i]} in
      "$prefix"*) return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

conf_names() {
  local i=0
  [ "$#" -eq 1 ] || return 2
  while [ "$i" -lt "${#CONF_SECTIONS[@]}" ]; do
    case ${CONF_SECTIONS[$i]} in
      "$1|"*) printf '%s\n' "${CONF_SECTIONS[$i]#*|}" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

conf_rows() {
  local i=0
  while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
    printf '%s\n' "${CONF_ROWS[$i]}"
    i=$((i + 1))
  done
  return 0
}

conf_line() {
  local i=0 prefix
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    return 2
  fi
  if [ "$#" -eq 2 ]; then
    _conf_find_section "$1|$2" || return 1
    printf '%s\n' "${CONF_SECTION_LINES[$_CONF_INDEX]}"
    return 0
  fi
  prefix="$1|$2|$3|"
  while [ "$i" -lt "${#CONF_ROWS[@]}" ]; do
    case ${CONF_ROWS[$i]} in
      "$prefix"*)
        printf '%s\n' "${CONF_ROW_LINES[$i]}"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# Substitution is literal: a value never runs as code, and a replacement text
# is never scanned again for placeholders.
conf_expand() {
  local value allowed="" name out="" rest status=0 var
  [ "$#" -ge 1 ] || return 2
  value=$1
  shift
  for var in "$@"; do
    _conf_token_ok "$var" "$_CONF_LOWER$_CONF_UPPER"_ "$_CONF_LOWER$_CONF_UPPER$_CONF_DIGITS"_ || return 2
    allowed="$allowed $var"
  done
  rest=$value
  while :; do
    case $rest in
      *'${'*) ;;
      *)
        out=$out$rest
        break
        ;;
    esac
    out=$out${rest%%'${'*}
    rest=${rest#*'${'}
    case $rest in
      *'}'*) ;;
      *)
        out=$out'${'$rest
        status=1
        break
        ;;
    esac
    name=${rest%%'}'*}
    rest=${rest#*'}'}
    if util_contains_word "$name" "$allowed" && [ -n "${!name+set}" ]; then
      out=$out${!name}
    else
      out=$out'${'$name'}'
      status=1
    fi
  done
  printf '%s\n' "$out"
  return "$status"
}
