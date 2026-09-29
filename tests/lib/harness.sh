# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034 # globals set here are read by the tests that source this file
# harness.sh - shared setup for the stack-up tests. Sourced, never executed.
# Every test gets its own temporary HOME and XDG_STATE_HOME, a double for the
# keep-awake helper, so no test touches power state, and helpers that run the
# real bin/stack-up with /bin/bash. Nothing here writes outside that temporary
# folder, which is left to the OS.

set -u
set -o pipefail
# An exported CDPATH makes cd print the folder it found.
unset CDPATH

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO=$(cd "$TESTS_DIR/.." && pwd -P)
STACK_UP=$REPO/bin/stack-up
DEMO=$REPO/examples/demo

# shellcheck source=../../lib/testing.sh
. "$REPO/lib/testing.sh"
# shellcheck source=ports.sh
. "$TESTS_DIR/lib/ports.sh"

testing_init || exit 1
T=$(cd "$TESTING_TMPDIR" && pwd -P) || exit 1
export HOME=$T/home
export XDG_STATE_HOME=$T/state
export NO_COLOR=1
unset PROMPT_INTERACTIVE PROMPT_TTY PROMPT_TEST_SEAM
# The quickstart curl lines run as written, and the proxy tests set their own
# values; an exported proxy, no_proxy list or curl config would answer for, or
# refuse, 127.0.0.1 and fail a correct engine.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy CURL_HOME XDG_CONFIG_HOME
mkdir -p "$HOME" "$T/shims" "$T/named" "$XDG_STATE_HOME"
SHIM_LOG=$T/shims.log
: >> "$SHIM_LOG"
# The shared lib signals keep-awake only while it is a child of the engine
# named caffeinate, and macOS names a process after the path that started it,
# so the double runs again under a link to bash called caffeinate.
ln -s /bin/bash "$T/named/caffeinate"
cat >> "$T/shims/caffeinate" <<SHIM
#!/bin/bash
[ "\${BASH:-}" = "$T/named/caffeinate" ] || exec "$T/named/caffeinate" "\$0" "\$@"
printf 'caffeinate %s\n' "\$*" >> "$SHIM_LOG"
while [ "\$#" -gt 0 ]; do
  case \$1 in
    -w) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
while kill -0 "\${pid:-0}" 2>/dev/null; do sleep 1; done
SHIM
chmod +x "$T/shims/caffeinate"
export PATH="$T/shims:$PATH"

OUT=""
STATUS=0

# stdin comes from /dev/null, so no question in the engine can wait on a
# terminal; the output lands in OUT and the exit status in STATUS.
su_run() {
  OUT=$(/bin/bash "$STACK_UP" "$@" </dev/null 2>&1)
  STATUS=$?
}

check_status() {
  testing_check "$1 (exit status)" "$2" "$STATUS"
}

# Runs a stop command as stack-up printed it, with this repository's
# bin/stack-up in place of the program word; an empty line is a failure, never
# a run with no arguments.
run_printed() {
  if [ -z "$1" ]; then
    OUT="no stop command was printed"
    STATUS=none
    return
  fi
  eval "set -- $1"
  shift
  su_run "$@"
}

check_match() {
  if printf '%s\n' "$3" | LC_ALL=C grep -E -e "$2" >/dev/null 2>&1; then
    testing_check "$1" yes yes
  else
    testing_check "$1" "a line matching /$2/" "no such line"
  fi
}

check_line() {
  if printf '%s\n' "$3" | LC_ALL=C grep -F -x -e "$2" >/dev/null 2>&1; then
    testing_check "$1" yes yes
  else
    testing_check "$1" "the line [$2]" "no such line"
  fi
}

check_no_match() {
  if printf '%s\n' "$3" | LC_ALL=C grep -E -e "$2" >/dev/null 2>&1; then
    testing_check "$1" "no line matching /$2/" "$(printf '%s\n' "$3" | LC_ALL=C grep -E -e "$2" | head -n 1)"
  else
    testing_check "$1" yes yes
  fi
}

write_conf() {
  local file=$1
  mkdir -p "$(dirname "$file")"
  cat >> "$file"
}

state_of() {
  printf '%s/stack-up/%s\n' "$XDG_STATE_HOME" "$1"
}

group_alive() {
  [ -n "$(pgrep -g "$1" 2>/dev/null)" ]
}

wait_until_gone() {
  local pgid=$1 tries=0
  while group_alive "$pgid" && [ "$tries" -lt 50 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  ! group_alive "$pgid"
}

count_files() {
  local n=0 path
  for path in "$1"/$2; do
    [ -e "$path" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Run log names start with the time, so the last one in glob order is the
# newest.
newest_run_log() {
  local path last=""
  for path in "$1"/logs/run-*.log; do
    [ -e "$path" ] && last=$path
  done
  printf '%s\n' "$last"
}

mode_of() {
  # shellcheck disable=SC2012 # only the fixed-width mode column is read
  ls -ld "$1" | cut -c 1-10
}

# A signal ignored when a shell starts stays ignored in everything it runs, and
# a test started in the background by a shell without job control starts with
# SIGINT ignored, so a scenario that sends an interrupt checks first that one
# can arrive.
interrupts_arrive() {
  local probe ticks=0
  set -m
  sleep 30 &
  probe=$!
  set +m
  kill -INT "$probe" 2>/dev/null
  while kill -0 "$probe" 2>/dev/null && [ "$ticks" -lt 10 ]; do
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if kill -0 "$probe" 2>/dev/null; then
    kill -TERM "$probe" 2>/dev/null
    wait "$probe" 2>/dev/null
    return 1
  fi
  wait "$probe" 2>/dev/null
  return 0
}
