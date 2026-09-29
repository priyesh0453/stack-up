#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # single-quoted $ is literal config or shell text on purpose
# unit-process.sh - process ownership through the real CLI: every launch gets
# its own process group and a launch token; readiness is bound to that group
# and fails fast when the process dies; --stop signals only groups that still
# hold this stack's token; provider secrets reach only their consumers; heals,
# nvm toolchains, option stops, restarts and parallel stages; a pgrep that
# misses a group for a moment, and a pgrep that fails outright; a launched
# process that left its group is named by the token it still holds; no heal
# relaunches beside a copy that could not be proven stopped; --stop without
# lsof signals nothing and says why; a launch that cannot be recorded is
# stopped at once, or reported as already exited, and a process it left
# holding its token is named; a launch table row with group 0 or 1 is never a
# record; a heal whose relaunch cannot start is counted once; an env_file
# that cannot be read, and an [env] provider's precheck, fail the entry before
# its command runs; entry paths resolve ${PORT} to the entry's own port.
# A cmd probe leaves ${STACK_ROOT} to bash; a parallel stage waits for a
# dependency it launched; a port held by another recorded entry is named as
# this stack's; an entry's env and env_file never reach another entry; only
# the nvm service gets its node; the ready line shows a port only when a
# listener was checked; a launch token without lsof keeps --stop at 1; a heal
# that fails is not followed by another start; and a port whose holder this
# account cannot see is refused without a PID. It signals only what its own
# scenarios started: tagged sleeps, loopback listeners and decoys.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

conf() {
  local name=$1 file=$T/$1/stack.conf
  mkdir -p "$T/$name"
  printf '[stack]\nname = %s\nstages = setup services\nkeep_awake = off\ndefault_select = all\n' "$name" >> "$file"
  cat >> "$file"
  CONF=$file
  STATE=$(state_of "$name")
}

record_field() {
  awk -F'|' -v want="$2" -v field="$3" '$1 == want { value = $field } END { print value }' "$1"
}

# Every sleep a test service runs carries this run's own suffix, so the leak
# check at the end sees only this test's processes.
export SU_TEST_TAG=$$
test_sleepers() {
  pgrep -f "sleep 3(0[1-9]|[12][0-9])\\.$SU_TEST_TAG\$"
}

# a: a launch gets its own process group and a launch token, and --stop stops
# it by group.
conf proc-a <<'CONF'
[service sleeper]
stage = services
start = exec sleep "301.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "a: up" 0
table=$STATE/run/launched.tsv
pid=$(record_field "$table" sleeper 3)
pgid=$(record_field "$table" sleeper 4)
token=$(record_field "$table" sleeper 5)
testing_check "a: the launch is recorded with pgid equal to pid" "$pid" "$pgid"
check_match "a: the recorded pid leads its own process group" "^$pid\$" "$(pgrep -g "$pgid")"
check_match "a: the launched process holds the launch token" "^$pid\$" "$(lsof -t -- "$token" 2>/dev/null)"
check_match "a: the entry log records pid and pgid" "^pid $pid pgid $pid\$" "$(cat "$STATE/logs/sleeper.log")"
su_run --config "$CONF" --stop
check_status "a: stop" 0
check_match "a: stop names the group" "stopped sleeper \\(process group $pgid\\)" "$OUT"
check_match "a: stop closing line" '^    \+  Everything this stack recorded is down\. Safe to power off the machine\.$' "$OUT"
check_no_match "a: the closing line claims only what this stack recorded" 'Everything is down' "$OUT"
testing_check "a: the group is gone" gone "$(group_alive "$pgid" && echo alive || echo gone)"
testing_check "a: the token of the stopped group was removed" no "$( [ -e "$token" ] && echo yes || echo no)"
testing_check "a: the launch table was rotated" 1 "$(count_files "$STATE/run" "launched-*.tsv")"
su_run --config "$CONF" --stop
check_status "a: a second stop" 0
check_match "a: a second stop finds nothing" 'Nothing from this stack was running' "$OUT"

# b: a process that exits at once fails long before its deadline.
conf proc-b <<'CONF'
[service quitter]
stage = services
start = echo "starting quitter"; exit 3
ready = alive 30
ready_timeout = 60
CONF
started=$SECONDS
su_run --config "$CONF" --yes
elapsed=$((SECONDS - started))
check_status "b: a service that exits at once" 1
check_match "b: the reason is its exit" 'quitter failed to start: it exited after [0-9]+s, before it was ready' "$OUT"
testing_check "b: failure came well before the 60 s deadline" yes "$( [ "$elapsed" -lt 30 ] && echo yes || echo "no, ${elapsed}s")"
check_match "b: the fault quotes its log" 'LOG +.*quitter\.log' "$OUT"

# c: a listener that left the launched group does not count as ready.
pick_free_port || testing_check "c: free port" found none
PORT_C=$FREE_PORT
conf proc-c <<CONF
[service escaper]
stage = services
port = $PORT_C
start = set -m; nc -l 127.0.0.1 "\$PORT" </dev/null >/dev/null 2>&1 & exec sleep 309.$SU_TEST_TAG
ready = port
ready_timeout = 15
CONF
su_run --config "$CONF" --yes
check_status "c: listener outside the group" 1
check_match "c: the foreign listener is named, not accepted" "port $PORT_C is answered by PID [0-9]+ \\(nc\\), which is not part of the process group stack-up started" "$OUT"
escaped=$(lsof -nP -iTCP:"$PORT_C" -sTCP:LISTEN -t 2>/dev/null)
testing_check "c: stack-up did not signal the listener outside its group" alive "$( [ -n "$escaped" ] && kill -0 "$escaped" 2>/dev/null && echo alive || echo gone)"
testing_check "c: the launched group itself was stopped" "" "$(pgrep -f "sleep 309\\.$SU_TEST_TAG")"
for p in $escaped; do kill "$p" 2>/dev/null; done

# d: a service that never binds its port is still stopped, by group.
pick_free_port || testing_check "d: free port" found none
conf proc-d <<CONF
[service unbound]
stage = services
port = $FREE_PORT
start = exec sleep "302.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "d: up with a service that has not bound" 0
pgid=$(record_field "$STATE/run/launched.tsv" unbound 4)
su_run --config "$CONF" --stop
check_status "d: stop" 0
testing_check "d: the unbound service is gone" gone "$(group_alive "$pgid" && echo alive || echo gone)"

# e: a recorded group whose processes do not hold the token is never signalled.
conf proc-e <<'CONF'
[service ghost]
stage = services
start = exec sleep "303.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$STATE/run/tokens"
set -m
sleep 310 &
decoy=$!
set +m
printf 'launch token for ghost\n' >> "$STATE/run/tokens/ghost-old"
printf 'ghost|service|%s|%s|%s|||\n' "$decoy" "$decoy" "$STATE/run/tokens/ghost-old" >> "$STATE/run/launched.tsv"
su_run --config "$CONF" --stop
check_status "e: stop with a group that is not provably ours" 1
check_match "e: it says why it did not signal" "process group $decoy is running, but none of its processes holds this stack's launch token, so it is not signalled" "$OUT"
testing_check "e: the decoy is untouched" alive "$(kill -0 "$decoy" 2>/dev/null && echo alive || echo gone)"
check_no_match "e: no stop line names the decoy" "stopped ghost" "$(cat "$STATE"/logs/run-*.log)"
kill "$decoy"
wait "$decoy" 2>/dev/null

# f: provider values reach only the entries that name the provider.
conf proc-f <<'CONF'
[env secrets]
stage = setup
run = printf 'API_TOKEN=example-token-%s\nREGION=dev\n' "$SU_TEST_TAG"
[service consumer]
stage = services
env_from = secrets
env = LOCAL_ONLY=consumer-env
env_file = ${STACK_ROOT}/consumer.env
start = printf '%s\n' "${API_TOKEN:+present}" > "$STACK_STATE/consumer.seen"; sleep "304.$SU_TEST_TAG"
ready = alive 1
[service bystander]
stage = services
start = printf '%s\n' "${API_TOKEN:-absent}" > "$STACK_STATE/bystander.seen"; printf '%s\n' "${LOCAL_ONLY:-absent} ${FILE_ONLY:-absent}" > "$STACK_STATE/bystander-env.seen"; exec sleep "305.$SU_TEST_TAG"
ready = alive 1
CONF
printf 'FILE_ONLY=consumer-file\n' >| "$T/proc-f/consumer.env"
su_run --config "$CONF" --yes
check_status "f: up with a provider" 0
testing_check "f: the consumer sees the value" present "$(cat "$STATE/consumer.seen")"
testing_check "f: an entry without env_from does not" absent "$(cat "$STATE/bystander.seen")"
testing_check "f: another entry's env and env_file values do not reach it either" "absent absent" "$(cat "$STATE/bystander-env.seen")"
check_match "f: the run log shows keys only" 'env provider secrets: API_TOKEN=<set> REGION=<set>' "$(cat "$STATE"/logs/run-*.log)"
testing_check "f: the value is in no file under the state folder" "" "$(LC_ALL=C grep -rl "example-token-$SU_TEST_TAG" "$STATE" 2>/dev/null)"
check_match "f: the consumer's own shell is still running, so its command line can be read" '^[0-9]+$' "$(pgrep -g "$(record_field "$STATE/run/launched.tsv" consumer 4)" -f 'consumer\.seen')"
testing_check "f: the value is on no command line" "" "$(pgrep -f "example-token-$SU_TEST_TAG")"
su_run --config "$CONF" --stop
check_status "f: stop" 0

# f2: in a UTF-8 locale bash 3.2 matches [A-Za-z] against an accented letter,
# so a provider key that starts with one must be refused by the engine itself,
# not logged as set and then lost in the consumer's export.
if [ "$(LC_ALL=en_US.UTF-8 /bin/bash -c 'printf "%s" "${#1}"' _ "$(printf '\303\251')")" = 1 ]; then
conf proc-f2 <<'CONF'
[env secrets]
stage = setup
run = printf '\303\251KEY=v\nPLAIN=p\n'
[service consumer]
stage = services
env_from = secrets
start = exec sleep "306.$SU_TEST_TAG"
ready = alive 1
CONF
OUT=$(LC_ALL=en_US.UTF-8 /bin/bash "$STACK_UP" --config "$CONF" --yes </dev/null 2>&1)
STATUS=$?
check_status "f2: an accented provider key under UTF-8 stops the run" 1
check_match "f2: it names the line" 'env provider secrets printed line 1, which is not KEY=VALUE' "$OUT"
check_no_match "f2: the key is never logged as set" 'KEY=<set>' "$(cat "$STATE"/logs/run-*.log)"
check_no_match "f2: the run does not claim everything is running" 'Open: everything that started is running' "$OUT"
su_run --config "$CONF" --stop
check_status "f2: stop" 0
else
  printf 'SKIP  f2: the en_US.UTF-8 locale is not available here\n'
fi

# g: one heal attempt, then one retry. The start builds its message at run
# time, so only its output, never its command text, can match when_log.
conf proc-g <<'CONF'
[service flaky]
stage = services
start = if [ -f "$STACK_STATE/healed" ]; then exec sleep "306.$SU_TEST_TAG"; fi; printf 'cache is %s\n' stale; exit 1
ready = alive 1
[heal clear-cache]
for = flaky
when_log = cache is stale
run = touch "$STACK_STATE/healed"
CONF
su_run --config "$CONF" --yes
check_status "g: a service healed on its first failure" 0
check_match "g: the heal is announced" 'its log matches heal clear-cache' "$OUT"
check_match "g: recovered after the heal" 'flaky ready running \([0-9]+s\) \(recovered after heal clear-cache\)' "$OUT"
check_match "g: heal ledger rows" '	clear-cache	flaky	recovered$' "$(cat "$STATE/heals.tsv")"
su_run --config "$CONF" --stop
check_status "g: stop" 0

# h: toolchain = nvm resolves node through nvm which, from a fixture NVM_DIR.
export NVM_DIR=$T/nvm
mkdir -p "$NVM_DIR/versions/node/v9.9.9/bin" "$T/app"
printf 'nvm() {\n  [ "$1" = which ] && printf "%%s\\n" "$NVM_DIR/versions/node/$2/bin/node"\n}\n' >> "$NVM_DIR/nvm.sh"
printf '#!/bin/bash\necho v9.9.9-fixture\n' >> "$NVM_DIR/versions/node/v9.9.9/bin/node"
chmod +x "$NVM_DIR/versions/node/v9.9.9/bin/node"
printf 'v9.9.9\n' >> "$T/app/.nvmrc"
conf proc-h <<CONF
[service web]
stage = services
dir = $T/app
toolchain = nvm
start = node > "\$STACK_STATE/node.out"; exec sleep 307.$SU_TEST_TAG
ready = alive 1
[job after]
stage = services
always = yes
depends_on = web
run = command -v node > "\$STACK_STATE/after.node" || echo none > "\$STACK_STATE/after.node"
[service no-version]
stage = services
dir = $T
toolchain = nvm
start = exec sleep 311.$SU_TEST_TAG
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "h: one nvm service ok, one without .nvmrc" 1
# ready = alive 1 can pass before the fixture node has written its line on
# a loaded machine, so the check waits for the file (at most 5 seconds).
tries=0
while [ ! -s "$STATE/node.out" ] && [ "$tries" -lt 25 ]; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "h: node came from nvm which" v9.9.9-fixture "$(cat "$STATE/node.out")"
check_match "h: missing .nvmrc is a counted failure with a hint" 'no-version not started: toolchain = nvm, but .*/\.nvmrc is missing' "$OUT"
testing_check "h: a job after the nvm service does not get its node" 0 "$(LC_ALL=C grep -c -F "$NVM_DIR/versions/node/v9.9.9/bin" "$STATE/after.node")"
su_run --config "$CONF" --stop
check_status "h: stop" 0
unset NVM_DIR

# i: an option with when_off = stop stops its entries when it is off.
conf proc-i <<'CONF'
[option extras]
question = Start the extras?
when_off = stop
[service extra]
stage = services
option = extras
start = exec sleep "312.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes --with extras
check_status "i: up with the option on" 0
pgid=$(record_field "$STATE/run/launched.tsv" extra 4)
testing_check "i: extra is running" alive "$(group_alive "$pgid" && echo alive || echo gone)"
su_run --config "$CONF" --yes
check_status "i: up with the option at its default (off)" 0
check_match "i: extra is stopped because the option is off" 'option extras is off: stopped extra' "$OUT"
testing_check "i: extra's group is gone" gone "$(group_alive "$pgid" && echo alive || echo gone)"

# j: a rerun restarts only the copy this stack started.
conf proc-j <<'CONF'
[service again]
stage = services
start = exec sleep "308.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
first=$(record_field "$STATE/run/launched.tsv" again 4)
su_run --config "$CONF" --yes
check_status "j: second up" 0
check_match "j: the earlier copy is stopped first" 'again: stopping the copy this stack started earlier' "$OUT"
second=$(record_field "$STATE/run/launched.tsv" again 4)
testing_check "j: the first group is gone" gone "$(group_alive "$first" && echo alive || echo gone)"
testing_check "j: a new group runs" alive "$(group_alive "$second" && echo alive || echo gone)"
testing_check "j: one record per entry" 1 "$(LC_ALL=C grep -c '^again|' "$STATE/run/launched.tsv")"
su_run --config "$CONF" --stop
check_status "j: stop" 0

# k: a parallel stage launches everything, then waits.
conf proc-k <<'CONF'
parallel_stages = services
[service one]
stage = services
start = exec sleep "313.$SU_TEST_TAG"
ready = alive 2
[service two]
stage = services
start = exec sleep "314.$SU_TEST_TAG"
ready = alive 2
CONF
su_run --config "$CONF" --yes
check_status "k: parallel stage" 0
check_match "k: both launched before waiting" 'waiting for 2 service\(s\) to become ready' "$OUT"
su_run --config "$CONF" --stop
check_status "k: stop" 0

# k2: in a parallel stage, a service whose dependency is launched in the same
# stage waits for that dependency instead of failing as blocked.
conf proc-k2 <<'CONF'
parallel_stages = services
[service db]
stage = services
start = exec sleep "325.$SU_TEST_TAG"
ready = alive 1
[service api]
stage = services
depends_on = db
start = exec sleep "326.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "k2: a parallel stage with a dependency inside it" 0
check_match "k2: db is ready" 'db ready running' "$OUT"
check_match "k2: api is ready" 'api ready running' "$OUT"
check_no_match "k2: api is not blocked by a pending db" 'which is pending' "$OUT"
su_run --config "$CONF" --stop
check_status "k2: stop" 0

# l: pgrep misses the group on its first call, as it can right around a fork.
pick_free_port || testing_check "l: free port" found none
mkdir -p "$T/pgrep-miss"
cat >> "$T/pgrep-miss/pgrep" <<SHIM
#!/bin/bash
if [ ! -e "$T/pgrep-miss/served" ] && [ "\$1" = -g ]; then
  printf 'miss\n' >> "$T/pgrep-miss/calls"
  : > "$T/pgrep-miss/served"
  exit 1
fi
printf 'real\n' >> "$T/pgrep-miss/calls"
exec /usr/bin/pgrep "\$@"
SHIM
chmod +x "$T/pgrep-miss/pgrep"
conf proc-l <<CONF
[service listener]
stage = services
port = $FREE_PORT
start = exec nc -lk 127.0.0.1 "\$PORT"
ready = port
CONF
PATH="$T/pgrep-miss:$PATH" su_run --config "$CONF" --yes
check_status "l: up when the first pgrep misses" 0
check_match "l: the service is ready from its own group" "listener ready :$FREE_PORT" "$OUT"
check_no_match "l: no false process-group refusal" 'could not be given its own process group|did not report its process group' "$OUT"
testing_check "l: the first pgrep call was the miss" miss "$(head -n 1 "$T/pgrep-miss/calls" 2>/dev/null)"
pgid=$(record_field "$STATE/run/launched.tsv" listener 4)
rm -f "$T/pgrep-miss/served" "$T/pgrep-miss/calls"
PATH="$T/pgrep-miss:$PATH" su_run --config "$CONF" --stop
check_status "l: stop when the first pgrep misses" 0
check_match "l: stop still stops the group" "stopped listener \\(process group $pgid\\)" "$OUT"
testing_check "l: the stop's first pgrep call was the miss" miss "$(head -n 1 "$T/pgrep-miss/calls" 2>/dev/null)"
testing_check "l: the group is gone" gone "$(wait_until_gone "$pgid" && echo gone || echo alive)"

# w: a declared port is shown on the ready line only when readiness checked a
# listener on it.
pick_free_port || testing_check "w: free port" found none
PORT_W=$FREE_PORT
conf proc-w <<CONF
[service quiet]
stage = services
port = $PORT_W
start = exec sleep "327.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "w: a service with a port and ready = alive" 0
check_match "w: its ready line says running" 'quiet ready running \(' "$OUT"
check_no_match "w: it does not show the port no probe checked" "quiet ready :$PORT_W" "$OUT"
su_run --config "$CONF" --stop
check_status "w: stop" 0

# m: pgrep fails outright. A group that cannot be checked is never called
# stopped, never signalled, and keeps its record and token.
mkdir -p "$T/pgrep-broken"
printf '#!/bin/bash\nexit 3\n' >> "$T/pgrep-broken/pgrep"
chmod +x "$T/pgrep-broken/pgrep"
conf proc-m <<'CONF'
[service steady]
stage = services
start = exec sleep "315.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "m: up" 0
table=$STATE/run/launched.tsv
pgid=$(record_field "$table" steady 4)
token=$(record_field "$table" steady 5)
PATH="$T/pgrep-broken:$PATH" su_run --config "$CONF" --stop
check_status "m: --stop when pgrep fails" 1
check_match "m: it says the group could not be checked" "steady: process group $pgid could not be checked \\(pgrep -g $pgid failed with status 3\\), so it was not signalled" "$OUT"
check_no_match "m: it never calls the group stopped or the stack down" 'had already stopped|stopped steady|Everything (this stack recorded )?is down' "$OUT"
testing_check "m: the group is still running" alive "$(group_alive "$pgid" && echo alive || echo gone)"
testing_check "m: the launch record is kept" "$pgid" "$(record_field "$table" steady 4)"
testing_check "m: the launch token is kept" yes "$( [ -f "$token" ] && echo yes || echo no)"
PATH="$T/pgrep-broken:$PATH" su_run --config "$CONF" --yes
check_status "m: up when pgrep fails" 1
check_match "m: the running copy is not restarted blind" "steady not restarted: process group $pgid could not be checked" "$OUT"
testing_check "m: the first copy still runs" alive "$(group_alive "$pgid" && echo alive || echo gone)"
testing_check "m: its record survives the start of the run" "$pgid" "$(record_field "$table" steady 4)"
su_run --config "$CONF" --stop
check_status "m: stop with a working pgrep" 0
check_match "m: then it stops the recorded group" "stopped steady \\(process group $pgid\\)" "$OUT"
testing_check "m: the group is gone" gone "$(wait_until_gone "$pgid" && echo gone || echo alive)"

pid_gone() {
  local tries=0
  while kill -0 "$1" 2>/dev/null && [ "$tries" -lt 25 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

# n: a child that moves to a process group of its own still holds the launch
# token it inherited. --stop names it, never signals it, keeps the token and
# exits 1; once the test stops that child itself, --stop is clean again.
conf proc-n <<'CONF'
[service esc]
stage = services
start = set -m; sleep "316.$SU_TEST_TAG" & exec sleep "317.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "n: up" 0
table=$STATE/run/launched.tsv
pgid=$(record_field "$table" esc 4)
token=$(record_field "$table" esc 5)
escaped=$(pgrep -f "sleep 316\\.$SU_TEST_TAG\$")
check_match "n: the child outside the group is running" '^[0-9]+$' "$escaped"
su_run --config "$CONF" --stop
check_status "n: --stop with a launched process outside its group" 1
check_match "n: the recorded group itself is stopped" "stopped esc \\(process group $pgid\\)" "$OUT"
check_match "n: the process outside the group is named with its PID" "esc: PID $escaped \\(sleep\\) left the process group this stack started but still holds its launch token, so it was not signalled" "$OUT"
check_no_match "n: it never claims the stack is down" 'Everything is down|Everything this stack recorded is down|Nothing from this stack was running' "$OUT"
testing_check "n: the process outside the group was not signalled" alive "$(kill -0 "$escaped" 2>/dev/null && echo alive || echo gone)"
testing_check "n: its launch token is kept" yes "$( [ -f "$token" ] && echo yes || echo no)"
check_match "n: the history row says leftovers" '	stop	leftovers	exit=1 .*left=\[stray:esc\]' "$(cat "$STATE/history.tsv")"
kill "$escaped"
testing_check "n: the test stopped that process itself" gone "$(pid_gone "$escaped" && echo gone || echo alive)"
su_run --config "$CONF" --stop
check_status "n: --stop once nothing holds the token" 0
testing_check "n: then the token is removed" no "$( [ -e "$token" ] && echo yes || echo no)"

# n2: the same with --root and a relative state_dir: the hint --stop prints for
# what it left running carries the --root, so running it as printed finds the
# stack instead of saying it never ran here.
conf proc-n2 <<'CONF'
state_dir = run-state
[service esc]
stage = services
start = set -m; sleep "331.$SU_TEST_TAG" & exec sleep "332.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$T/root-n2"
su_run --config "$CONF" --root "$T/root-n2" --yes
check_status "n2: up with --root" 0
escaped=$(pgrep -f "sleep 331\\.$SU_TEST_TAG\$")
check_match "n2: the child outside the group is running" '^[0-9]+$' "$escaped"
su_run --config "$CONF" --root "$T/root-n2" --stop
check_status "n2: --stop leaves the escaped process" 1
again=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/.*; run \(.*\) again, or stop them by hand$/\1/p')
check_match "n2: the rerun hint carries the --root" ' --root .*/root-n2 --stop$' "$again"
kill "$escaped"
testing_check "n2: the test stopped that process itself" gone "$(pid_gone "$escaped" && echo gone || echo alive)"
run_printed "$again"
check_status "n2: the rerun hint, run as printed" 0
check_no_match "n2: it never says the stack has not run here" 'has not run here' "$OUT"
testing_check "n2: the tokens folder is under the root" yes "$( [ -d "$T/root-n2/run-state/run/tokens" ] && echo yes || echo no)"
testing_check "n2: the token is removed" 0 "$(find "$T/root-n2/run-state/run/tokens" -type f | wc -l | tr -d ' ')"

# o: a classic daemon: the leader forks into a new group and exits. The run is
# Partial, and both the run and --stop name the process left behind.
conf proc-o <<'CONF'
[service daemon]
stage = services
start = set -m; sleep "318.$SU_TEST_TAG" & sleep 0.5; exit 0
ready = alive 5
CONF
su_run --config "$CONF" --yes
check_status "o: a service that detaches and exits" 1
detached=$(pgrep -f "sleep 318\\.$SU_TEST_TAG\$")
check_match "o: the detached process is running" '^[0-9]+$' "$detached"
check_match "o: the run names it" "daemon: PID $detached \\(sleep\\) left the process group stack-up started but still holds its launch token" "$OUT"
su_run --config "$CONF" --stop
check_status "o: --stop with only a detached process left" 1
check_match "o: --stop names it" "daemon: PID $detached \\(sleep\\) left the process group this stack started" "$OUT"
check_no_match "o: --stop never says nothing was running" 'Nothing from this stack was running|Everything (this stack recorded )?is down' "$OUT"
testing_check "o: the detached process was not signalled" alive "$(kill -0 "$detached" 2>/dev/null && echo alive || echo gone)"
kill "$detached"
testing_check "o: the test stopped it itself" gone "$(pid_gone "$detached" && echo gone || echo alive)"

# p: when the failed copy cannot be proven stopped, no heal runs and no second
# copy is launched beside it.
conf proc-p <<'CONF'
[service stuck]
stage = services
start = echo "cache is stale"; exec sleep "319.$SU_TEST_TAG"
ready = cmd false
ready_timeout = 2
[heal clear-cache]
for = stuck
when_log = cache is stale
run = true
CONF
PATH="$T/pgrep-broken:$PATH" su_run --config "$CONF" --yes
check_status "p: a failed start whose group cannot be checked" 1
check_match "p: it says the group could not be checked" 'stuck: process group [0-9]+ could not be checked' "$OUT"
check_no_match "p: no heal runs" 'trying heal|its log matches heal' "$OUT"
testing_check "p: one launch record" 1 "$(LC_ALL=C grep -c '^stuck|' "$STATE/run/launched.tsv")"
testing_check "p: one copy running" 1 "$(pgrep -f "sleep 319\\.$SU_TEST_TAG\$" | LC_ALL=C grep -c .)"
su_run --config "$CONF" --stop
check_status "p: stop with a working pgrep" 0
check_match "p: it stops the one recorded copy" 'stopped stuck \(process group [0-9]+\)' "$OUT"

# q: without lsof on PATH the launch token cannot be read, so --stop signals
# nothing and says the group could not be checked, never that its ID was reused.
conf proc-q <<'CONF'
[service quiet]
stage = services
start = exec sleep "320.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "q: up" 0
pgid=$(record_field "$STATE/run/launched.tsv" quiet 4)
testing_check "q: setup: lsof is not in the short PATH" "" "$(PATH="$T/shims:/usr/bin:/bin" command -v lsof)"
PATH="$T/shims:/usr/bin:/bin" su_run --config "$CONF" --stop
check_status "q: stop without lsof" 1
check_match "q: it says the group could not be checked and why" "process group $pgid could not be checked \\(lsof is not on PATH; it lives in /usr/sbin\\), so it was not signalled" "$OUT"
check_no_match "q: it never blames a reused group ID" 'unrelated program' "$OUT"
testing_check "q: the service is still running" alive "$(group_alive "$pgid" && echo alive || echo gone)"
testing_check "q: its record is kept" "$pgid" "$(record_field "$STATE/run/launched.tsv" quiet 4)"
su_run --config "$CONF" --stop
check_status "q: stop with lsof" 0
testing_check "q: now the group is gone" gone "$(group_alive "$pgid" && echo alive || echo gone)"

# q2: a launch token left behind cannot be checked without lsof either, so
# --stop keeps it, says why and exits 1, never "Everything is down".
conf proc-q2 <<'CONF'
[service brief]
stage = services
start = exec sleep "323.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "q2: up" 0
pgid=$(record_field "$STATE/run/launched.tsv" brief 4)
kill -TERM -- -"$pgid"
testing_check "q2: the test stopped the group itself" gone "$(wait_until_gone "$pgid" && echo gone || echo alive)"
PATH="$T/shims:/usr/bin:/bin" su_run --config "$CONF" --stop
check_status "q2: stop without lsof, with a launch token left" 1
check_match "q2: it says the tokens could not be checked" 'lsof is not available, so the launch tokens under .* could not be checked' "$OUT"
check_no_match "q2: it never says everything is down" 'Everything (this stack recorded )?is down' "$OUT"
testing_check "q2: the token is kept" 1 "$(count_files "$STATE/run/tokens" '*')"
su_run --config "$CONF" --stop
check_status "q2: stop with lsof" 0
testing_check "q2: then the token is removed" 0 "$(count_files "$STATE/run/tokens" '*')"

# r: a launch the table cannot record is stopped at once and counted failed,
# so nothing runs that --stop has no record of.
conf proc-r <<'CONF'
[service unrecorded]
stage = services
start = exec sleep "321.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$STATE/run/launched.tsv"
su_run --config "$CONF" --yes
check_status "r: a launch that cannot be recorded" 1
check_match "r: it says so" 'unrecorded not started: its launch could not be recorded in .*/run/launched\.tsv, so it was stopped at once' "$OUT"
check_no_match "r: it never reads as running" 'unrecorded ready' "$OUT"
testing_check "r: nothing is left running" "" "$(pgrep -f "sleep 321\\.$SU_TEST_TAG\$")"
rmdir "$STATE/run/launched.tsv"
su_run --config "$CONF" --stop
check_status "r: stop afterwards" 0

# r3: a stack whose only entry is a job without pick = yes says why nothing is
# selected, although the job is essential and default_select is all.
conf proc-r3 <<'CONF'
[job seed]
stage = setup
tier = essential
run = true
CONF
su_run --config "$CONF" --yes
check_match "r3: the hint names pick = yes for entries that are not services" 'nothing is selected: .*\(an entry that is not a service also needs pick = yes\)' "$OUT"

# r2: a launch that exits before it can be recorded is not signalled at all.
# The engine is sourced so that, after the launch, the test waits until the
# launched group is gone (at most 5 seconds), and every group signal can be
# recorded.
conf proc-r2 <<'CONF'
[service quick]
stage = services
start = exec /bin/sh -c 'exit 0'
ready = alive 1
CONF
mkdir -p "$STATE/run/launched.tsv"
cat >| "$T/r2-probe.sh" <<'PROBE'
. "$1" || exit 3
su_signal_group() {
  if [ "$1" != 0 ]; then printf '%s %s\n' "$1" "$2" >> "$SIGLOG"; fi
  kill "-$1" -- "-$2" 2>/dev/null
}
eval "orig_$(declare -f su_launch)"
su_launch() {
  local n=0
  orig_su_launch "$@"
  while kill -0 -- "-$SU_PID" 2>/dev/null && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
}
main --config "$2" --yes </dev/null
PROBE
OUT=$(SIGLOG="$T/r2-signals" /bin/bash "$T/r2-probe.sh" "$STACK_UP" "$CONF" 2>&1)
STATUS=$?
check_status "r2: a launch that exited before it was recorded" 1
check_match "r2: it says the launch had already exited" 'quick not started: its launch could not be recorded in .*, and it had already exited' "$OUT"
check_no_match "r2: it does not claim a stop" 'so it was stopped at once' "$OUT"
testing_check "r2: no signal goes to a group that is gone" "" "$(cat "$T/r2-signals" 2>/dev/null)"
rmdir "$STATE/run/launched.tsv"

# r4: such a launch that left a process of its own behind, in a group of its
# own and still holding the launch token, has that process named in the
# same run, and never signalled.
conf proc-r4 <<'CONF'
[service quick]
stage = services
start = exec /bin/sh -c 'set -m; sleep "306.$SU_TEST_TAG" & exit 0'
ready = alive 1
CONF
mkdir -p "$STATE/run/launched.tsv"
OUT=$(SIGLOG="$T/r4-signals" /bin/bash "$T/r2-probe.sh" "$STACK_UP" "$CONF" 2>&1)
STATUS=$?
check_status "r4: a launch that left a token holder behind" 1
check_match "r4: the process left behind is named by its token" 'quick: PID [0-9]+ .*left the process group stack-up started but still holds its launch token, so it was not signalled' "$OUT"
check_match "r4: it still says the launch had already exited" 'quick not started: its launch could not be recorded in .*, and it had already exited' "$OUT"
testing_check "r4: no signal was sent" "" "$(cat "$T/r4-signals" 2>/dev/null)"
stray=$(pgrep -f "sleep 306\\.$SU_TEST_TAG\$")
testing_check "r4: the process left behind is still running" yes "$( [ -n "$stray" ] && echo yes || echo no)"
for stray_pid in $stray; do
  kill "$stray_pid" 2>/dev/null
done
rmdir "$STATE/run/launched.tsv"

# r5: when the group is still there, it is stopped, and a process it left
# behind that still holds the launch token is named, never signalled. The
# test waits after the launch until that process exists (at most 5 seconds).
conf proc-r5 <<'CONF'
[service quick]
stage = services
start = exec /bin/sh -c 'set -m; sleep "309.$SU_TEST_TAG" & exec sleep "310.$SU_TEST_TAG"'
ready = alive 1
CONF
mkdir -p "$STATE/run/launched.tsv"
cat >| "$T/r5-probe.sh" <<'PROBE'
. "$1" || exit 3
eval "orig_$(declare -f su_launch)"
su_launch() {
  local n=0
  orig_su_launch "$@"
  while ! pgrep -f "sleep 309\\.$SU_TEST_TAG\$" >/dev/null && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
}
main --config "$2" --yes </dev/null
PROBE
OUT=$(/bin/bash "$T/r5-probe.sh" "$STACK_UP" "$CONF" 2>&1)
STATUS=$?
check_status "r5: a launch that could not be recorded and left a token holder" 1
check_match "r5: the group was stopped" 'quick not started: its launch could not be recorded in .*, so it was stopped at once' "$OUT"
check_match "r5: the process left behind is named by its token" 'quick: PID [0-9]+ .*left the process group stack-up started but still holds its launch token, so it was not signalled' "$OUT"
testing_check "r5: the group's own process is gone" "" "$(pgrep -f "sleep 310\\.$SU_TEST_TAG\$")"
stray=$(pgrep -f "sleep 309\\.$SU_TEST_TAG\$")
testing_check "r5: the process left behind was not signalled" yes "$( [ -n "$stray" ] && echo yes || echo no)"
for stray_pid in $stray; do
  kill "$stray_pid" 2>/dev/null
done
rmdir "$STATE/run/launched.tsv"

# s: a hand-edited row with process group 0 or 1 is not a record: kill -- -0
# is the engine's own group and kill -- -1 every process the user can signal.
conf proc-s <<'CONF'
[service ghost]
stage = services
start = exec sleep "322.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$STATE/run/tokens"
: >> "$STATE/run/tokens/ghost-19990101-000000-1"
printf 'ghost|service|1|1|%s||%s\nghost|service|0|0|%s||%s\n' "$STATE/run/tokens/ghost-19990101-000000-1" "$STATE/logs/ghost.log" "$STATE/run/tokens/ghost-19990101-000000-1" "$STATE/logs/ghost.log" >> "$STATE/run/launched.tsv"
su_run --config "$CONF" --stop
check_status "s: stop with only group 0 and 1 rows" 0
check_no_match "s: neither row is treated as a process group" 'process group [01][^0-9]' "$OUT"
check_match "s: nothing from this stack was running" 'Nothing from this stack was running' "$OUT"

# t: a heal whose relaunch cannot start is one failure, counted once.
conf proc-t <<'CONF'
[service rootless]
stage = services
dir = wd
start = echo "cache is stale"; exit 1
ready = alive 1
[heal drop-wd]
for = rootless
when_log = cache is stale
run = rmdir wd
CONF
mkdir -p "$T/proc-t/wd"
su_run --config "$CONF" --yes
check_status "t: a heal whose relaunch cannot start" 1
check_match "t: the heal ran" 'rootless: trying heal drop-wd once' "$OUT"
check_match "t: the relaunch failure is named" 'rootless not started: its dir .*/proc-t/wd does not exist' "$OUT"
check_match "t: the closing line counts it once" '^  Partial: 1 failed: rootless\. ' "$OUT"
check_match "t: the heal ledger says not recovered" '	drop-wd	rootless	not recovered$' "$(cat "$STATE/heals.tsv")"
mkdir -p "$T/proc-t/wd"
su_run --config "$CONF" --stop
check_status "t: stop afterwards" 0

# t2: a heal that fails is not followed by another start.
conf proc-t2 <<'CONF'
[service flaky]
stage = services
start = echo started >> "$STACK_STATE/starts"; printf 'cache is %s\n' stale; exit 1
ready = alive 1
[heal clear]
for = flaky
when_log = cache is stale
run = exit 7
CONF
su_run --config "$CONF" --yes
check_status "t2: a heal that fails" 1
check_match "t2: the heal ran" 'flaky: trying heal clear once' "$OUT"
testing_check "t2: the service was started once" 1 "$(LC_ALL=C grep -c . "$STATE/starts")"
check_match "t2: the ledger has the heal's exit status" '	clear	flaky	exit=7$' "$(cat "$STATE/heals.tsv")"
check_match "t2: the ledger says not recovered" '	clear	flaky	not recovered$' "$(cat "$STATE/heals.tsv")"
check_no_match "t2: it is never called recovered" 'recovered after heal' "$OUT"

# u: an env_file that is missing or cannot be read fails its entry before the
# command runs, for a job, a service and an env provider alike.
conf proc-u1 <<'CONF'
[job seed]
stage = setup
pick = yes
env_file = ${STACK_ROOT}/missing.env
run = echo "seed-ran target=${DATABASE_URL:-builtin}"
CONF
su_run --config "$CONF" --yes
check_status "u: a job whose env_file is missing" 1
check_match "u: the job's env_file is named" 'seed not started: its env_file .*/proc-u1/missing\.env cannot be read' "$OUT"
check_match "u: the job's run stops there, as its on_fail says" 'STOPPED  seed failed and its on_fail is abort' "$OUT"
check_no_match "u: the job's run does not claim open" 'Open:' "$OUT"
check_no_match "u: the job never ran" 'seed-ran' "$(cat "$STATE/logs/seed.log" 2>/dev/null)"
conf proc-u2 <<'CONF'
[service api]
stage = services
env_file = ${STACK_ROOT}/folder.env
start = echo "api-ran"; exec sleep "303.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$T/proc-u2/folder.env"
su_run --config "$CONF" --yes
check_status "u: a service whose env_file is a folder" 1
check_match "u: the service's env_file is named" 'api not started: its env_file .*/proc-u2/folder\.env cannot be read' "$OUT"
check_no_match "u: the service never started" 'api-ran' "$(cat "$STATE/logs/api.log" 2>/dev/null)"
testing_check "u: no launch was recorded for the service" "" "$(record_field "$STATE/run/launched.tsv" api 3 2>/dev/null)"
conf proc-u3 <<'CONF'
[env secrets]
stage = setup
env_file = ${STACK_ROOT}/missing.env
run = echo "provider-ran" >&2; echo TOKEN=1
[service consumer]
stage = services
env_from = secrets
start = echo "consumer-ran"; exec sleep "303.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "u: an env provider whose env_file is missing" 1
check_match "u: the provider's env_file is named" 'secrets not started: its env_file .*/proc-u3/missing\.env cannot be read' "$OUT"
check_no_match "u: the provider never ran" 'provider-ran' "$(cat "$STATE/logs/secrets.log" 2>/dev/null)"
check_no_match "u: its consumer is not started without its values" 'consumer-ran' "$(cat "$STATE/logs/consumer.log" 2>/dev/null)"

# u4: an env_file that exists but cannot be read fails the same way.
if [ "$(id -u)" != 0 ]; then
conf proc-u4 <<'CONF'
[job seed]
stage = setup
pick = yes
env_file = ${STACK_ROOT}/locked.env
run = echo "seed-ran target=${DATABASE_URL:-builtin}"
CONF
printf 'DATABASE_URL=dbscheme://locked\n' >| "$T/proc-u4/locked.env"
chmod 000 "$T/proc-u4/locked.env"
su_run --config "$CONF" --yes
chmod 600 "$T/proc-u4/locked.env"
check_status "u4: a job whose env_file cannot be read" 1
check_match "u4: the unreadable env_file is named" 'seed not started: its env_file .*/proc-u4/locked\.env cannot be read' "$OUT"
check_match "u4: the hint fits a file that exists" 'make .*/proc-u4/locked\.env a readable file, or remove env_file from \[job seed\]' "$OUT"
check_no_match "u4: the job never ran" 'seed-ran' "$(cat "$STATE/logs/seed.log" 2>/dev/null)"
else
  printf 'SKIP  u4: running as root, where no file is unreadable\n'
fi

# u5: a readable env_file that is not a regular file, such as /dev/null, is read.
conf proc-u5 <<'CONF'
[job seed]
stage = setup
pick = yes
env_file = /dev/null
run = echo "seed-ran"
CONF
su_run --config "$CONF" --yes
check_status "u5: an env_file of /dev/null" 0
check_match "u5: the job ran" 'seed-ran' "$(cat "$STATE/logs/seed.log" 2>/dev/null)"
check_no_match "u5: the child read the file too" 'is not readable' "$(cat "$STATE/logs/seed.log" 2>/dev/null)"

# u6: ${PORT} in a service's dir, env_file, files, needs and log is its own
# port, as its child sees it.
pick_free_port || testing_check "u6: free port" found none
PORT_U6=$FREE_PORT
conf proc-u6 <<CONF
[service api]
stage = services
port = $PORT_U6
dir = \${STACK_ROOT}/wd-\${PORT}
env_file = \${STACK_ROOT}/api-\${PORT}.env
needs = \${STACK_ROOT}/ready-\${PORT}.flag
files = \${STACK_ROOT}/cert-\${PORT}.pem
log = \${STACK_ROOT}/api-\${PORT}.log
start = echo "api DB_NAME=\${DB_NAME:-unset}"; exec sleep "312.$SU_TEST_TAG"
ready = alive 1
CONF
mkdir -p "$T/proc-u6/wd-$PORT_U6"
printf 'DB_NAME=right-db\n' >| "$T/proc-u6/api-$PORT_U6.env"
: >| "$T/proc-u6/ready-$PORT_U6.flag"
: >| "$T/proc-u6/cert-$PORT_U6.pem"
su_run --config "$CONF" --yes
check_status "u6: a service whose paths use its own port" 0
check_match "u6: the port-named env_file reached the child, and the port-named log holds its output" 'api DB_NAME=right-db' "$(cat "$T/proc-u6/api-$PORT_U6.log" 2>/dev/null)"
su_run --config "$CONF" --stop
check_status "u6: stop" 0

# u10: ${PORT} in the ready value of a service with a port is that port; the
# single quotes keep the shell from supplying it, so only the engine can.
pick_free_port || testing_check "u10: free port" found none
PORT_U10=$FREE_PORT
conf proc-u10 <<CONF
[service portcheck]
stage = services
port = $PORT_U10
start = exec sleep "316.$SU_TEST_TAG"
ready = cmd test '\${PORT}' = $PORT_U10
ready_timeout = 5
CONF
su_run --config "$CONF" --plan
check_status "u10: the plan accepts \${PORT} in the ready value of a service with a port" 0
su_run --config "$CONF" --yes
check_status "u10: the probe saw the service's own port" 0
check_match "u10: ready" 'portcheck ready' "$OUT"
su_run --config "$CONF" --stop
check_status "u10: stop" 0

# u11: ${STACK_ROOT} in a cmd probe is left to bash, so a root whose name holds
# a quote, a $1 and a backquoted command is read as a path, never run.
odd_root=$T/u11/'it'"'"'s $1 `touch PWNED`'
mkdir -p "$odd_root"
printf '%s\n' '[stack]' 'name = proc-u11' 'stages = setup services' 'keep_awake = off' 'default_select = all' '[service odd]' 'stage = services' 'start = exec sleep "328.$SU_TEST_TAG"' 'ready = cmd test -d "${STACK_ROOT}"' 'ready_timeout = 5' >| "$odd_root/stack.conf"
su_run --config "$odd_root/stack.conf" --yes
check_status "u11: a cmd probe that names a root with shell characters" 0
check_match "u11: ready" 'odd ready' "$OUT"
testing_check "u11: nothing in the root's name was run" "" "$(find "$T" -name PWNED)"
su_run --config "$odd_root/stack.conf" --stop
check_status "u11: stop" 0

# u7: an [env] provider honours needs and precheck like every other entry.
conf proc-u7 <<'CONF'
[env secrets]
stage = setup
precheck = false
run = echo "provider-ran" >&2; echo TOKEN=1
[service consumer]
stage = services
env_from = secrets
start = echo "consumer-ran"; exec sleep "313.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "u7: a provider whose precheck fails" 1
check_match "u7: the precheck is named" 'secrets not started: its precheck failed' "$OUT"
check_no_match "u7: the provider never ran" 'provider-ran' "$(cat "$STATE/logs/secrets.log" 2>/dev/null)"
check_no_match "u7: its consumer is not started" 'consumer-ran' "$(cat "$STATE/logs/consumer.log" 2>/dev/null)"
conf proc-u7b <<'CONF'
[env secrets]
stage = setup
needs = ${STACK_ROOT}/credentials.json
run = echo "provider-ran" >&2; echo TOKEN=1
[service consumer]
stage = services
env_from = secrets
start = echo "consumer-ran"; exec sleep "313.$SU_TEST_TAG"
ready = alive 1
CONF
su_run --config "$CONF" --yes
check_status "u7: a provider whose needs path is missing" 1
check_match "u7: the missing path is named" 'secrets not started: .*/proc-u7b/credentials\.json is missing' "$OUT"

# u8: a rerun whose env_file is gone fails before it stops the running copy.
conf proc-u8 <<'CONF'
[service keeper]
stage = services
env_file = ${STACK_ROOT}/keeper.env
start = exec sleep "314.$SU_TEST_TAG"
ready = alive 1
CONF
printf 'A=1\n' >| "$T/proc-u8/keeper.env"
su_run --config "$CONF" --yes
check_status "u8: the first run" 0
first=$(record_field "$STATE/run/launched.tsv" keeper 3)
mv "$T/proc-u8/keeper.env" "$T/proc-u8/keeper.env.away"
su_run --config "$CONF" --yes
check_status "u8: a rerun whose env_file is gone" 1
check_match "u8: the env_file is named" 'keeper not started: its env_file .*/proc-u8/keeper\.env cannot be read' "$OUT"
check_no_match "u8: the running copy is not stopped" 'stopping the copy this stack started earlier' "$OUT"
check_match "u8: the output says the earlier copy was kept" 'keeper: the copy an earlier run started was not stopped' "$OUT"
testing_check "u8: the copy from the first run still runs" yes "$(kill -0 "$first" 2>/dev/null && echo yes || echo no)"
mv "$T/proc-u8/keeper.env.away" "$T/proc-u8/keeper.env"
su_run --config "$CONF" --stop
check_status "u8: stop" 0

# v: a port that answers while lsof lists no listener on it is held by a
# program this account cannot see; the run stops without a PID to name, and
# nothing is signalled.
mkdir -p "$T/hide-lsof"
printf '%s\n' '#!/bin/bash' 'for arg in "$@"; do' '  case $arg in -iTCP*) exit 1 ;; esac' 'done' 'exec /usr/sbin/lsof "$@"' >| "$T/hide-lsof/lsof"
chmod +x "$T/hide-lsof/lsof"
pick_free_port || testing_check "v: free port" found none
PORT_V=$FREE_PORT
set -m
nc -lk 127.0.0.1 "$PORT_V" </dev/null >/dev/null 2>&1 &
HOLDER_V=$!
set +m
tries=0
while ! nc -z 127.0.0.1 "$PORT_V" >/dev/null 2>&1 && [ "$tries" -lt 25 ]; do
  sleep 0.2
  tries=$((tries + 1))
done
conf proc-v <<CONF
[service hidden]
stage = services
port = $PORT_V
start = exec sleep "324.\$SU_TEST_TAG"
ready = alive 1
CONF
PATH="$T/hide-lsof:$PATH" su_run --config "$CONF" --yes
check_status "v: a port whose holder this account cannot see" 1
check_match "v: it is refused without a PID" "port $PORT_V for hidden answers connections, but its owner is not visible to this account" "$OUT"
testing_check "v: nothing was launched" 0 "$(cat "$STATE/run/launched.tsv" 2>/dev/null | LC_ALL=C grep -c .)"
testing_check "v: the holder is still alive" alive "$(kill -0 "$HOLDER_V" 2>/dev/null && echo alive || echo gone)"
su_run --config "$CONF" --stop
kill "$HOLDER_V"
wait "$HOLDER_V" 2>/dev/null

# v2: a port held by a group this stack recorded under another entry is
# named with that entry, since --stop frees it.
pick_free_port || testing_check "v2: free port" found none
PORT_V2=$FREE_PORT
conf proc-v2 <<CONF
[service alpha]
stage = services
port = $PORT_V2
start = exec nc -lk 127.0.0.1 "\$PORT"
ready = port
[service beta]
stage = services
port = $PORT_V2
start = exec nc -lk 127.0.0.1 "\$PORT"
ready = port
CONF
su_run --config "$CONF" --select alpha --yes
check_status "v2: alpha holds the port" 0
su_run --config "$CONF" --select beta --yes
check_status "v2: beta on alpha's port" 1
check_match "v2: the holder is named as this stack's alpha" "port $PORT_V2 for beta is held by alpha \\(PID [0-9]+\\), which this stack started in an earlier run" "$OUT"
check_no_match "v2: it is never called foreign" 'did not start' "$OUT"
su_run --config "$CONF" --stop
check_status "v2: stop" 0
check_match "v2: stop frees the port" 'stopped alpha' "$OUT"

# u9: a known_defect_check never runs without the entry's env_file.
conf proc-u9 <<'CONF'
[job seed]
stage = setup
pick = yes
env_file = ${STACK_ROOT}/missing.env
known_defect_check = true
run = echo "seed-ran"
CONF
su_run --config "$CONF" --yes
check_status "u9: a known_defect_check whose entry's env_file is missing" 1
check_match "u9: the env_file is named" 'seed not started: its env_file .*/proc-u9/missing\.env cannot be read' "$OUT"
check_no_match "u9: it is not skipped as a defect" 'seed skipped' "$OUT"

tries=0
while [ -n "$(test_sleepers)" ] && [ "$tries" -lt 25 ]; do
  sleep 0.2
  tries=$((tries + 1))
done
testing_check "no test process is left running" "" "$(test_sleepers)"

testing_verdict
