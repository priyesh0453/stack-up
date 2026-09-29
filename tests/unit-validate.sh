#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # single-quoted $ is literal config or shell text on purpose
# unit-validate.sh - the validator refuses bad configs with file:line errors
# and exit 2 before anything runs; the CLI refuses bad flags with exit 2. A
# state or log folder may not be the project root, HOME or a folder above
# either, and only a state folder stack-up created gets mode 700. --stop on a
# stack that never ran here writes nothing. A required check must run before
# its dependent's stage, and a gate no later than the check it gates. The
# printed rm line is one shell operand. A start checks --select, --with and
# --without before it creates anything, and the other modes refuse them. A
# state path with a vertical bar, a relative HOME, a byte-order mark and
# ${HOME} while HOME is unset each exit 2 with their own message, and
# env_file values are read literally.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

n=0
expect_invalid() {
  local label=$1 where=$2 message=$3 file
  n=$((n + 1))
  file=$T/invalid-$n/stack.conf
  write_conf "$file"
  su_run --config "$file" --print-config
  check_status "$label" 2
  if [ -n "$where" ]; then where=":$where"; fi
  check_match "$label: error names file:line and the problem" "stack\\.conf$where: .*$message" "$OUT"
  testing_check "$label: no state folder was created" no "$( [ -e "$XDG_STATE_HOME/stack-up" ] && echo yes || echo no)"
}

expect_invalid "typo in a key" 5 'unknown key dependson in \[service web\]' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
dependson = db
CONF

expect_invalid "unknown section kind" 3 'unknown section kind servce' <<'CONF'
[stack]
name = t
[servce web]
start = sleep 60
CONF

expect_invalid "ready = port without a port (no port-0 services)" 5 'ready = port needs a port' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready = port
CONF

expect_invalid "depends_on an unknown entry" 3 'depends on db, which is not a declared entry' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
depends_on = db
CONF

expect_invalid "dependency cycle" 5 'part of a dependency cycle' <<'CONF'
[stack]
name = t
[service a]
start = sleep 60
depends_on = b
[service b]
start = sleep 60
depends_on = a
CONF

expect_invalid "dependency in a later stage" 4 'depends on late, which runs in the later stage web' <<'CONF'
[stack]
name = t
stages = services web
[service early]
start = sleep 60
depends_on = late
[service late]
stage = web
start = sleep 60
CONF

expect_invalid "one namespace for entry names" 5 'the name web is already used by \[service web\]' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
[job web]
stage = services
run = true
CONF

expect_invalid "port below 1024" 5 'port in \[service web\] must be a whole number from 1024 to 65535' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
port = 80
CONF

expect_invalid "signature owner that does not exist" 7 'owner nobody is not a built-in owner' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
[signature s1]
match = boom
owner = nobody
explain = something
CONF

expect_invalid "option that is not declared" 5 'option extras is not declared' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
option = extras
CONF

expect_invalid "env_from naming a service" 7 'env_from names db, which is a service' <<'CONF'
[stack]
name = t
[service db]
start = sleep 60
[service web]
start = sleep 60
env_from = db
CONF

expect_invalid "repair without target or backup" 8 'has a repair but no target or backup' <<'CONF'
[stack]
name = t
stages = prepare services
[service web]
start = sleep 60
[check c]
probe = false
repair = true
CONF

expect_invalid "compose takes no env" 5 'env is not used by \[compose db\]' <<'CONF'
[stack]
name = t
[compose db]
services = db
env = EXTRA=1
CONF

expect_invalid "compose takes no env_file" 5 'env_file is not used by \[compose db\]' <<'CONF'
[stack]
name = t
[compose db]
services = db
env_file = db.env
CONF

expect_invalid "compose takes no env_from" 7 'env_from is not used by \[compose db\]' <<'CONF'
[stack]
name = t
[env secrets]
run = echo T=1
[compose db]
services = db
env_from = secrets
CONF

expect_invalid "PORT in a job path" 5 'log in \[job seed\] uses \$\{PORT\}, but only a service with a port has one' <<'CONF'
[stack]
name = t
[job seed]
run = true
log = ${STACK_ROOT}/seed-${PORT}.log
CONF

expect_invalid "PORT in a path of a service without a port" 5 'dir in \[service web\] uses \$\{PORT\}' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
dir = ${STACK_ROOT}/wd-${PORT}
CONF

expect_invalid "PORT in a stack path" 3 'log_dir uses \$\{PORT\}' <<'CONF'
[stack]
name = t
log_dir = ${STACK_ROOT}/logs-${PORT}
[service web]
start = sleep 60
CONF

expect_invalid "PORT in a check target" 9 'target in \[check c\] uses \$\{PORT\}' <<'CONF'
[stack]
name = t
stages = prepare services
[service web]
start = sleep 60
[check c]
probe = false
repair = true
target = ${STACK_ROOT}/settings-${PORT}.conf
CONF

expect_invalid "PORT in the ready value of a service without a port" 5 'ready in \[service web\] uses \$\{PORT\}' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready = http http://127.0.0.1:${PORT}/health 200
CONF

expect_invalid "an unknown placeholder in a ready value" 6 'ready in \[service web\] has an unknown placeholder' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
port = 18599
ready = http http://127.0.0.1:${FOO}/ 200
CONF

expect_invalid "an empty root" 3 'root is empty' <<'CONF'
[stack]
name = t
root =
[service web]
start = sleep 60
CONF

expect_invalid "an empty compose_files" 3 'compose_files is empty' <<'CONF'
[stack]
name = t
compose_files =
[service web]
start = sleep 60
CONF

expect_invalid "an empty check target" 9 'target in \[check c\] is empty' <<'CONF'
[stack]
name = t
stages = prepare services
[service web]
start = sleep 60
[check c]
probe = false
repair = true
target =
CONF

expect_invalid "an empty compose services list" 4 'services in \[compose db\] is empty' <<'CONF'
[stack]
name = t
[compose db]
services =
CONF

expect_invalid "a compose services list of only blanks" 4 'services in \[compose db\] is empty' <<'CONF'
[stack]
name = t
[compose db]
services =   	 
CONF

# From a folder whose only file would pass as a service name, so an unguarded
# wildcard would expand to it and validate.
mkdir -p "$T/glob-cwd"
: > "$T/glob-cwd/db"
cd "$T/glob-cwd" || exit 1
expect_invalid "a compose services list with a wildcard" 4 'services in \[compose db\] must be a space-separated list of compose service names' <<'CONF'
[stack]
name = t
[compose db]
services = *
CONF
cd - >/dev/null || exit 1

expect_invalid "a compose services list with a question mark" 4 'services in \[compose db\] must be a space-separated list of compose service names' <<'CONF'
[stack]
name = t
[compose db]
services = db?
CONF

# Every command-valued key refuses a blank value, because bash -c '' succeeds
# and would pass a probe, a precheck or a backup that never ran.
blank_command() {
  local label=$1 key=$2 message=$3 config=$4 line
  line=$(printf '%s\n' "$config" | LC_ALL=C grep -n -E "^$key =" | cut -d: -f1)
  expect_invalid "$label" "$line" "$message" <<<"$config"
}
w='[service web]
start = sleep 60'
blank_command "a blank require" require 'require in \[stack\] must be a command, not blank' "[stack]
name = t
require =
$w"
blank_command "a blank engine_check" engine_check 'engine_check in \[stack\] must be a command, not blank' "[stack]
name = t
engine_check =
$w"
blank_command "a blank service start" start 'start in \[service web\] must be a command, not blank' "[stack]
name = t
[service web]
start ="
blank_command "a blank requires" requires 'requires in \[service web\] must be a command, not blank' "[stack]
name = t
$w
requires ="
blank_command "a blank precheck" precheck 'precheck in \[service web\] must be a command, not blank' "[stack]
name = t
$w
precheck ="
blank_command "a blank known_defect_check" known_defect_check 'known_defect_check in \[service web\] must be a command, not blank' "[stack]
name = t
$w
known_defect_check ="
blank_command "a blank build" build 'build in \[service web\] must be a command, not blank' "[stack]
name = t
$w
build ="
blank_command "a blank job run" run 'run in \[job j\] must be a command, not blank' "[stack]
name = t
[job j]
run ="
blank_command "a blank run_if" run_if 'run_if in \[job j\] must be a command, not blank' "[stack]
name = t
[job j]
run = true
run_if ="
blank_command "a blank report" report 'report in \[job j\] must be a command, not blank' "[stack]
name = t
[job j]
run = true
report ="
blank_command "a blank env run" run 'run in \[env e\] must be a command, not blank' "[stack]
name = t
[env e]
run ="
blank_command "a blank probe" probe 'probe in \[check c\] must be a command, not blank' "[stack]
name = t
stages = prepare services
$w
[check c]
probe ="
blank_command "a blank repair" repair 'repair in \[check c\] must be a command, not blank' "[stack]
name = t
stages = prepare services
$w
[check c]
probe = true
repair ="
blank_command "a blank backup" backup 'backup in \[check c\] must be a command, not blank' "[stack]
name = t
stages = prepare services
$w
[check c]
probe = true
repair = true
backup ="
blank_command "a blank heal run" run 'run in \[heal h\] must be a command, not blank' "[stack]
name = t
$w
[heal h]
for = web
when_log = stale
run ="
blank_command "a blank heal when" when 'when in \[heal h\] must be a command, not blank' "[stack]
name = t
$w
[heal h]
for = web
when =
run = true"
blank_command "a blank known_defect" known_defect 'known_defect in \[service web\] must be a line of text, not blank' "[stack]
name = t
$w
known_defect ="
blank_command "a blank signature explain" explain 'explain in \[signature s\] must be a line of text, not blank' "[stack]
name = t
$w
[signature s]
match = boom
owner = o
explain =
[owner o]
label = O"
blank_command "a blank owner label" label 'label in \[owner o\] must be a line of text, not blank' "[stack]
name = t
$w
[signature s]
match = boom
owner = o
explain = it broke
[owner o]
label ="
blank_command "a blank option question" question 'question in \[option o\] must be a line of text, not blank' "[stack]
name = t
[option o]
question =
$w"

expect_invalid "an empty ready value" 4 'ready in \[service web\] is empty' <<'CONF'
[stack]
name = t
[service web]
ready =
start = sleep 60
CONF

expect_invalid "state_dir naming itself" 3 'state_dir cannot use \$\{STACK_STATE\}' <<'CONF'
[stack]
name = t
state_dir = ${STACK_STATE}/own-state
[service web]
start = sleep 60
CONF

expect_invalid "root naming the state folder" 3 'root cannot use \$\{STACK_STATE\}' <<'CONF'
[stack]
name = t
root = ${STACK_STATE}/r
[service web]
start = sleep 60
CONF

expect_invalid "an empty state_dir" 3 'state_dir is empty' <<'CONF'
[stack]
name = t
state_dir =
[service web]
start = sleep 60
CONF

expect_invalid "an empty env_file" 5 'env_file in \[job seed\] is empty' <<'CONF'
[stack]
name = t
[job seed]
run = true
env_file =
CONF

expect_invalid "stage that is not in stages" 5 'runs in stage later, which is not in \[stack\] stages' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
stage = later
CONF

expect_invalid "a config with no entries" '' 'declares no \[service\], \[job\], \[compose\] or \[env\] entry' <<'CONF'
[stack]
name = t
CONF

expect_invalid "default_select naming nothing" 3 'default_select has "nosuch"' <<'CONF'
[stack]
name = t
default_select = nosuch
[service web]
start = sleep 60
CONF

expect_invalid "gate declared below its check" 6 'gate b must be a \[check\] declared above' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
[check a]
gate = b
probe = true
[check b]
probe = true
CONF

expect_invalid "menu that lists nothing" 3 'menu front lists no pickable entry' <<'CONF'
[stack]
name = t
menus = front
[service web]
start = sleep 60
CONF

expect_invalid "bad section name" 3 'bad name "Web" for \[service\]' <<'CONF'
[stack]
name = t
[service Web]
start = sleep 60
CONF

expect_invalid "a 41-character name" 3 'bad name "a[0-9]{40}" for \[service\]' <<'CONF'
[stack]
name = t
[service a0123456789012345678901234567890123456789]
start = sleep 60
CONF

expect_invalid "a name that starts with -" 3 'bad name "-web" for \[service\]' <<'CONF'
[stack]
name = t
[service -web]
start = sleep 60
CONF

expect_invalid "unknown placeholder in a path" 4 'dir in \[service web\] has an unknown placeholder' <<'CONF'
[stack]
name = t
[service web]
dir = ${SRC_DIR}/web
start = sleep 60
CONF

expect_invalid "bad ready form" 4 'ready must be port, http URL \[STATUS\], cmd COMMAND or alive SECONDS' <<'CONF'
[stack]
name = t
[service web]
ready = listening
start = sleep 60
CONF

expect_invalid "capital letters in a group name" 5 'groups in \[service web\] must be a space-separated list of lowercase names' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
groups = Front
CONF

expect_invalid "an env entry that is not KEY=VALUE" 5 'env in \[service web\] must be KEY=VALUE' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
env = 1BAD=x
CONF

expect_invalid "a smoke URL that is not http" 3 'smoke_url in \[stack\] must be a URL that starts with http:// or https://' <<'CONF'
[stack]
name = t
smoke_url = ftp://127.0.0.1/
[service web]
start = sleep 60
CONF

expect_invalid "a blank compose_command" 3 'compose_command in \[stack\] must be a command, not blank, got ""' <<'CONF'
[stack]
name = t
compose_command =
[service web]
start = sleep 60
CONF

expect_invalid "an unknown placeholder in compose_files" 3 'compose_files has an unknown placeholder' <<'CONF'
[stack]
name = t
compose_files = ${REPO}/compose.yaml
[service web]
start = sleep 60
CONF

expect_invalid "state_dir is the project root" 3 'state_dir is .*, which is .* or a folder above it' <<'CONF'
[stack]
name = t
state_dir = ${STACK_ROOT}
[service web]
start = sleep 60
CONF

expect_invalid "state_dir is HOME" 3 'state_dir is .*, which is .* or a folder above it' <<'CONF'
[stack]
name = t
state_dir = ${HOME}
[service web]
start = sleep 60
CONF

expect_invalid "state_dir above the project root" 3 'state_dir is .*, which is .* or a folder above it' <<'CONF'
[stack]
name = t
state_dir = ${STACK_ROOT}/..
[service web]
start = sleep 60
CONF

expect_invalid "log_dir is the file system root" 3 'log_dir is /, which is .* or a folder above it' <<'CONF'
[stack]
name = t
log_dir = /
[service web]
start = sleep 60
CONF

expect_invalid "a required check that runs after its dependent starts" 8 '\[check must\] runs at the end of stage services, but its dependent web starts in stage services' <<'CONF'
[stack]
name = t
stages = prepare services
[service web]
stage = services
start = sleep 60
[check must]
stage = services
dependent = web
probe = true
CONF

for pattern in 'c*.yaml' 'c?.yaml' 'c[12].yaml'; do
  expect_invalid "compose_files with the pattern $pattern" 3 'compose_files names a pattern' <<CONF
[stack]
name = t
compose_files = $pattern
[compose db]
services = db
CONF
done

expect_invalid "a key given twice" 5 'duplicate key start in \[service web\], first at line 4' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
start = sleep 61
CONF

expect_invalid "a missing required key" 3 '\[service web\] is missing required key start' <<'CONF'
[stack]
name = t
[service web]
port = 8080
CONF

expect_invalid "a second [stack]" 3 'only one \[stack\] section is allowed' <<'CONF'
[stack]
name = t
[stack]
name = u
CONF

expect_invalid "no [stack] section" '' 'missing required section \[stack\]' <<'CONF'
[service web]
start = sleep 60
CONF

expect_invalid "a stage named twice" 3 'stages names prep twice' <<'CONF'
[stack]
name = t
stages = prep services prep
[job seed]
stage = prep
run = true
CONF

expect_invalid "parallel_stages naming a stage twice" 4 'parallel_stages names services twice' <<'CONF'
[stack]
name = t
stages = prep services
parallel_stages = services services
[job seed]
stage = prep
run = true
CONF

expect_invalid "a gate in a later stage" 12 'gate g runs at the end of stage b, after \[check c\] in stage a' <<'CONF'
[stack]
name = t
stages = a b
[job j]
stage = a
run = true
[check g]
stage = b
probe = true
[check c]
stage = a
gate = g
probe = true
CONF

expect_invalid "an open_url that is not a URL" 3 'open_url in \[stack\] must be a URL that starts with http:// or https://' <<'CONF'
[stack]
name = t
open_url = not a url
[service web]
start = sleep 60
CONF

expect_invalid "a blank open_url" 3 'open_url in \[stack\] must be a URL that starts with http:// or https://' <<'CONF'
[stack]
name = t
open_url =
[service web]
start = sleep 60
CONF

expect_invalid "a service url that is not a URL" 5 'url in \[service web\] must be a URL' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
url = not a url
CONF

expect_invalid "alive longer than ready_timeout" 5 'ready = alive 3 needs a ready_timeout longer than 3, got 1' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready = alive 3
ready_timeout = 1
CONF

expect_invalid "alive equal to ready_timeout" 5 'ready = alive 3 needs a ready_timeout longer than 3, got 3' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready = alive 3
ready_timeout = 3
CONF

expect_invalid "a ready_timeout shorter than the default alive 5" 5 'ready_timeout 2 is not longer than the default ready = alive 5' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready_timeout = 2
CONF

expect_invalid "a ready_timeout equal to the default alive 5" 5 'ready_timeout 5 is not longer than the default ready = alive 5' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
ready_timeout = 5
CONF

expect_invalid "port_env without a port" 4 'port_env in \[service web\] needs a port' <<'CONF'
[stack]
name = t
[service web]
port_env = API_PORT
start = sleep 60
CONF

expect_invalid "a repair on an advisory check" 8 '\[check c\] is advisory, so its repair would never run' <<'CONF'
[stack]
name = t
[service web]
start = sleep 60
[check c]
level = advisory
probe = true
repair = true
backup = true
CONF

expect_invalid "an unbraced variable in a path" 3 'state_dir has a \$ that does not start a placeholder' <<'CONF'
[stack]
name = t
state_dir = $HOME/.stack-state
[service web]
start = sleep 60
CONF

blank_command "a blank default_select" default_select 'default_select in \[stack\] must be a line of text, not blank' "[stack]
name = t
default_select =
$w"
blank_command "a blank needs_hint" needs_hint 'needs_hint in \[service web\] must be a line of text, not blank' "[stack]
name = t
$w
needs_hint ="
blank_command "a blank precheck_hint" precheck_hint 'precheck_hint in \[service web\] must be a line of text, not blank' "[stack]
name = t
$w
precheck_hint ="
blank_command "a blank owner advice" advice 'advice in \[owner o\] must be a line of text, not blank' "[stack]
name = t
$w
[owner o]
label = O
advice ="

# A byte-order mark would hide the [stack] header behind three bytes.
mkdir -p "$T/bom"
printf '\357\273\277[stack]\nname = t\n[service web]\nstart = sleep 60\n' >| "$T/bom/stack.conf"
su_run --config "$T/bom/stack.conf" --print-config
check_status "a config that starts with a byte-order mark" 2
check_match "it names the byte-order mark" 'starts with a UTF-8 byte-order mark' "$OUT"

# With HOME unset, ${HOME} is a documented placeholder with no value.
write_conf "$T/no-home/stack.conf" <<'CONF'
[stack]
name = t
log_dir = ${HOME}/logs
[service web]
start = sleep 60
CONF
OUT=$(/usr/bin/env -u HOME XDG_STATE_HOME="$T/state" /bin/bash "$STACK_UP" --config "$T/no-home/stack.conf" --print-config </dev/null 2>&1)
STATUS=$?
check_status "\${HOME} in a path while HOME is unset" 2
check_match "it says HOME is not set" 'log_dir uses \$\{HOME\}, but HOME is not set' "$OUT"

# A relative --config or engine path whose first folder starts with - is read
# as a path, not as a flag.
mkdir -p "$T/-x"
cp "$DEMO/stack.conf" "$T/-x/"
OUT=$(cd "$T" && /bin/bash "$STACK_UP" --config -x/stack.conf --print-config </dev/null 2>&1)
STATUS=$?
check_status "a --config under a folder named -x" 0
check_match "it reads that config" '^stack\|\|name\|demo$' "$OUT"
mkdir -p "$T/-e"
cp -R "$REPO/bin" "$REPO/lib" "$REPO/VERSION" "$T/-e/"
testing_check "an engine path that starts with -" "stack-up $(cat "$REPO/VERSION")" "$(cd "$T" && /bin/bash -- -e/bin/stack-up --version 2>&1)"

file=$T/guard-paths/stack.conf
write_conf "$file" <<'CONF'
[stack]
name = t
state_dir = ${HOME}
[service web]
start = sleep 60
CONF
su_run --config "$file" --print-paths
check_status "--print-paths with state_dir = HOME" 2
check_no_match "--print-paths never offers rm -r of HOME" 'rm -r' "$OUT"

# Every error in a file is reported, not only the first.
file=$T/many/stack.conf
write_conf "$file" <<'CONF'
[stack]
name = t
colour = blue
[service web]
start = sleep 60
port = 99999
CONF
su_run --config "$file" --print-config
check_status "two errors in one file" 2
check_match "first error reported" 'stack\.conf:3: unknown key colour' "$OUT"
check_match "second error reported" 'stack\.conf:6: port in \[service web\]' "$OUT"
check_match "error count stated" 'the config has 2 error\(s\); nothing was started' "$OUT"

su_run --config "$DEMO/stack.conf" --no-such-flag
check_status "unknown flag" 2
check_match "unknown flag is named" 'unknown flag --no-such-flag' "$OUT"

su_run --config "$DEMO/stack.conf" --plan --stop
check_status "two modes at once" 2

su_run --config "$DEMO/stack.conf" --plan --select nosuch
check_status "--select with an unknown name" 2
check_match "--select names the bad token" '"nosuch" matches no pickable entry' "$OUT"

su_run --config "$DEMO/stack.conf" --plan --with nosuch
check_status "--with an unknown option" 2

su_run --config "$DEMO/stack.conf" --plan --with ticker --without ticker
check_status "--with and --without the same option" 2

su_run --config "$DEMO/stack.conf" --select
check_status "--select without a value" 2

su_run --config ""
check_status "--config with an empty value" 2
check_match "--config asks for a path" '--config needs a path, not an empty value' "$OUT"

su_run --config "$DEMO/stack.conf" --root "" --plan
check_status "--root with an empty value" 2
check_match "--root asks for a path" '--root needs a path, not an empty value' "$OUT"

su_run --config "$DEMO/stack.conf" --stop --with ticker
check_status "--stop with --with" 2
check_match "--with is refused outside a start and --plan" 'apply only to a start and --plan' "$OUT"
su_run --config "$DEMO/stack.conf" --clean --select all
check_status "--clean with --select" 2

# A start checks --select, --with and --without against the config before it
# creates anything.
write_conf "$T/cli-start/stack.conf" <<'CONF'
[stack]
name = clistart
keep_awake = off
[option extras]
question = Extras?
[job hello]
stage = prepare
always = yes
run = true
[job pickme]
stage = prepare
pick = yes
run = true
CONF
su_run --config "$T/cli-start/stack.conf" --with nosuch --yes
check_status "a start with --with an unknown option" 2
su_run --config "$T/cli-start/stack.conf" --select nosuch --yes
check_status "a start with --select an unknown name" 2
su_run --config "$T/cli-start/stack.conf" --with extras --without extras --yes
check_status "a start with --with and --without the same option" 2

testing_check "no invalid run created a state folder" no "$( [ -e "$XDG_STATE_HOME/stack-up" ] && echo yes || echo no)"

# A state folder that already exists keeps its mode; a new one gets 700.
mkdir -p "$T/shared-state"
chmod 755 "$T/shared-state"
for target in shared-state new-state; do
  file=$T/mode-$target/stack.conf
  write_conf "$file" <<CONF
[stack]
name = t
state_dir = $T/$target
keep_awake = off
[job hello]
stage = prepare
always = yes
run = true
CONF
  su_run --config "$file" --yes
  check_status "up with state_dir = $target" 0
done
testing_check "an existing state folder keeps its mode" drwxr-xr-x "$(mode_of "$T/shared-state")"
testing_check "a state folder stack-up created is private" drwx------ "$(mode_of "$T/new-state")"

# The printed rm line is exactly one operand, whatever the state path holds:
# pasted unquoted, "Work Projects" would have split into two, and rm -r would
# have reached the unrelated folder Work.
mkdir -p "$T/Work" "$T/Work Projects/app"
printf 'notes\n' >> "$T/Work/notes.txt"
write_conf "$T/Work Projects/app/stack.conf" <<'CONF'
[stack]
name = spaced
state_dir = .stack-state
[service web]
start = sleep 60
CONF
su_run --config "$T/Work Projects/app/stack.conf" --print-paths
check_status "--print-paths with a space in the state folder's path" 0
rm_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  \(rm -r -- .*\)$/\1/p')
testing_check "the rm line parses into one operand, the state folder" "[rm][-r][--][$T/Work Projects/app/.stack-state]" "$(/bin/bash -c "printf '[%s]' $rm_line")"
XDG_STATE_HOME="$T/x y/state" su_run --config "$DEMO/stack.conf" --print-paths
rm_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  \(rm -r -- .*\)$/\1/p')
testing_check "with a space in XDG_STATE_HOME, still one operand" "[rm][-r][--][$T/x y/state/stack-up/demo]" "$(/bin/bash -c "printf '[%s]' $rm_line")"
testing_check "--print-paths created no state folder" no "$( [ -e "$T/Work Projects/app/.stack-state" ] || [ -e "$T/x y" ] && echo yes || echo no)"
# The XDG spec says to ignore a relative XDG_STATE_HOME; kept, the launch
# table would move with the current folder.
mkdir -p "$T/rel-cwd"
OUT=$(cd "$T/rel-cwd" && XDG_STATE_HOME=relstate /bin/bash "$STACK_UP" --config "$DEMO/stack.conf" --print-paths </dev/null 2>&1)
STATUS=$?
check_status "--print-paths with a relative XDG_STATE_HOME" 0
check_line "the state folder falls back to HOME" "  state          $HOME/.local/state/stack-up/demo" "$OUT"
check_no_match "the relative value is not used" 'relstate' "$OUT"
OUT=$(/usr/bin/env -u HOME XDG_STATE_HOME=relstate /bin/bash "$STACK_UP" --config "$DEMO/stack.conf" --print-paths </dev/null 2>&1)
STATUS=$?
check_status "no HOME and a relative XDG_STATE_HOME" 2
check_match "it says the state folder is unknown" '^stack-up: neither XDG_STATE_HOME nor HOME is an absolute path, so the state folder is unknown$' "$OUT"
# A relative HOME would move the state folder with the current folder too.
for mode in --print-paths --stop; do
  OUT=$(cd "$T" && HOME=relhome /usr/bin/env -u XDG_STATE_HOME /bin/bash "$STACK_UP" --config "$DEMO/stack.conf" "$mode" </dev/null 2>&1)
  STATUS=$?
  check_status "$mode with a relative HOME and no XDG_STATE_HOME" 2
  check_match "$mode says the state folder is unknown" '^stack-up: neither XDG_STATE_HOME nor HOME is an absolute path, so the state folder is unknown$' "$OUT"
done
testing_check "a relative HOME created nothing under the current folder" no "$( [ -e "$T/relhome" ] && echo yes || echo no)"
# The launch table separates its fields with |, so a state path with one is
# refused before anything is written.
XDG_STATE_HOME="$T/st|ate" su_run --config "$DEMO/stack.conf" --print-paths
check_status "an XDG_STATE_HOME with a vertical bar" 2
check_match "it names the vertical bar" 'contains \|, which the launch table uses' "$OUT"
testing_check "that folder was not created" no "$( [ -e "$T/st|ate" ] && echo yes || echo no)"
write_conf "$T/pipe-state/stack.conf" <<'CONF'
[stack]
name = t
state_dir = ${STACK_ROOT}/a|b
[service web]
start = sleep 60
CONF
su_run --config "$T/pipe-state/stack.conf" --print-paths
check_status "a state_dir with a vertical bar" 2
check_match "it names the vertical bar too" 'contains \|, which the launch table uses' "$OUT"

# Keys from an env_file, and provider lines, are checked with explicit letter
# lists: in a UTF-8 locale bash 3.2 matches [A-Za-z] against an accented
# letter, and the child's export would then fail.
if [ "$(LC_ALL=en_US.UTF-8 /bin/bash -c 'printf "%s" "${#1}"' _ "$(printf '\303\251')")" = 1 ]; then
  printf '%s\n' "$(printf '\303\251KEY=accented')" 'PLAIN_KEY=plain' '_UNDER=under' '1BAD=digit' >| "$T/keys.env"
  OUT=$(LC_ALL=en_US.UTF-8 /bin/bash -c '. "$1" || exit 1
  accented=$(printf "\303\251")
  printf "characters=%s\n" "${#accented}"
  su_export_env_file "$2"
  env | LC_ALL=C grep -E "^(PLAIN_KEY|_UNDER|1BAD)=|KEY=accented"
  if su_shape_ok envname "${accented}KEY"; then echo "provider key=accepted"; else echo "provider key=refused"; fi' _ "$STACK_UP" "$T/keys.env" 2>&1)
  check_line "control: the UTF-8 locale is in effect (one character)" 'characters=1' "$OUT"
  check_line "env_file: a plain key is exported" 'PLAIN_KEY=plain' "$OUT"
  check_line "env_file: a key that starts with _ is exported" '_UNDER=under' "$OUT"
  check_no_match "env_file: a key that starts with an accented letter is skipped" 'KEY=accented' "$OUT"
  check_no_match "env_file: a key that starts with a digit is skipped" '^1BAD=' "$OUT"
  check_no_match "env_file: no export fails" 'not a valid identifier' "$OUT"
  check_match "env_file: a skipped line is named by its number" 'env_file .*: line 4 was skipped, because it does not start with a variable name and =' "$OUT"
  check_no_match "env_file: a skipped value is never printed" 'digit' "$OUT"
  check_line "su_shape_ok envname refuses a key that starts with an accented letter (the engine run is in unit-process.sh f2)" 'provider key=refused' "$OUT"
else
  printf 'SKIP  the accented-key checks: the en_US.UTF-8 locale is not available here\n'
fi

# A malformed env_file line can be part of a secret value, so the skip names
# the line number only.
printf '%s\n' 'GOOD=1' 'export EXPORTED=yes' 'DATABASE_URL dbscheme://app:example-password@db/app?mode=require' 'example/SECRETPART=value' 'no equals sign here SECRETLINE' 'QUOTED="q"' 'CMD=$(printf pwned)' 'REF=$HOME' >| "$T/leak.env"
OUT=$(/bin/bash -c '. "$1" || exit 1
su_export_env_file "$2"
printf "GOOD=%s\n" "${GOOD-}"
printf "EXPORTED=%s\n" "${EXPORTED-}"
printf "QUOTED=[%s]\n" "${QUOTED-}"
printf "CMD=[%s]\n" "${CMD-}"
printf "REF=[%s]\n" "${REF-}"' _ "$STACK_UP" "$T/leak.env" 2>&1)
check_line "env_file: a valid line beside malformed ones is exported" 'GOOD=1' "$OUT"
check_line "env_file: an export KEY=VALUE line is read like KEY=VALUE" 'EXPORTED=yes' "$OUT"
check_match "env_file: a malformed line 3 is named by its number" 'env_file .*leak\.env: line 3 was skipped' "$OUT"
check_match "env_file: a malformed line 4 is named by its number" 'env_file .*leak\.env: line 4 was skipped' "$OUT"
check_match "env_file: a line with no = is named by its number" 'env_file .*leak\.env: line 5 was skipped' "$OUT"
check_no_match "env_file: the export line is not reported as skipped" 'leak\.env: line 2 was skipped' "$OUT"
check_no_match "env_file: no part of a skipped line is printed" 'example-password|SECRETPART|SECRETLINE|dbscheme' "$OUT"
# Values are literal: never unquoted, never evaluated, never expanded.
check_line "env_file: quotes stay in the value" 'QUOTED=["q"]' "$OUT"
check_line "env_file: a command substitution is not run" 'CMD=[$(printf pwned)]' "$OUT"
check_line "env_file: a variable reference is not expanded" 'REF=[$HOME]' "$OUT"

if [ "$(/bin/bash -c 'printf "%s" "${BASH_VERSINFO[0]}"')" -lt 5 ]; then
  # bash 3.2 writes each here-document to a temporary file. Where it cannot, the
  # engine must say so and stop, not report every config key as unknown. A file
  # size limit of 0 makes that write fail on any machine.
  OUT=$(/bin/bash -c 'trap "" XFSZ; ulimit -f 0; exec /bin/bash "$1" --config "$2" --print-config' _ "$STACK_UP" "$DEMO/stack.conf" </dev/null 2>&1)
  STATUS=$?
  check_status "no here-document file" 2
  check_line "it names the cause and the folders bash tries" 'stack-up: bash cannot create a temporary file for a here-document (bash 3.2 uses /var/tmp, then /tmp, then /usr/tmp, and ignores TMPDIR); nothing was read or started' "$OUT"
  check_no_match "it reports no config key as unknown" 'unknown key' "$OUT"
else
  printf 'SKIP  the here-document failure checks: bash 5 may pass a small here-document through a pipe\n'
fi

file=$T/never-ran/stack.conf
write_conf "$file" <<'CONF'
[stack]
name = never-ran
[service web]
start = sleep 60
CONF
su_run --config "$file" --stop
check_status "--stop on a stack that never ran here" 0
check_match "--stop says there is nothing to stop" 'nothing to stop; .* does not exist, so this stack has not run here' "$OUT"
testing_check "--stop on a stack that never ran creates no state" no "$( [ -e "$XDG_STATE_HOME/stack-up/never-ran" ] && echo yes || echo no)"

testing_verdict
