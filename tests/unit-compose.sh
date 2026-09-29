#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-compose.sh - [compose] entries against a shim container engine that
# records every call (tests never run a real engine). Proves the commands are
# project-scoped (-p NAME and every -f file), that --stop uses stop and never
# down, that the container check is scoped to the project, that the engine is
# checked and started only as configured, that STACK_COMPOSE reaches jobs,
# and that every engine call runs in the stack root.
# A project folder with a space in its path keeps each file one argument, a
# failed container listing is never read as "nothing running", and an
# engine_check that times out during --stop makes it exit 1.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

CALLS=$T/engine-calls.log
ARGV=$T/engine-argv.log
ENGINE_STATE=$T/engine
mkdir -p "$ENGINE_STATE"
: >> "$CALLS"
cat >> "$T/shims/docker" <<SHIM
#!/bin/bash
printf '%s\n' "docker \$*" >> "$CALLS"
printf '[%s]' "\$@" >> "$ARGV"
printf '\n' >> "$ARGV"
pwd >> "$T/engine-cwd.log"
state=$ENGINE_STATE
[ "\$1" = info ] && { [ -e "\$state/up" ]; exit; }
[ -e "\$state/up" ] || { echo "engine is not running" >&2; exit 1; }
[ "\$1" = compose ] || exit 0
shift
while [ "\$#" -gt 0 ]; do
  case \$1 in
    -p|-f) shift 2 ;;
    *) break ;;
  esac
done
cmd=\$1
shift
[ "\$cmd" = ps ] && [ -n "\${SHIM_PS_FAIL:-}" ] && exit 14
case \$cmd in
  up) shift; for s in "\$@"; do : > "\$state/\$s"; done ;;
  stop) for s in "\$@"; do rm -f "\$state/\$s"; done ;;
  ps)
    if [ "\$1" = -q ]; then
      for f in "\$state"/*; do case \${f##*/} in up) ;; *) [ -e "\$f" ] && echo "id-\${f##*/}" ;; esac; done
    else
      shift 3
      for s in "\$@"; do [ -e "\$state/\$s" ] && echo "\$s|running|healthy"; done
    fi
    ;;
esac
exit 0
SHIM
chmod +x "$T/shims/docker"

mkdir -p "$T/comp"
printf 'services: {}\n' >> "$T/comp/compose.yaml"
write_conf "$T/comp/stack.conf" <<'CONF'
[stack]
name = comp
stages = infra build
keep_awake = off
default_select = all
compose_files = compose.yaml
engine_start = touch "$ENGINE_UP_MARKER"
engine_timeout = 10

[compose infra]
services = cache queue
ready_timeout = 10

[job migrate]
stage = build
always = yes
depends_on = infra
run = printf '%s' "$STACK_COMPOSE" > "$STACK_STATE/compose.seen"
CONF
STATE=$(state_of comp)
export ENGINE_UP_MARKER=$ENGINE_STATE/up

OUT=$(cd "$T" && /bin/bash "$STACK_UP" --config "$T/comp/stack.conf" --yes </dev/null 2>&1)
STATUS=$?
check_status "compose up, starting the engine first" 0
testing_check "control: the engine calls were recorded" yes "$( [ -s "$T/engine-cwd.log" ] && echo yes || echo no)"
testing_check "every engine call runs in the stack root, not the caller's folder" "" "$(LC_ALL=C grep -v -x -F "$T/comp" "$T/engine-cwd.log")"
check_match "the engine was checked and then started" 'starting the container engine: touch' "$OUT"
check_match "compose up is project-scoped with every file" "^docker compose -p comp -f $T/comp/compose.yaml up -d cache queue\$" "$(cat "$CALLS")"
check_match "the entry is ready" 'compose infra: cache queue ready' "$OUT"
testing_check "jobs receive STACK_COMPOSE" "$T/comp/compose.yaml" "$(cat "$STATE/compose.seen")"

su_run --config "$T/comp/stack.conf" --stop
check_status "compose stop" 0
check_match "stop is project-scoped and uses stop" "^docker compose -p comp -f $T/comp/compose.yaml stop cache queue\$" "$(cat "$CALLS")"
check_match "the container check is scoped to the project" "^docker compose -p comp -f $T/comp/compose.yaml ps -q --status running\$" "$(cat "$CALLS")"
check_match "stop reports no project container running" 'no container of compose project comp is running' "$OUT"
check_no_match "no call ever removes containers or volumes" '( down| rm |volume|prune)' "$(cat "$CALLS")"

rm -f "$ENGINE_UP_MARKER"
: > "$T/stop-while-down.log"
su_run --config "$T/comp/stack.conf" --stop
check_status "stop while the engine is down" 0
check_match "stop says nothing can be running" 'the container engine is not running, so no compose service of comp is running' "$OUT"

write_conf "$T/comp2/stack.conf" <<'CONF'
[stack]
name = comp2
stages = infra
keep_awake = off
default_select = all

[compose infra]
always = yes
services = cache
CONF
su_run --config "$T/comp2/stack.conf" --yes
check_status "engine down and no engine_start" 1
check_match "the hint says to start it" 'the container engine is not running and \[stack\] engine_start is empty; start it yourself, then run again' "$OUT"

su_run --config "$T/comp/stack.conf" --print-paths
check_status "--print-paths with compose entries" 0
check_line "the removal note claims only what stack-up never asks compose to do" "stack-up never asks compose to remove containers or volumes; a start's compose up -d still recreates a container whose configuration or image changed. To remove this project's by hand:" "$OUT"
check_no_match "the removal note never says stack-up never deletes" 'never deletes' "$OUT"
check_match "the down command is printed without -v" "^  docker compose -p comp -f $T/comp/compose.yaml down\$" "$OUT"
check_match "the volume command is filtered by project" '^  docker volume rm \$\(docker volume ls -q --filter label=com\.docker\.compose\.project=comp\)$' "$OUT"
testing_check "--print-paths ran no engine command" 0 "$(LC_ALL=C grep -c 'volume\| down' "$CALLS")"

# A project folder with a space in its path: every compose file stays one
# argument in every call, and the printed down line parses the same way.
SPACED="$T/My Projects/shop"
mkdir -p "$SPACED"
printf 'services: {}\n' >> "$SPACED/compose.yaml"
write_conf "$SPACED/stack.conf" <<'CONF'
[stack]
name = shop
stages = infra
keep_awake = off
default_select = all
compose_files = compose.yaml

[compose datastores]
always = yes
services = db
ready_timeout = 10
CONF
: > "$ENGINE_UP_MARKER"
su_run --config "$SPACED/stack.conf" --yes
check_status "compose up from a folder with a space in its path" 0
check_line "up passes the compose file as one argument" "[compose][-p][shop][-f][$SPACED/compose.yaml][up][-d][db]" "$(cat "$ARGV")"
su_run --config "$SPACED/stack.conf" --stop
check_status "compose stop from a folder with a space in its path" 0
check_line "stop passes the compose file as one argument" "[compose][-p][shop][-f][$SPACED/compose.yaml][stop][db]" "$(cat "$ARGV")"
check_line "the container check passes it as one argument" "[compose][-p][shop][-f][$SPACED/compose.yaml][ps][-q][--status][running]" "$(cat "$ARGV")"
su_run --config "$SPACED/stack.conf" --print-paths
check_status "--print-paths from a folder with a space in its path" 0
down=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  \(docker compose -p shop .*\)$/\1/p')
testing_check "the printed down line parses into one -f argument" "[docker][compose][-p][shop][-f][$SPACED/compose.yaml][down]" "$(/bin/bash -c "printf '[%s]' $down")"

# A container listing that fails is not "nothing is running".
su_run --config "$SPACED/stack.conf" --yes
SHIM_PS_FAIL=1 su_run --config "$SPACED/stack.conf" --stop
check_status "--stop when the container listing fails" 1
check_match "it says the containers could not be checked" 'listing the containers of compose project shop failed \(exit 14\), so they could not be checked' "$OUT"
check_no_match "it never says no container is running" 'no container of compose project shop is running' "$OUT"
su_run --config "$SPACED/stack.conf" --stop
check_status "--stop with a working listing" 0

# An engine_check that outlives its 30 s deadline during --stop leaves the
# compose services unchecked, so --stop exits 1.
write_conf "$T/slow-engine/stack.conf" <<'CONF'
[stack]
name = slow-engine
stages = infra
keep_awake = off
default_select = all
engine_check = sleep 40

[compose infra]
services = cache
CONF
su_run --config "$T/slow-engine/stack.conf" --stop
check_status "--stop when engine_check times out" 1
check_match "it says the engine could not be checked" 'engine_check did not finish within 30s, so the compose services of slow-engine could not be checked or stopped' "$OUT"
check_no_match "it never says everything is down" 'Everything is down|Everything this stack recorded is down' "$OUT"

# A start that stops early after compose up says the containers may still be
# running and prints the stop command, which then asks compose to stop them.
write_conf "$T/abort-comp/stack.conf" <<'CONF'
[stack]
name = abortcomp
stages = infra build
keep_awake = off
default_select = all

[compose db]
services = pg
ready = running

[job migrate]
stage = build
depends_on = db
pick = yes
run = exit 3
CONF
: > "$ENGINE_STATE/up"
su_run --config "$T/abort-comp/stack.conf" --yes
check_status "a start that stops after compose up" 1
check_match "it ends STOPPED" '^  STOPPED  migrate failed' "$OUT"
check_match "it says the containers may still be running" '^  Compose services this run started may still be running\.$' "$OUT"
check_match "it prints the stop command" '^  Stop it with  .* --config .* --stop$' "$OUT"
: > "$CALLS"
su_run --config "$T/abort-comp/stack.conf" --stop
check_status "that stop command" 0
check_match "it asks compose to stop pg" 'docker compose -p abortcomp .*stop pg' "$(cat "$CALLS")"

# A start stops the compose services of an option that is off with when_off =
# stop, when the engine answers engine_check.
write_conf "$T/off-up/stack.conf" <<'CONF'
[stack]
name = offup
stages = infra
keep_awake = off
default_select = all

[option db]
question = Start the database?
default = no
when_off = stop

[compose pg]
services = pg
option = db
CONF
: > "$ENGINE_STATE/up"
: > "$CALLS"
su_run --config "$T/off-up/stack.conf" --yes
check_status "a start with the option off and the engine up" 0
check_match "it says it stopped the option's compose services" 'option db is off: stopped compose pg' "$OUT"
check_match "it asked compose to stop pg" 'docker compose -p offup .*stop pg' "$(cat "$CALLS")"

# The same start, when the engine does not answer engine_check, sends no
# compose stop and says the stop was skipped.
write_conf "$T/off-engine/stack.conf" <<'CONF'
[stack]
name = off-engine
stages = infra
keep_awake = off
default_select = all
engine_check = false

[option db]
question = Start the database?
default = no
when_off = stop

[compose pg]
services = pg
option = db
CONF
: > "$CALLS"
su_run --config "$T/off-engine/stack.conf" --yes
check_status "a start with the option off and the engine down" 0
check_no_match "no compose stop was sent" 'compose .*stop' "$(cat "$CALLS")"
check_match "it says the compose stop was skipped" 'option db is off, but the container engine did not answer engine_check, so compose pg was not stopped' "$OUT"

testing_verdict
