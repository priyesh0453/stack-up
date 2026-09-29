#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# e2e-demo.sh - the README quickstart, run as written, on free loopback ports:
# plan, up, curl each service, stop. Then the records it leaves, a decoy
# listener this test owns (stack-up must leave it alone), a foreign holder on
# a demo port, a degraded run, a rerun, every tier with the ticker, and the
# housekeeping flags. The only processes it signals itself are the decoy and
# the holder it started.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

STATE=$(state_of demo)
pick_free_port || { testing_check "free port for hello-api" found none; testing_verdict; }
API=$FREE_PORT
pick_free_port || { testing_check "free port for docs-site" found none; testing_verdict; }
DOCS=$FREE_PORT
pick_free_port || { testing_check "free port for the decoy" found none; testing_verdict; }
DECOY_PORT=$FREE_PORT
render_demo_config "$DEMO/stack.conf" "$T/stack.conf" "$API" "$DOCS"
testing_check "the demo renders onto two picked ports" 0 "$?"

set -m
nc -lk 127.0.0.1 "$DECOY_PORT" </dev/null >/dev/null 2>&1 &
DECOY=$!
set +m
sleep 0.5
testing_check "the decoy listener is up" "$DECOY" "$(lsof -nP -iTCP:"$DECOY_PORT" -sTCP:LISTEN -t 2>/dev/null)"

steps=$(awk '/<!-- quickstart:begin -->/ { on = 1; next } /<!-- quickstart:end -->/ { on = 0 } on && !/^```/ && NF' "$REPO/README.md")
testing_check "the README has a quickstart block with 5 commands" 5 "$(printf '%s\n' "$steps" | LC_ALL=C grep -c .)"

run_step() {
  local line=$1 attempt=0
  case $line in
    'bin/stack-up '*|'curl '*) ;;
    *)
      testing_check "README quickstart line is runnable as written" "bin/stack-up or curl" "$line"
      return 1
      ;;
  esac
  line=${line//examples\/demo\/stack.conf/$(LC_ALL=C; printf '%q' "$T/stack.conf") --root $(LC_ALL=C; printf '%q' "$DEMO")}
  line=${line//18081/$API}
  line=${line//18082/$DOCS}
  while :; do
    OUT=$(cd "$REPO" && /bin/bash -c "$line" </dev/null 2>&1)
    STATUS=$?
    # nc answers one connection per run; a curl that lands in the few
    # milliseconds between two runs is refused (exit 7) and tried once more.
    case $line in
      curl*) [ "$STATUS" = 7 ] && [ "$attempt" = 0 ] || break ;;
      *) break ;;
    esac
    attempt=1
    sleep 0.3
  done
}

i=0
while IFS= read -r line; do
  i=$((i + 1))
  run_step "$line"
  case $i in
    1)
      check_status "quickstart 1: --plan" 0
      check_match "plan lists the seed job" 'job settings-seed' "$OUT"
      check_match "plan lists the contract check and its backup" 'backup +copy of .*demo-settings\.env, taken first' "$OUT"
      check_match "plan shows the ticker off" 'ticker: off \(option ticker\)' "$OUT"
      check_match "plan shows what is not selected" 'not selected: legacy-worker' "$OUT"
      testing_check "plan wrote nothing" no "$( [ -e "$STATE" ] && echo yes || echo no)"
      ;;
    2)
      # Read before anything else: the double also ends on its own within a
      # second of the run, so only an immediate look shows the run stopped it.
      testing_check "keep-awake was stopped by the run as it exited" "" "$(pgrep -f "$T/shims/caffeinate")"
      check_status "quickstart 2: up" 0
      check_match "the seed job ran" 'job settings-seed finished' "$OUT"
      check_match "the contract repaired the missing key" 'check greeting: missing, repairing' "$OUT"
      check_match "the contract re-verified it" 'check greeting: repaired and re-verified' "$OUT"
      check_match "hello-api ready on its port" "hello-api ready :$API" "$OUT"
      check_match "docs-site ready on its port" "docs-site ready :$DOCS" "$OUT"
      check_match "smoke check passed" "smoke check: http://127.0.0.1:$API/health answered 200" "$OUT"
      check_match "closing line is Open with the URL" "^  Open http://127.0.0.1:$API/health$" "$OUT"
      check_match "summary lists each service's url" "hello-api is at http://127\\.0\\.0\\.1:$API/\$" "$OUT"
      hint=$(printf '%s\n' "$OUT" | LC_ALL=C sed -n 's/^  Stop it with  //p')
      check_match "the stop hint ends with --stop" ' --stop$' "$hint"
      hint_out=$(cd "$T" && /bin/bash -c "${hint% --stop} --print-paths" </dev/null 2>&1)
      testing_check "the stop hint's command runs as printed, from another folder" "0 yes" "$? $(printf '%s\n' "$hint_out" | LC_ALL=C grep -q '^stack-up paths for demo$' && echo yes || echo no)"
      ;;
    3)
      check_status "quickstart 3: curl hello-api" 0
      testing_check "hello-api answers with the repaired greeting" "hello from the demo stack" "$OUT"
      ;;
    4)
      check_status "quickstart 4: curl docs-site" 0
      check_match "docs-site serves the page" 'docs-site is up' "$OUT"
      run_log=$(newest_run_log "$STATE")
      check_match "run log: VERDICT record" 'VERDICT open exit=0 selected=\[settings-seed,hello-api,docs-site,ticker\]' "$(cat "$run_log")"
      check_match "run log: line format date, two spaces, tag padded to 7" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}  OK      hello-api ready' "$(cat "$run_log")"
      check_match "history: one start row, open, exit 0" '^[0-9-]+ [0-9:]+	start	open	exit=0 version=0\.1\.0 ' "$(cat "$STATE/history.tsv")"
      testing_check "launch table: two records" 2 "$(LC_ALL=C grep -c '|service|' "$STATE/run/launched.tsv")"
      LAUNCHED=$(awk -F'|' '{ print $3 ":" $4 }' "$STATE/run/launched.tsv")
      for pair in $LAUNCHED; do
        testing_check "launch table: pid equals pgid for ${pair%%:*}" "${pair%%:*}" "${pair#*:}"
      done
      check_match "hello-api listens on loopback only" "127\\.0\\.0\\.1:$API \\(LISTEN\\)" "$(lsof -nP -iTCP:"$API" -sTCP:LISTEN)"
      check_no_match "no demo listener on all interfaces" "\\*:($API|$DOCS)" "$(lsof -nP -iTCP -sTCP:LISTEN)"
      check_match "keep-awake was requested with the run's pid" '^caffeinate -i -w [0-9]+$' "$(cat "$SHIM_LOG")"
      testing_check "keep-awake was released when the run ended" "" "$(pgrep -f "$T/shims/caffeinate")"
      ;;
    5)
      check_status "quickstart 5: --stop" 0
      check_match "stop closing line" 'Everything this stack recorded is down\. Safe to power off the machine\.' "$OUT"
      for pair in $LAUNCHED; do
        testing_check "launched pid ${pair%%:*} is gone" gone "$(kill -0 "${pair%%:*}" 2>/dev/null && echo alive || echo gone)"
        testing_check "launched group ${pair#*:} is gone" gone "$(group_alive "${pair#*:}" && echo alive || echo gone)"
      done
      testing_check "the decoy started by this test is untouched" alive "$(kill -0 "$DECOY" 2>/dev/null && echo alive || echo gone)"
      testing_check "the decoy still listens" "$DECOY" "$(lsof -nP -iTCP:"$DECOY_PORT" -sTCP:LISTEN -t 2>/dev/null)"
      check_no_match "no run log line names the decoy" "(^|[^0-9])$DECOY([^0-9]|$)" "$(cat "$STATE"/logs/run-*.log)"
      check_match "history: a stop row, down, exit 0" '	stop	down	exit=0 ' "$(cat "$STATE/history.tsv")"
      ;;
  esac
done <<STEPS
$steps
STEPS

CONF=$T/stack.conf
SU=(--config "$CONF" --root "$DEMO")

# Rerun: the seed is not needed and the contract holds, so no repair runs.
# stack-up is on PATH for this run, so the stop hint may use the bare name; the
# run was given --root, so the hint carries it.
blocks=$(LC_ALL=C grep -c '^=== ' "$STATE/repair.log")
mkdir -p "$T/on-path"
ln -s "$STACK_UP" "$T/on-path/stack-up"
PATH="$T/on-path:$PATH" su_run "${SU[@]}" --yes
check_status "rerun" 0
check_match "with stack-up on PATH, the stop hint uses the bare name" "^  Stop it with  stack-up --config $T/stack\\.conf --root .* --stop\$" "$OUT"
check_match "and carries the run's --root" "^  Stop it with  .* --root .*/examples/demo'? --stop\$" "$OUT"
check_match "rerun: the seed is skipped" 'settings-seed: not needed \(run_if said no\)' "$OUT"
check_match "rerun: the check is satisfied" 'check greeting: satisfied' "$OUT"
testing_check "rerun: no new repair audit block" "$blocks" "$(LC_ALL=C grep -c '^=== ' "$STATE/repair.log")"
su_run "${SU[@]}" --check
check_status "--check after a good run" 0

# --select all with the ticker on reaches the known defect and the when_off =
# stop path, which the quickstart's recommended selection never runs.
su_run "${SU[@]}" --select all --with ticker --yes
check_status "all tiers with the ticker" 0
check_match "ticker is ready" 'ticker ready running' "$OUT"
check_match "the known defect is skipped, not counted" '~  legacy-worker skipped: demo entry' "$OUT"
check_match "the known defect gets a summary owner" 'WHO +UPSTREAM CODE' "$OUT"
check_match "history counts the defect" 'defects=\[legacy-worker\]' "$(tail -n 1 "$STATE/history.tsv")"
su_run "${SU[@]}" --select recommended --yes
check_status "back to the default option" 0
check_match "when_off = stop stopped the ticker" 'option ticker is off: stopped ticker' "$OUT"
su_run "${SU[@]}" --stop
check_status "stop after the tier runs" 0

# A degraded run: a test-only warn-policy job appended to a copy of the config.
cp "$CONF" "$T/degraded.conf"
printf '\n[job warm-cache]\nstage = prepare\nalways = yes\non_fail = warn\nrun = false\n' >> "$T/degraded.conf"
su_run --config "$T/degraded.conf" --root "$DEMO" --yes
check_status "degraded run" 3
check_match "degraded closing line" '^  Degraded: warm-cache did not finish \(on_fail = warn\);' "$OUT"
check_match "degraded VERDICT" 'VERDICT degraded exit=3' "$(cat "$(newest_run_log "$STATE")")"
su_run --config "$T/degraded.conf" --root "$DEMO" --stop
check_status "stop after degraded" 0

# A foreign program on a demo port is named and refused, never signalled.
pick_free_port || testing_check "free port for the holder" found none
HELD=$FREE_PORT
set -m
nc -lk 127.0.0.1 "$HELD" </dev/null >/dev/null 2>&1 &
HOLDER=$!
set +m
sleep 0.5
render_demo_config "$DEMO/stack.conf" "$T/held.conf" "$HELD" "$DOCS"
su_run --config "$T/held.conf" --root "$DEMO" --yes
check_status "up with a foreign holder on the hello-api port" 1
check_match "the holder is named with its PID" "port $HELD for hello-api is held by PID $HOLDER \\(nc\\), which this stack did not start" "$OUT"
check_match "nothing was started" 'preflight found 1 problem\(s\); nothing was started' "$OUT"
testing_check "the holder is alive after up" alive "$(kill -0 "$HOLDER" 2>/dev/null && echo alive || echo gone)"
su_run --config "$T/held.conf" --root "$DEMO" --stop
check_status "stop with the holder still there" 0
check_match "stop names the program on the declared port" "in use by programs this stack has no record of \\(left running\\): port $HELD by PID $HOLDER \\(nc\\)" "$OUT"
check_match "stop claims only what it recorded" 'Everything this stack recorded is down\.' "$OUT"
testing_check "the holder is alive after --stop" alive "$(kill -0 "$HOLDER" 2>/dev/null && echo alive || echo gone)"
check_no_match "no stop line names the holder" "stopped .*$HOLDER|group $HOLDER" "$OUT"
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null

# The housekeeping flags run last, once the stops above have left rotated
# launch tables for --clean to find.
su_run "${SU[@]}" --print-paths
check_status "--print-paths" 0
check_match "--print-paths names the state folder" "state +$STATE" "$OUT"
check_match "--print-paths says there is nothing to remove for this demo" 'no \[compose\] entries' "$OUT"
rotated=$(count_files "$STATE/run" "launched-*")
testing_check "stops left rotated launch tables to clean" yes "$( [ "$rotated" -gt 0 ] && echo yes || echo no)"
su_run "${SU[@]}" --clean
check_status "--clean with no terminal and no --yes" 1
check_match "--clean asked and was not confirmed" 'nothing deleted' "$OUT"
testing_check "nothing was deleted" "$rotated" "$(count_files "$STATE/run" "launched-*")"
logs_before=$(count_files "$STATE/logs" "run-*")
tables=$(for path in "$STATE"/run/launched-*; do [ -e "$path" ] && printf '%s\n' "$path"; done | LC_ALL=C sort)
su_run "${SU[@]}" --clean --yes
check_status "--clean --yes" 0
testing_check "rotated launch tables are gone" 0 "$(count_files "$STATE/run" "launched-*")"
testing_check "run logs are kept (keep_runs = 0), plus this clean run's own" $((logs_before + 1)) "$(count_files "$STATE/logs" "run-*")"
# Run log names are only second-resolution, so the clean run's log is found by
# its verdict, not by sort order.
clean_log=$(LC_ALL=C grep -l 'VERDICT cleaned exit=0 removed=[1-9]' "$STATE"/logs/run-*.log)
deleted=$(LC_ALL=C sed -n 's/^[0-9-]* [0-9:]*  INFO    deleted //p' "$clean_log" | LC_ALL=C sort)
check_match "--clean --yes leaves an ASK record of the consent" "ASK +Delete these $(printf '%s\n' "$deleted" | LC_ALL=C grep -c .) file\\(s\\)\\? They belong to this stack's state only\\. \\(--yes, so the answer is yes\\)\$" "$(cat "$clean_log")"
testing_check "the run log names every rotated launch table it deleted" "$tables" "$(printf '%s\n' "$deleted" | LC_ALL=C grep '/launched-')"
check_match "the deleted count matches the named files" "OK +deleted $(printf '%s\n' "$deleted" | LC_ALL=C grep -c .) file\\(s\\)\$" "$(cat "$clean_log")"

# A file that cannot be deleted is named, never counted, and the run exits 1.
# The immutable flag is cleared on any exit, so the test folder stays removable.
stuck=$STATE/run/launched-19990101-000000-1.tsv
: >> "$stuck"
trap 'chflags nouchg "$stuck" 2>/dev/null' EXIT
chflags uchg "$stuck"
su_run "${SU[@]}" --clean --yes
check_status "--clean --yes with a file that cannot be deleted" 1
check_match "the file is named" "could not delete $stuck\$" "$OUT"
check_match "the count is honest" 'deleted 0 of 1 file\(s\)' "$OUT"
failed_log=$(LC_ALL=C grep -l 'VERDICT failed exit=1 removed=0 of=1' "$STATE"/logs/run-*.log)
testing_check "the VERDICT says failed, in exactly one run log" 1 "$(printf '%s\n' "$failed_log" | LC_ALL=C grep -c .)"
check_match "that run log records the consent" "ASK +Delete these 1 file\\(s\\)\\? .*\\(--yes, so the answer is yes\\)\$" "$(cat "$failed_log")"
check_no_match "that run log does not claim it was deleted" "INFO +deleted $stuck" "$(cat "$failed_log")"
chflags nouchg "$stuck"
trap - EXIT
su_run "${SU[@]}" --clean --yes
check_status "--clean --yes once the file can be deleted" 0
testing_check "the file is gone" no "$( [ -e "$stuck" ] && echo yes || echo no)"

kill "$DECOY"
wait "$DECOY" 2>/dev/null
testing_check "no demo listener is left" "" "$(lsof -nP -iTCP:"$API" -sTCP:LISTEN -t 2>/dev/null)$(lsof -nP -iTCP:"$DOCS" -sTCP:LISTEN -t 2>/dev/null)"

testing_verdict
