# shellcheck shell=bash
# testing.sh - helpers for test scripts: function extraction, checks, mutation
# probes and the closing verdict line.
# Sourced, never executed. bash 3.2 compatible and safe under set -u.
# Counters live in this shell: a check run inside $( ) or ( ) is not counted.

[ -n "${_TESTING_SH_LOADED:-}" ] && return 0
_TESTING_SH_LOADED=1

case ${BASH_SOURCE[0]} in
  */*) _LIB_DIR=${BASH_SOURCE[0]%/*} ;;
  *) _LIB_DIR=. ;;
esac
# shellcheck source=gate.sh
. "$_LIB_DIR/gate.sh" || return 1

TESTING_PASSED=0
TESTING_FAILED=0
TESTING_TMPDIR=${TESTING_TMPDIR-}
TESTING_BASELINE_OK=0
TESTING_BASELINE_OUTPUT=""

testing_init() {
  TESTING_PASSED=0
  TESTING_FAILED=0
  TESTING_BASELINE_OK=0
  TESTING_BASELINE_OUTPUT=""
  if [ -z "$TESTING_TMPDIR" ]; then
    TESTING_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/lib-testing.XXXXXX") || {
      printf 'testing: mktemp -d failed\n' >&2
      TESTING_TMPDIR=""
      return 1
    }
  fi
  return 0
}

_testing_pass() {
  TESTING_PASSED=$((TESTING_PASSED + 1))
  printf 'PASS  %s\n' "$1"
}

_testing_fail() {
  TESTING_FAILED=$((TESTING_FAILED + 1))
  printf 'FAIL  %s\n' "$1"
}

# An empty extraction must never look like a function that passed: every
# failure goes to stderr with a non-zero status.
testing_extract_function() {
  local text
  [ "$#" -eq 2 ] || return 2
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    printf 'testing: cannot read %s\n' "$1" >&2
    return 1
  fi
  text=$(cat -- "$1")
  _GATE_WHY="not a valid function name"
  if ! gate_function_body "$text" "$2" 2>/dev/null; then
    printf 'testing: could not extract %s from %s: %s\n' "$2" "$1" "$_GATE_WHY" >&2
    return 1
  fi
  return 0
}

testing_source_function() {
  local body file
  [ "$#" -eq 2 ] || return 2
  if [ -z "$TESTING_TMPDIR" ]; then
    testing_init || return 1
  fi
  if ! body=$(testing_extract_function "$1" "$2") || [ -z "$body" ]; then
    _testing_fail "extract $2 from $1"
    return 1
  fi
  if ! file=$(mktemp "$TESTING_TMPDIR/function.XXXXXX"); then
    _testing_fail "extract $2 from $1: mktemp failed"
    return 1
  fi
  printf '%s\n' "$body" >> "$file"
  # shellcheck disable=SC1090
  if ! . "$file" || ! declare -F "$2" >/dev/null 2>&1; then
    _testing_fail "extract $2 from $1: sourcing did not define it"
    return 1
  fi
  return 0
}

testing_check() {
  [ "$#" -eq 3 ] || return 2
  if [ "$2" = "$3" ]; then
    _testing_pass "$1"
    return 0
  fi
  _testing_fail "$1: expected [$2] got [$3]"
  return 1
}

testing_baseline() {
  [ "$#" -eq 3 ] || return 2
  TESTING_BASELINE_OUTPUT=$3
  if [ "$2" = 0 ]; then
    TESTING_BASELINE_OK=1
    _testing_pass "baseline $1 passes unmutated"
    return 0
  fi
  TESTING_BASELINE_OK=0
  _testing_fail "baseline $1 fails unmutated (status $2), so no probe can prove anything"
  return 1
}

# A probe bites when the mutated output matches PATTERN. It proves nothing
# without a passing baseline, or when the baseline output matches PATTERN too.
testing_expect_fail() {
  [ "$#" -eq 3 ] || return 2
  if [ "$TESTING_BASELINE_OK" != 1 ]; then
    _testing_fail "probe $1: no passing baseline was recorded first"
    return 1
  fi
  if [ -z "$3" ]; then
    _testing_fail "probe $1: empty pattern matches anything"
    return 1
  fi
  if printf '%s\n' "$TESTING_BASELINE_OUTPUT" | LC_ALL=C grep -E -e "$3" >/dev/null 2>&1; then
    _testing_fail "probe $1: pattern also matches the unmutated output"
    return 1
  fi
  if printf '%s\n' "$2" | LC_ALL=C grep -E -e "$3" >/dev/null 2>&1; then
    _testing_pass "probe $1 bites"
    return 0
  fi
  _testing_fail "probe $1 did not bite"
  return 1
}

# Never returns. Zero checks is a failure, because a suite that ran nothing
# proved nothing.
testing_verdict() {
  local total=$((TESTING_PASSED + TESTING_FAILED))
  printf '\n%s passed, %s failed\n' "$TESTING_PASSED" "$TESTING_FAILED"
  if [ "$total" -eq 0 ]; then
    printf 'no checks ran\nRESULT: FAIL 1\n'
    exit 1
  fi
  if [ "$TESTING_FAILED" -eq 0 ]; then
    printf 'RESULT: PASS\n'
    exit 0
  fi
  printf 'RESULT: FAIL %s\n' "$TESTING_FAILED"
  exit 1
}
