#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # single-quoted $ and | are literal config text or patterns on purpose
# unit-examples.sh - every shipped example validates through the real CLI
# without starting anything: --print-config (the validator) and --plan exit 0
# for each examples/*/stack.conf and write no state, with a container engine
# on PATH and without one, because examples/web-and-db has a [compose] entry;
# the plan of web-and-db says what its comments claim; a deliberately broken
# copy of it exits 2 and names its line; and the two scripts that example
# ships do what their headers say and pass the static rules.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

EXAMPLES=$REPO/examples
WEBDB=$EXAMPLES/web-and-db
WEBDB_CONF=examples/web-and-db/stack.conf

# --plan lists the engine (the first word of compose_command, docker by
# default) under requires and never runs it. A shim that records every call
# proves the second half; a PATH of only the system folders, where no
# container engine lives, shows what --plan prints for the first half.
CALLS=$T/engine-calls.log
: >> "$CALLS"
cat >> "$T/shims/docker" <<SHIM
#!/bin/bash
printf 'docker %s\n' "\$*" >> "$CALLS"
exit 0
SHIM
chmod +x "$T/shims/docker"
NO_ENGINE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

# plan_without_engine CONF: --plan with only the system folders on PATH;
# output and status land in OUT and STATUS, as su_run leaves them.
plan_without_engine() {
  OUT=$(PATH="$NO_ENGINE_PATH" /bin/bash "$STACK_UP" --config "$1" --plan </dev/null 2>&1)
  STATUS=$?
}

testing_check "control: the reduced PATH has no container engine" "" "$(PATH="$NO_ENGINE_PATH" command -v docker 2>/dev/null)"
testing_check "control: the reduced PATH still has lsof, pgrep, nc and curl" 4 "$(PATH="$NO_ENGINE_PATH" command -v lsof pgrep nc curl 2>/dev/null | LC_ALL=C grep -c .)"

found=0
for conf in "$EXAMPLES"/*/stack.conf; do
  [ -f "$conf" ] || continue
  found=$((found + 1))
  rel=${conf#"$REPO"/}
  su_run --config "$conf" --print-config
  check_status "$rel: --print-config, the validator, exits 0" 0
  check_match "$rel: its stack name row is printed" '^stack\|\|name\|[a-z0-9-]+$' "$OUT"
  # A compose file the config names must ship beside it: compose itself
  # would fail at up, which no test reaches without an engine.
  compose_files=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^stack||compose_files|//p')
  for path in $compose_files; do
    testing_check "$rel: the compose file $path ships beside it" yes "$( [ -f "${conf%/*}/$path" ] && echo yes || echo no)"
  done
  su_run --config "$conf" --plan
  check_status "$rel: --plan with an engine on PATH exits 0" 0
  check_match "$rel: --plan says nothing runs and no file is written" 'Plan \(nothing runs and no file is written\)' "$OUT"
  plan_without_engine "$conf"
  check_status "$rel: --plan with no engine on PATH exits 0" 0
done
testing_check "both shipped examples were found" yes "$( [ "$found" -ge 2 ] && echo yes || echo no)"
testing_check "control: no --print-config or --plan called the engine" "" "$(cat "$CALLS")"
testing_check "no example wrote a state folder" "" "$(find "$XDG_STATE_HOME" -mindepth 1 2>/dev/null)"

# web-and-db: the [compose] entry is planned whether or not an engine is on
# PATH; the engine is only listed under requires, and marked missing when it
# is not there.
plan_without_engine "$WEBDB/stack.conf"
check_match "$WEBDB_CONF: without an engine, --plan lists it under requires and marks it missing" '^    requires .*docker.*\(missing:.* docker' "$OUT"
check_match "$WEBDB_CONF: and still plans the compose entry under the project name" '^      services db \(project web-and-db\)$' "$OUT"
su_run --config "$WEBDB/stack.conf" --plan
check_match "$WEBDB_CONF: with an engine on PATH, requires lists docker" '^    requires .*docker' "$OUT"
check_no_match "$WEBDB_CONF: and no line marks docker missing" 'missing:[^)]*docker' "$OUT"
testing_check "$WEBDB_CONF: the four stages, in file order" "1/4 prepare 2/4 infra 3/4 migrate 4/4 services" "$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  \([0-9]\/[0-9]\)  \([a-z]*\)$/\1 \2/p' | tr '\n' ' ' | LC_ALL=C sed 's/ $//')"
check_match "$WEBDB_CONF: recommended selects api and web" '^    selected   api web \(default_select \(recommended\)\)$' "$OUT"
check_match "$WEBDB_CONF: the provider's values are kept in memory" '^      run      bash read-secrets\.sh \.env \(values are kept in memory, never shown\)$' "$OUT"
check_match "$WEBDB_CONF: the seed option is off by default" '^    option     seed: off \(default\)$' "$OUT"
check_match "$WEBDB_CONF: so the seed job is off" '^    off        seed: off \(option seed\)$' "$OUT"
check_match "$WEBDB_CONF: the check copies the web env file before repairing" '^      backup   copy of .*/web-and-db/web/\.env\.local, taken first$' "$OUT"
check_match "$WEBDB_CONF: the api probe carries its port once, through \${PORT}" '^      ready    http http://127\.0\.0\.1:8080/health 200 within 30s$' "$OUT"
web_block=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n '/^    service web  :3000$/,/on_fail/p')
check_match "$WEBDB_CONF: web fails as degraded, not partial" '^      on_fail  warn$' "$web_block"
check_match "$WEBDB_CONF: web starts after api" '^      after    api$' "$web_block"
check_match "$WEBDB_CONF: the smoke check is the api's health page" '^  smoke        http://127\.0\.0\.1:8080/health must answer 200 within 60s$' "$OUT"
su_run --config "$WEBDB/stack.conf" --plan --with seed
check_status "$WEBDB_CONF: --plan --with seed exits 0" 0
check_match "$WEBDB_CONF: --with seed turns the option on" '^    option     seed: on \(--with\)$' "$OUT"
seed_block=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n '/^    job seed$/,/on_fail/p')
check_match "$WEBDB_CONF: and plans the seed job after migrate and the provider" '^      after    migrate secrets$' "$seed_block"
su_run --config "$WEBDB/stack.conf" --plan --select essential
check_status "$WEBDB_CONF: --plan --select essential exits 0" 0
check_match "$WEBDB_CONF: --select essential leaves web out" '^    not selected: web$' "$OUT"
check_no_match "$WEBDB_CONF: and skips the check whose dependent is web" 'check web-api-url' "$OUT"

# One deliberately broken copy: a typo in a key name is the mistake a first
# config is most likely to have, and it must be an error, never a silently
# dropped setting.
broken=$T/broken/web-and-db
mkdir -p "$broken"
cp "$WEBDB/compose.yaml" "$broken/"
LC_ALL=C sed 's/^depends_on = api$/dependson = api/' "$WEBDB/stack.conf" >> "$broken/stack.conf"
testing_check "control: the broken copy differs from the shipped example" no "$(cmp -s "$WEBDB/stack.conf" "$broken/stack.conf" && echo yes || echo no)"
su_run --config "$broken/stack.conf" --print-config
check_status "$WEBDB_CONF, broken copy (dependson): --print-config exits 2" 2
check_match "$WEBDB_CONF, broken copy: the file, its line and the key are named" 'broken/web-and-db/stack\.conf:[0-9]+: unknown key dependson in \[service web\]$' "$OUT"
check_match "$WEBDB_CONF, broken copy: nothing was started" '^stack-up: the config has 1 error\(s\); nothing was started$' "$OUT"
check_no_match "$WEBDB_CONF, broken copy: no config row is printed" '^stack\|\|name\|' "$OUT"
su_run --config "$broken/stack.conf" --plan
check_status "$WEBDB_CONF, broken copy (dependson): --plan exits 2 as well" 2
testing_check "$WEBDB_CONF, broken copy: no state folder was written" "" "$(find "$XDG_STATE_HOME" -mindepth 1 2>/dev/null)"

# read-secrets.sh: comments, blank lines, indentation, an export prefix and a
# Windows line ending never reach the provider parser; a value keeps its =
# signs and quotes; a bad line fails the whole file by number, not content.
sample=$T/sample.env
{
  printf '%s\n' '# a comment' '' '  DB_USER=app' 'export DB_PASSWORD="p=a=s"' '   # an indented comment'
  printf 'DB_NAME=app\r\n'
  printf 'LAST=no newline at the end'
} >> "$sample"
OUT=$(cd "$WEBDB" && /bin/bash read-secrets.sh "$sample" 2>&1)
STATUS=$?
check_status "web-and-db read-secrets.sh: a well-formed file" 0
testing_check "web-and-db read-secrets.sh prints only KEY=VALUE lines, as written" "$(printf '%s\n' 'DB_USER=app' 'DB_PASSWORD="p=a=s"' 'DB_NAME=app' 'LAST=no newline at the end')" "$OUT"
OUT=$(cd "$WEBDB" && /bin/bash read-secrets.sh "$T/absent.env" 2>&1)
STATUS=$?
check_status "web-and-db read-secrets.sh: a missing file fails" 1
check_match "web-and-db read-secrets.sh: and names the fix" 'copy \.env\.example to .*absent\.env and fill in the values' "$OUT"
printf 'DB_USER=app\nthis is not a pair\n' >> "$T/bad.env"
OUT=$(cd "$WEBDB" && /bin/bash read-secrets.sh "$T/bad.env" 2>&1)
STATUS=$?
check_status "web-and-db read-secrets.sh: a line that is not KEY=VALUE fails" 1
check_match "web-and-db read-secrets.sh: names the line by number" 'line 2 of .*bad\.env is not KEY=VALUE' "$OUT"
check_no_match "web-and-db read-secrets.sh: never by content, and prints no value first" 'not a pair|DB_USER=app' "$OUT"

# set-dotenv.sh: create, replace in place once, append, refuse a bad key
# without touching the file, and leave no temporary copy behind.
mkdir -p "$T/web"
envlocal=$T/web/.env.local
OUT=$(cd "$WEBDB" && /bin/bash set-dotenv.sh "$envlocal" API_URL http://127.0.0.1:8080 2>&1)
STATUS=$?
check_status "web-and-db set-dotenv.sh: creates a missing file" 0
testing_check "web-and-db set-dotenv.sh: with the one line" 'API_URL=http://127.0.0.1:8080' "$(cat "$envlocal")"
printf '%s\n' 'OTHER=1' '  export API_URL=old' '# a note' 'API_URL=older' >| "$envlocal"
OUT=$(cd "$WEBDB" && /bin/bash set-dotenv.sh "$envlocal" API_URL http://127.0.0.1:8080 2>&1)
STATUS=$?
check_status "web-and-db set-dotenv.sh: replaces an existing key" 0
testing_check "web-and-db set-dotenv.sh: in place, once, keeping the other lines" "$(printf '%s\n' 'OTHER=1' 'API_URL=http://127.0.0.1:8080' '# a note')" "$(cat "$envlocal")"
OUT=$(cd "$WEBDB" && /bin/bash set-dotenv.sh "$envlocal" SECOND two 2>&1)
STATUS=$?
check_status "web-and-db set-dotenv.sh: appends a new key" 0
testing_check "web-and-db set-dotenv.sh: at the end" 'SECOND=two' "$(tail -n 1 "$envlocal")"
before=$(cat "$envlocal")
OUT=$(cd "$WEBDB" && /bin/bash set-dotenv.sh "$envlocal" 'not a name' x 2>&1)
STATUS=$?
check_status "web-and-db set-dotenv.sh: refuses a key that is not a variable name" 2
testing_check "web-and-db set-dotenv.sh: and leaves the file as it was" "$before" "$(cat "$envlocal")"
testing_check "web-and-db set-dotenv.sh: leaves no temporary copy behind" "" "$(find "$T/web" -name '.env.local.next.*')"

for script in read-secrets.sh set-dotenv.sh; do
  testing_check "web-and-db $script is executable" yes "$( [ -x "$WEBDB/$script" ] && echo yes || echo no)"
done
out=$(gate_check_denylist "$TESTS_DIR/static.rules" "$WEBDB/read-secrets.sh" "$WEBDB/set-dotenv.sh" 2>&1)
testing_check "web-and-db scripts pass the static rules for shipped shell code" "0: " "$?: $out"

testing_verdict
