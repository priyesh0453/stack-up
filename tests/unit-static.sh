#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # single-quoted $ is literal config or shell text on purpose
# unit-static.sh - static gates over the shipped tree, each proved by a
# mutation probe after an unmutated baseline passes:
#   * kill is allowed only inside su_alive, su_signal_group and
#     su_signal_launch, and a dynamic export (provider values, env and
#     env_file) only inside the forked child's su_exec_child,
#     su_export_provider and su_export_env_file; every other rule holds in
#     every engine function, so nothing looks up a parent pid or runs ps, and
#     no pattern kill, eval, sudo, system tool or machine path appears, in
#     the signal and child functions too; install.sh, uninstall.sh and the demo
#     scripts get every rule;
#   * a group is proven to be ours before it is signalled, and an interrupted
#     --check signals a probe group only while its leader answers kill -0;
#   * no destroy recipe past the compose project, in code or docs;
#   * every text file is ASCII, and every .png file is a PNG image.
# lib/ is not scanned here: it is pinned byte for byte by unit-manifest.sh.
# Every mutation lands in a copy under the test folder; the shipped tree is
# only read.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

RULES=$TESTS_DIR/static.rules
DOC_RULES=$TESTS_DIR/static-docs.rules
ALLOWED_SIGNALS="su_alive su_signal_group su_signal_launch"
CHILD_ONLY="su_exec_child su_export_provider su_export_env_file"

# The masked copy keeps every line in place, so a DENY names the engine's own
# line number.
mask_functions() {
  local file=$1 names=$2
  awk -v names=" $names " '
    match($0, /^[a-z_]+\(\) \{/) {
      name = substr($0, 1, index($0, "(") - 1)
      if (index(names, " " name " ") > 0) { inside = 1; print ""; next }
    }
    inside && /^}[ \t]*$/ { inside = 0; print ""; next }
    { print inside ? "" : $0 }
  ' "$file"
}

# The rules split three ways, so each function is excused only from the one
# rule it exists to break.
LC_ALL=C grep -v -E '^deny (kill|dynamic-export) ' "$RULES" >| "$T/rules-general"
LC_ALL=C grep -E '^deny kill ' "$RULES" >| "$T/rules-kill"
LC_ALL=C grep -E '^deny dynamic-export ' "$RULES" >| "$T/rules-export"

gate_all() {
  local engine=$1 status=0
  shift
  gate_check_denylist "$RULES" "$@" || status=1
  gate_check_denylist "$T/rules-general" "$engine" || status=1
  mask_functions "$engine" "$ALLOWED_SIGNALS" >| "$T/engine-signals-masked.sh"
  gate_check_denylist "$T/rules-kill" "$T/engine-signals-masked.sh" || status=1
  mask_functions "$engine" "$CHILD_ONLY" >| "$T/engine-child-masked.sh"
  gate_check_denylist "$T/rules-export" "$T/engine-child-masked.sh" || status=1
  return "$status"
}

set +o noclobber 2>/dev/null
SHIPPED=("$REPO/install.sh" "$REPO/uninstall.sh" "$DEMO/serve.sh" "$DEMO/hello-api.sh" "$DEMO/docs-site.sh" "$DEMO/add-greeting.sh")

out=$(gate_all "$STACK_UP" "${SHIPPED[@]}" 2>&1)
status=$?
testing_baseline "static rules over the shipped code" "$status" "$out"
[ "$status" = 0 ] || printf '%s\n' "$out"

engine_text=$(cat "$STACK_UP")
lint=$(gate_lint_function_columns "$engine_text")
testing_check "every engine function is defined at column 0 and closed there" "" "$lint"
for needle in 'kill -0 "$1"' 'kill "-$1" -- "-$2"' 'kill "-$1" "$2"'; do
  case $needle in
    *-0*) fn=su_alive ;;
    *--*) fn=su_signal_group ;;
    *) fn=su_signal_launch ;;
  esac
  result=$(gate_count_inside_function "$engine_text" "$needle" "$fn")
  testing_check "the only [$needle] is inside $fn" "" "$result"
done
result=$(gate_count_inside_function "$engine_text" 'su_signal_launch TERM "$SU_PID"' su_launch_service)
testing_check "su_signal_launch is used once, right after a launch" "" "$result"
body=$(gate_function_body "$engine_text" su_stop_group)
testing_check "a group is proven ours before TERM" "" "$(gate_order_in_function "$body" 'su_group_is_ours "$pgid" "$token"' 'su_signal_group TERM "$pgid"')"
testing_check "and proven again before KILL" "" "$(gate_order_in_function "$(printf '%s\n' "$body" | sed -n '/su_wait_group_gone "$pgid" "$grace"/,$p')" 'su_group_is_ours "$pgid" "$token"' 'su_signal_group KILL "$pgid"')"
body=$(gate_function_body "$engine_text" su_mode_up)
testing_check "preflight runs before any stage starts" "" "$(gate_order_in_function "$body" 'su_port_preflight "$i" "$port"' 'su_run_stage "$stage" "$SU_ORDER"')"
body=$(gate_function_body "$engine_text" su_launch_service)
testing_check "a launch that could not be recorded gets KILL only while the kernel has its group" 1 "$(printf '%s\n' "$body" | LC_ALL=C grep -c -F '! su_group_exists "$SU_PID" || su_signal_group KILL "$SU_PID"')"
body=$(gate_function_body "$engine_text" su_check_interrupted)
testing_check "an interrupted --check sends KILL only while the kernel has the probe group" 1 "$(printf '%s\n' "$body" | LC_ALL=C grep -c -F '! su_group_exists "$pgid" || su_signal_group KILL "$pgid"')"
testing_check "an interrupted --check sends TERM only while the probe's leader answers kill -0" 1 "$(printf '%s\n' "$body" | LC_ALL=C grep -c -F 'if [ -n "$pgid" ] && su_alive "$pgid"; then')"
body=$(gate_function_body "$engine_text" su_run_env_entry)
testing_check "control: the provider parser reads its output through a pipe" 1 "$(printf '%s\n' "$body" | LC_ALL=C grep -c -F "done < <(printf '%s\\n' \"\$output\")")"
testing_check "env provider output needs no temporary file (no here-document)" 0 "$(printf '%s\n' "$body" | LC_ALL=C grep -c '<<')"

docs=()
while IFS= read -r doc; do
  docs[${#docs[@]}]=$doc
done <<EOF
$(find "$REPO" -name '*.md' ! -path '*/.git/*' | LC_ALL=C sort)
EOF
out=$(gate_check_denylist "$DOC_RULES" "${docs[@]}" 2>&1)
testing_check "docs: no unscoped destroy recipe or pattern kill" "0: " "$?: $out"
out=$(/bin/bash "$STACK_UP" --config "$DEMO/stack.conf" --print-paths 2>&1)
out=$(printf '%s\n' "$out" | gate_check_denylist "$DOC_RULES" 2>&1)
testing_check "--print-paths output passes the docs rules" "0: " "$?: $out"

nonascii=$(cd "$REPO" && LC_ALL=C find . -type f ! -path './.git/*' ! -name '*.png' -exec grep -l '[^[:print:][:space:]]' {} + 2>/dev/null)
testing_check "every text file is ASCII" "" "$nonascii"
notpng=$(cd "$REPO" && find . -type f ! -path './.git/*' -name '*.png' | while IFS= read -r png; do
  [ "$(head -c 8 "$png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || printf '%s\n' "$png"
done)
testing_check "every .png file is a PNG image" "" "$notpng"

probe() {
  local label=$1 pattern=$2 target=$3 script=$4 mutant=$T/probe-engine.sh status
  cp "$STACK_UP" "$mutant"
  case $target in
    engine) sed -i '' -e "$script" "$mutant" ;;
  esac
  out=$(gate_all "$mutant" "${SHIPPED[@]}" 2>&1)
  status=$?
  testing_expect_fail "$label" "status=$status $out" "$pattern"
}
probe "a pattern kill added to --stop" 'DENY pattern-kill' engine '/^su_mode_stop() {/a\
  pkill -f stack-up
'
probe "a bare kill outside the signal helpers" 'DENY kill ' engine '/^su_mode_stop() {/a\
  kill -TERM "$pid"
'
probe "a parent lookup" 'DENY parent-pid' engine '/^su_stop_group() {/a\
  local parent=$PPID
'
probe "a ps identity lookup" 'DENY ps-lookup' engine '/^su_group_is_ours() {/a\
  ps -o lstart= -p "$1"
'
probe "an unscoped volume removal" 'DENY volume-rm' engine '/^su_mode_print_paths() {/a\
  docker volume rm $(docker volume ls -q)
'
probe "a volume-deleting down" 'DENY down-volumes' engine '/^su_mode_stop() {/a\
  su_compose_args down -v
'
probe "a provider value exported in the engine" 'DENY dynamic-export' engine '/^su_run_env_entry() {/a\
  export "$line"
'
probe "an unquoted dynamic export in the engine" 'DENY dynamic-export' engine '/^su_run_env_entry() {/a\
  export $line
'
probe "a dynamic declare -x in the engine" 'DENY dynamic-export' engine '/^su_run_env_entry() {/a\
  declare -x "$line"
'
probe "a pattern kill inside a signal helper" 'DENY pattern-kill' engine '/^su_signal_group() {/a\
  pkill -f stack-up
'
probe "a kill inside the child's environment function" 'DENY kill ' engine '/^su_exec_child() {/a\
  kill -TERM "$1"
'
probe "a ps parent lookup inside the child's environment function" 'DENY (ps-lookup|parent-pid)' engine '/^su_exec_child() {/a\
  ps -o ppid= -p "$1"
'
probe "a dynamic export inside a signal helper" 'DENY dynamic-export' engine '/^su_signal_group() {/a\
  export "$2"
'
probe "a backslash-escaped kill" 'DENY kill ' engine '/^su_mode_stop() {/a\
  \\kill -TERM "$pid"
'
probe "an export with -- before the name" 'DENY dynamic-export' engine '/^su_run_env_entry() {/a\
  export -- "$line"
'

mutant_text=$(printf '%s\n' "$engine_text" | sed 's/  su_group_is_ours "$pgid" "$token" || {/  true || {/; /^su_stop_group() {/,/^}/{/if ! su_group_is_ours "$pgid" "$token"; then/s/.*/  if false; then/;/^  su_group_is_ours "$pgid" "$token"$/s/.*/  true/;}')
body=$(gate_function_body "$mutant_text" su_stop_group)
testing_expect_fail "TERM without the ownership proof" "$(gate_order_in_function "$body" 'su_group_is_ours "$pgid" "$token"' 'su_signal_group TERM "$pgid"')" 'missing|comes after'

printf 'see docs: docker volume rm $(docker volume ls -q)\n' >| "$T/bad-doc.md"
out=$(gate_check_denylist "$DOC_RULES" "$T/bad-doc.md" 2>&1)
testing_expect_fail "an unscoped recipe in a doc" "$out" 'DENY volume-rm'

testing_verdict
