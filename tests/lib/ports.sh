# shellcheck shell=bash
# shellcheck disable=SC2034 # FREE_PORT and PICKED_PORTS are read by the tests
# ports.sh - free loopback ports for the tests, and the demo config rendered
# onto them. Sourced by harness.sh, never executed; bash 3.2 compatible. It
# never hands out a port twice in one test file, and never edits the demo
# config in place.

PICKED_PORTS=""
FREE_PORT=""

port_is_free() {
  if nc -z 127.0.0.1 "$1" >/dev/null 2>&1; then return 1; fi
  [ -z "$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null)" ]
}

# Sets FREE_PORT instead of printing it: a $( ) call would run in a subshell
# and lose PICKED_PORTS, so two picks could collide.
pick_free_port() {
  local tries=0 candidate
  FREE_PORT=""
  while [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    candidate=$((20000 + RANDOM % 10000))
    case " $PICKED_PORTS " in *" $candidate "*) continue ;; esac
    port_is_free "$candidate" || continue
    PICKED_PORTS="$PICKED_PORTS $candidate"
    FREE_PORT=$candidate
    return 0
  done
  return 1
}

# The count guard fails loudly if the demo gains or loses a port site, so a
# test can never keep a fixed port by accident.
render_demo_config() {
  local source=$1 target=$2 api=$3 docs=$4
  awk '/18081/ { a++ } /18082/ { d++ } END { exit !(a == 4 && d == 2) }' "$source" ||
    { printf 'demo port sites changed; update render_demo_config\n' >&2; return 1; }
  awk -v api="$api" -v docs="$docs" '{ gsub(/18081/, api); gsub(/18082/, docs); print }' "$source" >> "$target"
  if grep -q '1808[12]' "$target"; then return 1; fi
  return 0
}
