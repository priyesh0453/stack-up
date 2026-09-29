#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-select.sh - the selection grammar: essential, recommended, all, none,
# numbers (read base 10), ranges in either direction, names, group:NAME,
# commas, case, and first-mention order. No stack is started: the engine is
# sourced and the real su_resolve_spec is called directly.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=../bin/stack-up
. "$STACK_UP"

conf=$T/select/stack.conf
{
  printf '[stack]\nname = pick\n'
  for name in alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo; do
    printf '[service %s]\nstart = sleep 60\n' "$name"
    case $name in
      alpha|bravo) printf 'tier = essential\ngroups = api\n' ;;
      charlie) printf 'tier = recommended\ngroups = web\n' ;;
      delta) printf 'groups = web api\n' ;;
    esac
  done
  printf '[job setup]\nstage = services\nrun = true\n'
} | write_conf "$conf"
SU_CONFIG=$conf
SU_ROOT_OVERRIDE=""
su_load_config
su_pickable
all=$SU_PICKABLE
testing_check "pickable entries are services in file order (jobs are not pickable)" \
  "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo" "$all"

expect() {
  local spec=$1 want=$2 want_status=${3:-0} status
  su_resolve_spec "$spec" "$all"
  status=$?
  testing_check "select [$spec] status" "$want_status" "$status"
  if [ "$want_status" = 0 ]; then
    testing_check "select [$spec]" "$want" "$SU_PICKED"
  else
    testing_check "select [$spec] names the bad token" "$want" "$SU_BAD_TOKEN"
  fi
}

expect "" ""
expect "essential" "alpha bravo"
expect "ess" "alpha bravo"
expect "recommended" "alpha bravo charlie"
expect "all" "$all"
expect "ALL" "$all"
expect "none" ""
expect "none 3" ""
expect "3 none" ""
expect "all none" "$all"
expect "1,3" "alpha charlie"
expect " 1 , 3 " "alpha charlie"
expect "010" "juliet"
expect "5-1" "alpha bravo charlie delta echo"
expect "1-3" "alpha bravo charlie"
expect "3-3" "charlie"
expect "kilo alpha kilo 1" "kilo alpha"
expect "Delta" "delta"
expect "group:web" "charlie delta"
expect "group:api essential" "alpha bravo delta"
expect "essential 11" "alpha bravo kilo"
expect "0" "0" 1
expect "12" "12" 1
expect "2-12" "2-12" 1
expect "1-" "1-" 1
expect "-1" "-1" 1
expect "1-2-3" "1-2-3" 1
expect "1234567890" "1234567890" 1
expect "setup" "setup" 1
expect "group:nosuch" "group:nosuch" 1
expect "zulu" "zulu" 1

testing_verdict
