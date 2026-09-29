#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-exit.sh - exit codes and closing lines: the outcome mapping itself,
# then 0 open (a URL only after the smoke check proved that very address; a
# skipped smoke check shows none, and an open_url that no smoke check proved
# is marked not checked; the Open line counts the entries that were off or
# known defects, and a run where nothing started says so), 1 partial (never
# claiming the URL, including a service that died after it was ready and a
# probe that passed only after its deadline), 1 for a port clash (--plan and a
# start) and for a run_if that exits 2, 2 invalid, 3 degraded (a warn-policy
# failure or a failed smoke check), probes that no proxy or curlrc can answer
# for or fail, 4 busy, and 143, 130 and 129 on TERM, INT and HUP, each with
# its VERDICT record and history row; a signal during --check stops the
# running probe, and an interrupted --stop is named as a stop. Markers, heals
# and signatures read only what the entry printed, and --clean keeps an entry
# log whose name starts with run-. It signals only what it or its own
# scenarios started: engine runs, the proxy responder, and sleeps tagged with
# its own PID.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=../bin/stack-up
. "$STACK_UP"

# su_outcome is called directly, so the four counter cases are proven without
# a run for each.
while read -r failures degraded outcome code; do
  su_outcome "$failures" "$degraded"
  testing_check "outcome for $failures failure(s), $degraded degraded" "$outcome $code" "$SU_OUTCOME $SU_EXIT"
done <<'TABLE'
0 0 open 0
1 0 partial 1
0 1 degraded 3
2 3 partial 1
TABLE

set +o noclobber
# The TERM cases wait for a job's own sleep, so each carries this run's suffix
# and a second suite running at the same time cannot be mistaken for it.
export SU_TEST_TAG=$$
pick_free_port || { testing_check "free port" found none; testing_verdict; }
FREE=$FREE_PORT

conf() {
  local name=$1 file=$T/$1/stack.conf
  mkdir -p "$T/$name"
  printf '[stack]\nname = %s\nstages = setup services\nkeep_awake = off\ndefault_select = all\n' "$name" >> "$file"
  cat >> "$file"
  CONF=$file
  STATE=$(state_of "$name")
}

conf exit-open <<'CONF'
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "open run" 0
check_match "open closing line" '^  Open: everything that started is running$' "$OUT"
check_match "open VERDICT record" 'VERDICT open exit=0' "$(cat "$STATE"/logs/run-*.log)"
su_run --config "$CONF" --stop
check_status "stop after open" 0

conf exit-skipped-smoke <<CONF
smoke_url = http://127.0.0.1:$FREE/
smoke_requires = api
open_url = http://127.0.0.1:1/app
[service api]
stage = services
start = exec sleep 300
ready = alive 1
[service worker]
stage = services
start = exec sleep 300
ready = alive 1
CONF
su_run --config "$CONF" --select worker --yes
check_status "open with a skipped smoke check" 0
check_match "a skipped smoke check is named on the closing line" '^  Open: everything that started is running \(smoke check skipped: api is not running\)$' "$OUT"
check_no_match "a skipped smoke check never shows the URL" '^  Open http' "$OUT"
check_no_match "a skipped smoke check shows no open_url" '127\.0\.0\.1:1/app' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after a skipped smoke check" 0

conf exit-unchecked <<'CONF'
open_url = http://127.0.0.1:1/nothing-listens-here
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "open with open_url and no smoke check" 0
check_match "an open_url nothing checked is marked so" '^  Open \(not checked\): http://127\.0\.0\.1:1/nothing-listens-here$' "$OUT"
check_no_match "an unchecked URL never reads as proven" '^  Open http' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after an unchecked open_url" 0

# An open_url other than the smoke_url was not what the smoke check proved.
pick_free_port || testing_check "free port for the web service" found none
WEB=$FREE_PORT
conf exit-other-url <<CONF
smoke_url = http://127.0.0.1:$WEB/
open_url = http://127.0.0.1:$WEB/elsewhere
smoke_timeout = 20
[service web]
stage = services
dir = $DEMO
port = $WEB
env = BODY=ok
start = exec bash serve.sh
ready = port
CONF
su_run --config "$CONF" --yes
check_status "open with an open_url other than the smoke_url" 0
check_match "the smoke check passed on its own URL" "smoke check: http://127\\.0\\.0\\.1:$WEB/ answered 200" "$OUT"
check_match "the other address is marked not checked" "^  Open \\(not checked\\): http://127\\.0\\.0\\.1:$WEB/elsewhere\$" "$OUT"
check_no_match "it never reads as proven" '^  Open http' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after the other-url run" 0

# A run where every selected entry was skipped or off says so.
conf exit-nothing-ran <<'CONF'
[option extras]
question = Start the extras?
[service extra]
stage = services
option = extras
start = exec sleep 300
ready = alive 1
[service legacy]
stage = services
known_defect = stands in for a broken service
start = false
CONF
su_run --config "$CONF" --yes
check_status "open with nothing started" 0
check_line "the closing line says this run started nothing, counting what it skipped" '  Open: this run started nothing (0 started, 2 skipped or off)' "$OUT"
check_no_match "it never says everything is running" 'everything (selected|that started) is running' "$OUT"

# Entries that were off or known defects are counted on the Open line.
conf exit-some-skipped <<'CONF'
[service web]
stage = services
start = exec sleep 300
ready = alive 1
[service legacy]
stage = services
known_defect = stands in for a broken service
start = false
CONF
su_run --config "$CONF" --yes
check_status "open with one entry skipped" 0
check_line "the Open line counts the skipped entry" '  Open: everything that started is running (1 skipped or off)' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after the run with one entry skipped" 0

# A service that passed readiness and died before the run ended is a failure.
conf exit-died <<'CONF'
[service short]
stage = services
start = sleep 2; echo "short: lost its database connection"; exit 1
ready = alive 1
[service slow]
stage = services
start = exec sleep 300
ready = alive 5
CONF
su_run --config "$CONF" --yes
check_status "a service that exits after it was ready" 1
check_match "it is named as exited after it was ready" 'short exited after it was ready' "$OUT"
check_match "its log is quoted" 'LOG +.*/short\.log' "$OUT"
check_match "the closing line is Partial" '^  Partial: 1 failed: short\.' "$OUT"
check_no_match "the closing line is not Open" '^  Open' "$OUT"
check_match "the history row names it failed" '	start	partial	exit=1 .*failed=\[short\]' "$(cat "$STATE/history.tsv")"
su_run --config "$CONF" --stop
check_status "stop after a service died" 0

conf exit-died-warn <<'CONF'
[service short]
stage = services
on_fail = warn
start = sleep 2; echo "short: lost its database connection"; exit 1
ready = alive 1
[service slow]
stage = services
start = exec sleep 300
ready = alive 5
CONF
su_run --config "$CONF" --yes
check_status "a warn service that exits after it was ready" 3
check_match "the warn service is named as exited after it was ready" 'short exited after it was ready' "$OUT"
check_match "a warn service that died makes the closing line Degraded" '^  Degraded: short did not finish \(on_fail = warn\);' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after a warn service died" 0

conf exit-partial <<CONF
smoke_url = http://127.0.0.1:$FREE/
smoke_requires = broken
[service broken]
stage = services
start = echo "starting"; exit 7
ready = alive 2
CONF
su_run --config "$CONF" --yes
check_status "partial run" 1
check_match "partial closing line" '^  Partial: 1 failed: broken\.' "$OUT"
check_no_match "partial never claims the URL is up" '^  Open' "$OUT"
check_match "smoke is skipped when its entry did not start" 'smoke check skipped: broken is not running' "$OUT"
check_match "partial names why it failed" 'broken failed to start: it exited after [0-9]+s, before it was ready' "$OUT"
check_match "partial VERDICT record" 'VERDICT partial exit=1 selected=\[broken\] failed=\[broken\]' "$(cat "$STATE"/logs/run-*.log)"
check_match "partial history row" '	start	partial	exit=1 version=' "$(cat "$STATE/history.tsv")"

conf exit-degraded <<'CONF'
[job optional-warmup]
stage = setup
always = yes
on_fail = warn
run = echo "warm-up could not reach its cache"; exit 1
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "degraded run" 3
check_match "degraded closing line" '^  Degraded: optional-warmup did not finish \(on_fail = warn\);' "$OUT"
check_match "degraded VERDICT record" 'VERDICT degraded exit=3' "$(cat "$STATE"/logs/run-*.log)"
su_run --config "$CONF" --stop
check_status "stop after degraded" 0

conf exit-smoke <<CONF
smoke_url = http://127.0.0.1:$FREE/
smoke_timeout = 3
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "failed smoke check" 3
check_match "smoke failure is named" 'smoke check: http://127.0.0.1:[0-9]+/ did not answer 200 within 3s' "$OUT"
check_match "smoke failure closing line" '^  Degraded: the smoke check failed;' "$OUT"
check_match "the history row says the smoke check failed" 'degraded[[:space:]]+exit=3 .* smoke=failed$' "$(cat "$STATE/history.tsv")"
su_run --config "$CONF" --stop
check_status "stop after failed smoke" 0

# Two selected services on one port: --plan exits 1, and a start stops at Plan
# before it launches either.
conf exit-clash <<CONF
[service a]
port = $FREE
start = exec sleep 300
ready = port
ready_timeout = 2
[service b]
port = $FREE
start = exec sleep 300
ready = port
ready_timeout = 2
CONF
su_run --config "$CONF" --plan
check_status "--plan with two services on one port" 1
check_match "--plan names the clash" 'Port conflicts \(the run would stop at Plan\)' "$OUT"
check_match "--plan names the port and both entries" "^    port $FREE is declared by both a and b\$" "$OUT"
su_run --config "$CONF" --yes
check_status "a start with two services on one port" 1
check_match "the start stops at Plan" '^  STOPPED  two selected entries declare the same port' "$OUT"
testing_check "the start launched nothing" no "$( [ -s "$STATE/run/launched.tsv" ] && echo yes || echo no)"
check_match "its history row says stopped" '	start	stopped	exit=1 ' "$(cat "$STATE/history.tsv")"
su_run --config "$CONF" --stop

# Markers, heals and signatures see only what the entry printed: never the
# header line that quotes its command, nor an earlier run's build output.
conf exit-okmarker <<'CONF'
[job seed]
stage = setup
always = yes
trust_exit = no
ok_marker = SEED-OK
run = false && echo SEED-OK
CONF
su_run --config "$CONF" --yes
check_status "an ok_marker that only the command text holds" 1
check_match "the job fails for its missing ok_marker" 'job seed failed: its log does not contain ok_marker' "$OUT"
conf exit-failmarker <<'CONF'
[job seed]
stage = setup
always = yes
fail_marker = SEED-FAILED
run = true || echo SEED-FAILED
CONF
su_run --config "$CONF" --yes
check_status "a fail_marker that only the command text holds" 0
check_match "the job passes" 'job seed finished' "$OUT"
conf exit-silent <<'CONF'
[job seed]
stage = setup
always = yes
run = exit 3
CONF
su_run --config "$CONF" --yes
check_status "a job that fails without output" 1
check_match "a failure with no output names this machine" 'WHO +THIS MACHINE' "$OUT"
testing_check "the copy of its output that was classified is not left behind" no "$( [ -e "$STATE/run/fault-output.log" ] && echo yes || echo no)"
conf exit-heal-cmd <<'CONF'
[service flaky]
stage = services
start = exit 1 # rebuild-cache
ready = alive 1
[heal rebuild]
for = flaky
when_log = rebuild-cache
run = touch "$STACK_STATE/heal-ran"
CONF
su_run --config "$CONF" --yes
check_status "a heal whose when_log only the command text holds" 1
check_no_match "the heal is not tried" 'trying heal rebuild' "$OUT"
testing_check "the heal did not run" no "$( [ -e "$STATE/heal-ran" ] && echo yes || echo no)"
su_run --config "$CONF" --stop
conf exit-build <<'CONF'
[signature disk]
match = No space left on device
owner = this-machine
explain = the disk is full
[service web]
stage = services
build = printf '%s\n' "$(cat "$STACK_STATE/build-says")"; exit 1
start = exec sleep 300
CONF
mkdir -p "$STATE"
printf 'No space left on device\n' >| "$STATE/build-says"
su_run --config "$CONF" --yes
check_status "a build that fails for a full disk" 1
check_match "its signature names this machine" 'WHO +THIS MACHINE' "$OUT"
printf 'SyntaxError: unexpected token\n' >| "$STATE/build-says"
su_run --config "$CONF" --yes
check_status "the next build fails for another reason" 1
check_match "only this run's build output is classified" 'WHO +NEEDS A LOOK' "$OUT"
check_no_match "the earlier run's full disk is not named" 'the disk is full' "$OUT"
su_run --config "$CONF" --stop

# A probe that passes only after its deadline does not count.
conf exit-late-probe <<'CONF'
[service slow]
stage = services
start = exec sleep 300
ready = cmd sleep 3
ready_timeout = 1
CONF
su_run --config "$CONF" --yes
check_status "a probe that passes after ready_timeout" 1
check_match "it is not ready within its deadline" 'slow failed to start: not ready within 1s \(ready = cmd sleep 3\)' "$OUT"
su_run --config "$CONF" --stop

# run_if exits 0 to run and 1 to skip; anything else is an error.
conf exit-runif <<'CONF'
[job seed]
stage = setup
always = yes
run_if = exit 2
run = true
CONF
su_run --config "$CONF" --yes
check_status "a run_if that exits 2" 1
check_match "it is named as an error, not a skip" 'seed: its run_if probe failed \(exit 2\)' "$OUT"

# --clean keeps its own run log and the newest before it, and never takes an
# entry log whose name starts with run-.
conf exit-clean <<'CONF'
keep_runs = 1
[job run-0-seed]
stage = setup
always = yes
run = echo seeded
CONF
for run in 1 2 3; do
  su_run --config "$CONF" --yes
done
su_run --config "$CONF" --clean --yes
check_status "--clean with keep_runs = 1" 0
testing_check "the entry log named run-0-seed is kept" yes "$( [ -f "$STATE/logs/run-0-seed.log" ] && echo yes || echo no)"
testing_check "--clean kept its own run log and the newest before it" 2 "$(count_files "$STATE/logs" 'run-2*.log')"

# Every probe is local: a proxy in the environment or a curlrc must neither
# answer for an address nothing listens on, nor fail a healthy service.
pick_free_port || testing_check "free port for the proxy responder" found none
PROXY=$FREE_PORT
pick_free_port || testing_check "free port that nothing listens on" found none
DEAD=$FREE_PORT
set -m
PORT=$PROXY BODY=proxied /bin/bash "$DEMO/serve.sh" </dev/null >/dev/null 2>&1 &
RESPONDER=$!
set +m
tries=0
while [ -z "$(lsof -nP -iTCP:"$PROXY" -sTCP:LISTEN -t 2>/dev/null)" ] && [ "$tries" -lt 50 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
# nc serves one connection per run, so a refusal of the dead address between
# two runs is tried once more.
proxied_code() {
  local code
  code=$(env "$@" curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$DEAD/health" 2>/dev/null)
  [ "$code" = 200 ] || { sleep 0.3; code=$(env "$@" curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$DEAD/health" 2>/dev/null); }
  printf '%s\n' "$code"
}
testing_check "setup: through the proxy, the dead address reads as 200" 200 "$(proxied_code http_proxy="http://127.0.0.1:$PROXY")"
mkdir -p "$T/curl-home"
printf 'connect-to = "::127.0.0.1:%s"\n' "$PROXY" >| "$T/curl-home/.curlrc"
testing_check "setup: with the curlrc, the dead address reads as 200" 200 "$(proxied_code CURL_HOME="$T/curl-home")"

conf exit-proxy-smoke <<CONF
smoke_url = http://127.0.0.1:$DEAD/health
smoke_timeout = 3
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
export http_proxy="http://127.0.0.1:$PROXY" ALL_PROXY="http://127.0.0.1:$PROXY"
su_run --config "$CONF" --yes
unset http_proxy ALL_PROXY
check_status "a proxy that answers 200 does not pass the smoke check" 3
check_match "the smoke check names the dead address" "smoke check: http://127\\.0\\.0\\.1:$DEAD/health did not answer 200 within 3s" "$OUT"
check_match "the closing line is Degraded" '^  Degraded: the smoke check failed;' "$OUT"
check_no_match "the closing line never offers the dead address" '^  Open http' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after the proxy smoke run" 0

conf exit-curlrc <<CONF
smoke_url = http://127.0.0.1:$DEAD/health
smoke_timeout = 3
[service probe]
stage = services
start = exec sleep 300
ready = http http://127.0.0.1:$DEAD/ready 200
ready_timeout = 3
CONF
export CURL_HOME=$T/curl-home
su_run --config "$CONF" --yes
unset CURL_HOME
check_status "a curlrc that sends every connection elsewhere passes no probe" 1
check_match "the http readiness probe was not fooled" 'probe failed to start: not ready within 3s' "$OUT"
check_no_match "the smoke check was not fooled" 'smoke check: .* answered 200' "$OUT"
check_no_match "the closing line is not Open" '^  Open' "$OUT"
su_run --config "$CONF" --stop
check_status "stop after the curlrc run" 0

kill -TERM -- -"$RESPONDER" 2>/dev/null
wait "$RESPONDER" 2>/dev/null
testing_check "the proxy responder is gone" yes "$(wait_until_gone "$RESPONDER" && echo yes || echo no)"

# A proxy that answers nothing must not fail a healthy stack: the demo, on
# picked ports, with both proxy variables pointing at a closed port.
pick_free_port || testing_check "free port for hello-api" found none
API=$FREE_PORT
pick_free_port || testing_check "free port for docs-site" found none
DOCS=$FREE_PORT
render_demo_config "$DEMO/stack.conf" "$T/proxy-demo.conf" "$API" "$DOCS"
testing_check "the demo renders onto two picked ports" 0 "$?"
export http_proxy="http://127.0.0.1:$DEAD" ALL_PROXY="http://127.0.0.1:$DEAD"
su_run --config "$T/proxy-demo.conf" --root "$DEMO" --yes
unset http_proxy ALL_PROXY
check_status "the demo with a dead proxy in the environment" 0
check_match "hello-api is ready through its http probe" "hello-api ready :$API" "$OUT"
check_match "the closing line offers the proven address" "^  Open http://127\\.0\\.0\\.1:$API/health\$" "$OUT"
su_run --config "$T/proxy-demo.conf" --root "$DEMO" --stop
check_status "stop after the dead-proxy demo" 0

conf exit-busy <<'CONF'
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
# The holder keeps the lock until this test stops it, and the run starts only
# once the lock is seen held, so a slow machine cannot let it lapse first.
mkdir -p "$STATE/run"
lockf -k -s -t 10 "$STATE/run/lock" sleep "26.$$" &
holder=$!
tries=0
while lockf -k -s -t 0 "$STATE/run/lock" true 2>/dev/null && [ "$tries" -lt 50 ]; do
  sleep 0.2
  tries=$((tries + 1))
done
su_run --config "$CONF" --yes
check_status "a second run while the lock is held" 4
check_match "busy message names the lock" 'holds the lock' "$OUT"
check_match "busy history row" '	start	busy	exit=4 ' "$(cat "$STATE/history.tsv")"
for pid in $(pgrep -f "sleep 26\\.$$\$"); do kill "$pid"; done
wait "$holder"

# The lockf of older macOS releases has only "lockf file command", so the fd
# form the run lock uses prints its usage and exits 64 there.
conf exit-old-lockf <<'CONF'
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
mkdir -p "$T/oldlockf"
cat > "$T/oldlockf/lockf" <<'SH'
#!/bin/bash
args=("$@")
while getopts knst:w flag; do :; done
shift $((OPTIND - 1))
if [ "$#" -lt 2 ]; then
  printf 'usage: lockf [-knsw] [-t seconds] file command [arguments]\n' >&2
  exit 64
fi
exec /usr/bin/lockf "${args[@]}"
SH
chmod +x "$T/oldlockf/lockf"
PATH="$T/oldlockf:$PATH" su_run --config "$CONF" --yes
check_status "a start with a lockf that cannot lock a descriptor" 1
check_match "it says why before starting anything" "this Mac's lockf cannot lock an open file, which the run lock needs" "$OUT"
check_no_match "it launched nothing" 'idle.*(ready|running)' "$OUT"
check_no_match "it prints no stop command, having started nothing" 'Stop it with' "$OUT"
testing_check "nothing was recorded" no "$( [ -s "$STATE/run/launched.tsv" ] && echo yes || echo no)"
PATH="$T/oldlockf:$PATH" su_run --config "$CONF" --stop
check_status "--stop with that lockf, after the refused start made the state folder" 1
check_match "--stop says why too" "this Mac's lockf cannot lock an open file" "$OUT"
PATH="$T/oldlockf:$PATH" su_run --config "$CONF" --clean --yes
check_status "--clean with that lockf, after the refused start" 1
check_match "--clean says why too" "this Mac's lockf cannot lock an open file" "$OUT"
PATH="$T/oldlockf:$PATH" su_run --help
check_status "--help with that lockf" 0
PATH="$T/oldlockf:$PATH" su_run --version
check_status "--version with that lockf" 0
conf exit-old-lockf-never-ran <<'CONF'
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
PATH="$T/oldlockf:$PATH" su_run --config "$CONF" --stop
check_status "--stop with that lockf on a stack that never ran here" 0
check_no_match "it does not reach the lock" "lockf cannot lock" "$OUT"
PATH="$T/oldlockf:$PATH" su_run --config "$CONF" --clean --yes
check_status "--clean with that lockf on a stack that never ran here" 0
check_no_match "--clean does not reach the lock either" "lockf cannot lock" "$OUT"
for mode in --plan --check --print-paths --print-config --print-schema; do
  PATH="$T/oldlockf:$PATH" su_run --config "$CONF" "$mode"
  check_status "$mode with that lockf" 0
done

# A start that stops early after launching something leaves it running, so it
# prints what is recorded and the stop command.
conf exit-abort-hint <<'CONF'
state_dir = run-state
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
[job late]
stage = services
depends_on = idle
pick = yes
run = exit 3
CONF
mkdir -p "$T/root-b"
su_run --config "$CONF" --root "$T/root-b" --yes
check_status "a start that stops after launching a service" 1
check_match "it ends STOPPED" '^  STOPPED  late failed' "$OUT"
check_match "it names what is still recorded" 'Still recorded as started by this stack: idle$' "$OUT"
stop_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  Stop it with  //p')
check_match "its stop command carries the run's --root" ' --root .*/root-b --stop$' "$stop_line"
run_printed "$stop_line"
check_status "the stop command, run as printed, stops what the stopped run started" 0
check_match "it stopped idle" 'stopped idle' "$OUT"
su_run --config "$CONF" --root "$T/root-b" --stop

# With --root and a relative state_dir, the printed stop command carries the
# root, so running it as printed finds and stops what the start launched.
conf exit-root-stop <<'CONF'
state_dir = run-state
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
mkdir -p "$T/root-a"
su_run --config "$CONF" --root "$T/root-a" --yes
check_status "a start with --root and a relative state_dir" 0
stop_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  Stop it with  //p')
check_match "the printed stop command carries --root" ' --root .*/root-a --stop$' "$stop_line"
su_run --config "$CONF" --root "$T/root-a" --print-paths
check_match "--print-paths names the stop command with the same --root" 'To forget this stack after .* --root .*/root-a --stop, delete its state folder' "$OUT"
run_printed "$stop_line"
check_status "the printed stop command, run as printed" 0
check_match "it stopped what the start launched" 'stopped idle' "$OUT"
su_run --config "$CONF" --root "$T/root-a" --stop

# The reason the same --root is needed on --stop for a state_dir built on
# ${STACK_ROOT}, not only a relative one: without it, --stop looks elsewhere.
conf exit-root-state <<'CONF'
state_dir = ${STACK_ROOT}/st
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
mkdir -p "$T/root-d"
su_run --config "$CONF" --root "$T/root-d" --yes
check_status "a start with --root and a state_dir built on STACK_ROOT" 0
su_run --config "$CONF" --stop
check_match "--stop without the --root does not find the stack" 'has not run here' "$OUT"
su_run --config "$CONF" --root "$T/root-d" --stop
check_status "--stop with the same --root" 0
check_match "--stop with the same --root stops it" 'stopped idle' "$OUT"

# From a folder whose name has a non-ASCII letter, in a UTF-8 locale, every
# printed command is ASCII ($'\ooo' escapes) and pastes back as the same path.
if [ "$(LC_ALL=en_US.UTF-8 /bin/bash -c 'printf "%s" "${#1}"' _ "$(printf '\303\251')")" = 1 ]; then
  odd=$T/$(printf 'Code Dir/\303\204rger')
  mkdir -p "$odd"
  # shellcheck disable=SC2016 # the engine's child expands the tag
  printf '[stack]\nname = umlaut\nstages = services\nkeep_awake = off\ndefault_select = all\nstate_dir = run-state\n[service idle]\nstage = services\nstart = exec sleep "296.$SU_TEST_TAG"\nready = alive 1\n' > "$odd/stack.conf"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 su_run --config "$odd/stack.conf" --root "$odd" --yes
  check_status "a start from a folder with a non-ASCII letter, in a UTF-8 locale" 0
  stop_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  Stop it with  //p')
  check_match "its Stop line carries the --root" ' --root .* --stop$' "$stop_line"
  testing_check "its Stop line is ASCII" "" "$(printf '%s\n' "$stop_line" | LC_ALL=C grep '[^ -~]')"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 su_run --config "$odd/stack.conf" --root "$odd" --print-paths
  check_status "--print-paths from that folder" 0
  check_match "it prints the rm line the ASCII check reads" '^  rm -r -- ' "$OUT"
  testing_check "its --print-paths commands are ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep -E '^  rm -r -- |To forget this stack after' | LC_ALL=C grep '[^ -~]')"
  run_printed "$stop_line"
  check_status "that Stop line, run as printed, stops it" 0
  check_match "it stopped idle" 'stopped idle' "$OUT"
  # The engine itself in such a folder: the program word of every printed
  # command, and of the usage hint, is escaped too.
  clone=$odd/clone
  mkdir -p "$clone"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/VERSION" "$clone/"
  OUT=$(cd "$odd" && LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /bin/bash "$clone/bin/stack-up" --config "$odd/stack.conf" --root "$odd" --yes </dev/null 2>&1)
  STATUS=$?
  check_status "a start by a copy of stack-up in that folder" 0
  stop_line=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  Stop it with  //p')
  check_match "its Stop line names that copy in escapes" "^\\$'.*/clone/bin/stack-up' --config " "$stop_line"
  testing_check "and is ASCII" "" "$(printf '%s\n' "$stop_line" | LC_ALL=C grep '[^ -~]')"
  usage=$(cd "$odd" && LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /bin/bash "$clone/bin/stack-up" --no-such-flag </dev/null 2>&1)
  testing_check "that copy refuses an unknown flag (exit status)" 2 "$?"
  check_match "its usage hint names that copy in escapes" "Run \\$'.*/clone/bin/stack-up' --help for the flags" "$usage"
  testing_check "and is ASCII" "" "$(printf '%s\n' "$usage" | LC_ALL=C grep 'help for the flags' | LC_ALL=C grep '[^ -~]')"
  testing_check "the clone printed a Stop line" yes "$( [ -n "$stop_line" ] && echo yes || echo no)"
  stopped=$(eval "$stop_line" </dev/null 2>&1)
  testing_check "the whole Stop line, program word included, run as printed" 0 "$?"
  check_match "it stopped idle again" 'stopped idle' "$stopped"
  su_run --config "$odd/stack.conf" --root "$odd" --stop
  # A compose file in such a folder, named relative to the root, which holds
  # a space: the --print-paths down line escapes it as one -f argument.
  printf 'services: {}\n' > "$odd/c.yaml"
  printf '[stack]\nname = umlautc\nstages = infra\nkeep_awake = off\ncompose_files = c.yaml\n[compose db]\nservices = db\n' > "$odd/compose.conf"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 su_run --config "$odd/compose.conf" --print-paths
  check_status "--print-paths with a compose file in that folder" 0
  check_line "its down line names the compose file in escapes, as one -f argument" "  docker compose -p umlautc -f $(LC_ALL=C; printf '%q' "$odd/c.yaml") down" "$OUT"
  testing_check "and is ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep ' down$' | LC_ALL=C grep '[^ -~]')"
else
  printf 'SKIP  non-ASCII paths: the en_US.UTF-8 locale is missing\n'
fi

conf exit-term <<'CONF'
[job slow]
stage = setup
always = yes
timeout = 60
run = exec sleep "291.$SU_TEST_TAG"
CONF
/bin/bash "$STACK_UP" --config "$CONF" --yes </dev/null >"$T/term.out" 2>&1 &
engine=$!
tries=0
while [ "$tries" -lt 50 ] && ! pgrep -f "sleep 291\\.$SU_TEST_TAG\$" >/dev/null 2>&1; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "the run reached its slow job before the TERM" yes "$(pgrep -f "sleep 291\\.$SU_TEST_TAG\$" >/dev/null 2>&1 && echo yes || echo no)"
kill -TERM "$engine"
wait "$engine"
testing_check "TERM during a run exits 143" 143 "$?"
check_match "TERM is reported as an interruption" 'INTERRUPTED  during setup' "$(cat "$T/term.out")"
check_match "interrupted history row" '	start	interrupted	exit=143 ' "$(cat "$STATE/history.tsv")"
sleep 1
testing_check "the job's process group was stopped with the run" "" "$(pgrep -f "sleep 291\\.$SU_TEST_TAG\$")"

# INT and HUP end a start the same way, with 130 and 129. The engine is
# launched with job control on, because a background command of a shell
# without it starts with INT ignored. Job control cannot undo an INT that was
# already ignored when this test started, so the INT legs skip in that case.
signal_start() {
  local signal=$1 code=$2 tag=$3
  conf "exit-signal-$code" <<CONF
[job slow]
stage = setup
always = yes
timeout = 60
run = exec sleep "$tag.\$SU_TEST_TAG"
CONF
  set -m
  /bin/bash "$STACK_UP" --config "$CONF" --yes </dev/null >"$T/$signal.out" 2>&1 &
  engine=$!
  set +m
  tries=0
  while [ "$tries" -lt 50 ] && ! pgrep -f "sleep $tag\\.$SU_TEST_TAG\$" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  testing_check "the run reached its slow job before the $signal" yes "$(pgrep -f "sleep $tag\\.$SU_TEST_TAG\$" >/dev/null 2>&1 && echo yes || echo no)"
  kill "-$signal" "$engine"
  wait "$engine"
  testing_check "$signal during a run exits $code" "$code" "$?"
  check_match "$signal is reported as an interruption" 'INTERRUPTED  during setup' "$(cat "$T/$signal.out")"
  check_match "its history row says interrupted with exit $code" "	start	interrupted	exit=$code " "$(cat "$STATE/history.tsv")"
  tries=0
  while [ "$tries" -lt 25 ] && pgrep -f "sleep $tag\\.$SU_TEST_TAG\$" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  testing_check "the job's process group was stopped with the $signal" "" "$(pgrep -f "sleep $tag\\.$SU_TEST_TAG\$")"
}
if interrupts_arrive; then
  signal_start INT 130 293
else
  printf 'SKIP  INT during a run: SIGINT was ignored when this test started, so no interrupt can be sent\n'
fi
signal_start HUP 129 294

# An interrupted start prints a stop command that carries its --root.
conf exit-term-root <<'CONF'
state_dir = run-state
[service idle]
stage = setup
start = exec sleep 300
ready = alive 1
[job slow]
stage = setup
depends_on = idle
always = yes
timeout = 60
run = exec sleep "292.$SU_TEST_TAG"
CONF
mkdir -p "$T/root-c"
/bin/bash "$STACK_UP" --config "$CONF" --root "$T/root-c" --yes </dev/null >"$T/term-root.out" 2>&1 &
engine=$!
tries=0
while [ "$tries" -lt 50 ] && ! pgrep -f "sleep 292\\.$SU_TEST_TAG\$" >/dev/null 2>&1; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "the run given --root reached its slow job before the TERM" yes "$(pgrep -f "sleep 292\\.$SU_TEST_TAG\$" >/dev/null 2>&1 && echo yes || echo no)"
kill -TERM "$engine"
wait "$engine"
testing_check "TERM during a run given --root exits 143" 143 "$?"
hint=$(LC_ALL=C sed -n 's/.*stop it with: //p' "$T/term-root.out")
check_match "the interrupt hint carries the run's --root" ' --root .*/root-c --stop$' "$hint"
run_printed "$hint"
check_status "the interrupt hint, run as printed" 0
check_match "it stopped what the interrupted run started" 'stopped idle' "$OUT"
su_run --config "$CONF" --root "$T/root-c" --stop

# A --check probe runs in its own process group, which a terminal's Ctrl-C
# never reaches, so an interrupted --check must stop it itself.
conf exit-check-term <<CONF
[check slow]
probe = exec sleep 27.$$
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
/bin/bash "$STACK_UP" --config "$CONF" --check </dev/null >"$T/check-term.out" 2>&1 &
engine=$!
tries=0
while [ "$tries" -lt 50 ] && ! pgrep -f "sleep 27\\.$$\$" >/dev/null 2>&1; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "setup: the --check probe is running" yes "$(pgrep -f "sleep 27\\.$$\$" >/dev/null 2>&1 && echo yes || echo no)"
kill -TERM "$engine"
wait "$engine"
testing_check "TERM during --check exits 143" 143 "$?"
check_match "the interruption is reported" '--check interrupted by TERM; any running probe was stopped' "$(cat "$T/check-term.out")"
tries=0
while [ "$tries" -lt 25 ] && pgrep -f "sleep 27\\.$$\$" >/dev/null 2>&1; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "the --check probe's process group was stopped" "" "$(pgrep -f "sleep 27\\.$$\$")"
for pid in $(pgrep -f "sleep 27\\.$$\$"); do kill "$pid"; done

signal_check() {
  local signal=$1 code=$2 tag=$3
  conf "exit-check-signal-$code" <<CONF
[check slow]
probe = exec sleep $tag.$$
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
  set -m
  /bin/bash "$STACK_UP" --config "$CONF" --check </dev/null >"$T/check-$signal.out" 2>&1 &
  engine=$!
  set +m
  tries=0
  while [ "$tries" -lt 50 ] && ! pgrep -f "sleep $tag\\.$$\$" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  testing_check "setup: the --check probe is running before the $signal" yes "$(pgrep -f "sleep $tag\\.$$\$" >/dev/null 2>&1 && echo yes || echo no)"
  kill "-$signal" "$engine"
  wait "$engine"
  testing_check "$signal during --check exits $code" "$code" "$?"
  check_match "the $signal is reported" "--check interrupted by $signal; any running probe was stopped" "$(cat "$T/check-$signal.out")"
  tries=0
  while [ "$tries" -lt 25 ] && pgrep -f "sleep $tag\\.$$\$" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  testing_check "the --check probe's process group was stopped by the $signal" "" "$(pgrep -f "sleep $tag\\.$$\$")"
  for pid in $(pgrep -f "sleep $tag\\.$$\$"); do kill "$pid"; done
}
if interrupts_arrive; then
  signal_check INT 130 28
else
  printf 'SKIP  INT during --check: SIGINT was ignored when this test started, so no interrupt can be sent\n'
fi
signal_check HUP 129 29

# An interrupted --stop is named as a stop, with no start's hint: it launched
# nothing. The service ignores TERM, so the stop is still in its grace period
# when the engine is interrupted.
conf exit-stop-term <<'CONF'
[service stubborn]
stage = services
start = trap '' TERM; exec sleep "295.$SU_TEST_TAG"
ready = alive 1
stop_timeout = 5
CONF
su_run --config "$CONF" --yes
check_status "up with a service that ignores TERM" 0
set -m
/bin/bash "$STACK_UP" --config "$CONF" --stop </dev/null >"$T/stop-term.out" 2>&1 &
engine=$!
set +m
tries=0
while [ "$tries" -lt 50 ] && ! LC_ALL=C grep -q '^  Stop$' "$T/stop-term.out" 2>/dev/null; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "setup: the --stop reached its Stop section before the TERM" yes "$(LC_ALL=C grep -q '^  Stop$' "$T/stop-term.out" 2>/dev/null && echo yes || echo no)"
sleep 1
kill -TERM "$engine"
wait "$engine"
testing_check "TERM during --stop exits 143" 143 "$?"
check_match "it is reported as an interrupted stop" 'INTERRUPTED  during stop' "$(cat "$T/stop-term.out")"
check_no_match "it prints no start's hint" 'Anything already started keeps running' "$(cat "$T/stop-term.out")"
check_match "its history row names the stop" '	stop	interrupted	exit=143 .*during stop' "$(cat "$STATE/history.tsv")"
su_run --config "$CONF" --stop
check_status "a --stop that runs to the end KILLs the service after its grace" 0

conf exit-invalid <<'CONF'
[service idle]
start = exec sleep 300
ready = alive 0
CONF
su_run --config "$CONF" --yes
check_status "invalid config" 2

# A run that ends without a verdict is recorded as failed by the exit trap,
# and never exits 0: the engine is sourced, a run is started, and the shell
# then exits 0 on purpose.
conf exit-no-verdict <<'CONF'
[service idle]
stage = services
start = exec sleep 300
ready = alive 1
CONF
/bin/bash -c '. "$1" && su_parse_args --config "$2" --yes && su_self_command && su_load_config && su_resolve_paths && su_start_run start && exit 0' no-verdict "$STACK_UP" "$CONF" </dev/null >"$T/no-verdict.out" 2>&1
testing_check "a run with no verdict exits 1, not 0" 1 "$?"
check_match "it is recorded as failed" 'VERDICT failed exit=1 no verdict was recorded' "$(cat "$STATE"/logs/run-*.log)"
check_match "its history row says failed" '	start	failed	exit=1 ' "$(cat "$STATE/history.tsv")"

testing_verdict
