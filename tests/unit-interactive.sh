#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-interactive.sh - the questions a person answers at a terminal, driven
# through the library's own test seam (PROMPT_TEST_SEAM=1, PROMPT_INTERACTIVE=1
# and PROMPT_TTY pointing at a file of answers, one per line; without the
# first, the library ignores the other two): option questions, the menu
# with a wrong answer then a right one, blank answers taking the default (with
# several menus, the default over every pickable entry), an answer device that
# cannot be opened, and repair = ask. Every answer is recorded as an ASK line
# in the run log.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

conf=$T/ask/stack.conf
write_conf "$conf" <<'CONF'
[stack]
name = ask
stages = prepare services
keep_awake = off
default_select = essential
repair = ask

[option extras]
question = Start the extras too?
default = no

[job seed]
stage = prepare
always = yes
run = mkdir -p "$STACK_STATE" && printf 'a=1\n' > "$STACK_STATE/settings.env"

[check has-b]
stage = prepare
dependent = web
probe = grep -q '^b=' "$STACK_STATE/settings.env"
target = ${STACK_STATE}/settings.env
repair = f="$STACK_STATE/settings.env"; { cat "$f"; echo b=2; } > "$f.next" && mv "$f.next" "$f"

[service web]
tier = essential
start = exec sleep 321
ready = alive 1

[service api]
tier = recommended
start = exec sleep 322
ready = alive 1

[service extra]
option = extras
start = exec sleep 323
ready = alive 1
CONF
STATE=$(state_of ask)

ask_run() {
  local answers=$1
  shift
  printf '%s' "$answers" >| "$T/answers"
  OUT=$(PROMPT_TEST_SEAM=1 PROMPT_INTERACTIVE=1 PROMPT_TTY=$T/answers /bin/bash "$STACK_UP" --config "$conf" "$@" </dev/null 2>&1)
  STATUS=$?
}
set +o noclobber

ask_run $'yes\nnosuch\n1,3\nyes\n'
check_status "interactive run" 0
check_match "the option question is asked" 'Start the extras too\?' "$OUT"
check_match "the menu is shown with tier marks" '1 \* web' "$OUT"
check_match "a wrong menu answer is explained" 'nothing matched "nosuch"; try again' "$OUT"
check_match "the repair question is asked" 'Repair check has-b now\? A backup is taken first\.' "$OUT"
check_match "the chosen entries start" 'extra ready running' "$OUT"
check_no_match "an entry that was not picked does not start" 'api ready' "$OUT"
log=$(cat "$(newest_run_log "$STATE")")
check_match "ASK record for the option" 'ASK     Start the extras too\? answered: yes' "$log"
check_match "ASK record for the wrong answer" 'ASK     Selection answered: nosuch' "$log"
check_match "ASK record for the right answer" 'ASK     Selection answered: 1,3' "$log"
check_match "ASK record for the repair consent" 'ASK     Repair check has-b now\? A backup is taken first\. answered: yes' "$log"
check_match "the repair ran after a yes" 'check has-b: repaired and re-verified' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

ask_run $'\n\n\n'
check_status "blank answers take the defaults" 1
check_match "blank option answer keeps it off" 'option extras: off \(answer\)' "$OUT"
check_match "blank menu answer uses default_select" 'selected by menu: web' "$OUT"
check_match "blank repair answer is no" 'the repair was declined' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

ask_run $'maybe\nperhaps\nlater\n\n\n'
check_match "three answers that are not yes or no keep the default, named as the default" 'option extras: off \(default\)' "$OUT"
check_match "the fallback to the default is recorded" 'ASK     Start the extras too\? \(3 answers were not yes or no, so the default "no" applies\)' "$(cat "$(newest_run_log "$STATE")")"
su_run --config "$conf" --stop
check_status "stop" 0

ask_run ''
check_status "no answers at all (end of input)" 1
check_match "end of input on the option keeps the default, named as the default" 'option extras: off \(default\)' "$OUT"
check_match "end of input is recorded" 'no answer could be read' "$(cat "$(newest_run_log "$STATE")")"
check_match "end of input on the menu names default_select, not the menu, as the source" 'selected by default_select \(essential\): web' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

OUT=$(PROMPT_TEST_SEAM=1 PROMPT_INTERACTIVE=1 PROMPT_TTY=$T/no-such-folder/tty /bin/bash "$STACK_UP" --config "$conf" </dev/null 2>&1)
STATUS=$?
check_status "an answer device that cannot be opened" 1
check_match "the device that cannot be opened is recorded, and the default applies" 'ASK     Start the extras too\? \(cannot open .*/no-such-folder/tty, so the default "no" applies\)' "$(cat "$(newest_run_log "$STATE")")"
check_match "that option keeps its default as the source" 'option extras: off \(default\)' "$OUT"
check_match "that selection names default_select, not the menu, as the source" 'selected by default_select \(essential\): web' "$OUT"
check_match "that repair gets no yes" 'the repair was declined' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

printf '%s' $'yes\n1,3\nyes\n' >| "$T/answers"
OUT=$(PROMPT_INTERACTIVE=1 PROMPT_TTY=$T/answers /bin/bash "$STACK_UP" --config "$conf" </dev/null 2>&1)
log=$(cat "$(newest_run_log "$STATE")")
check_match "without PROMPT_TEST_SEAM an exported answer file is ignored: no terminal" 'ASK     Start the extras too\? \(no terminal' "$log"
check_match "without a terminal the defaulted selection is recorded" 'ASK     Selection \(no terminal, so the default "essential" applies\)' "$log"
check_match "without a terminal the option keeps its default as the source" 'option extras: off \(default\)' "$OUT"
check_no_match "without PROMPT_TEST_SEAM the option stays off" 'extra ready' "$OUT"
check_no_match "without PROMPT_TEST_SEAM the repair gets no yes" 'repaired and re-verified' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

su_run --config "$conf" --yes
log=$(cat "$(newest_run_log "$STATE")")
check_match "--yes names itself as the reason on the option record" 'ASK     Start the extras too\? \(--yes, so the default "no" applies\)' "$log"
check_match "--yes names itself as the reason on the selection record" 'ASK     Selection \(--yes, so the default "essential" applies\)' "$log"
check_match "--yes names itself as the reason on the repair record" 'ASK     Repair check has-b now\? A backup is taken first\. \(--yes, so the default "no" applies\)' "$log"
su_run --config "$conf" --stop
check_status "stop" 0

# With several menus, blank answers to all of them select what a run without
# a terminal selects: default_select over every pickable entry, including one
# in no listed group, and no menu is asked again.
conf=$T/menus/stack.conf
write_conf "$conf" <<'CONF'
[stack]
name = menus
stages = services
menus = front back
default_select = essential
keep_awake = off

[service web]
tier = essential
groups = front
start = exec sleep 324
ready = alive 1

[service api]
tier = recommended
groups = back
start = exec sleep 325
ready = alive 1

[service core]
tier = essential
start = exec sleep 326
ready = alive 1
CONF
ask_run $'\n\n'
check_status "blank answers to two menus" 0
check_match "an essential entry in no group starts" 'core ready' "$OUT"
check_match "the essential entry of a menu starts" 'web ready' "$OUT"
check_no_match "a recommended entry does not" 'api ready' "$OUT"
check_no_match "a blank answer is never refused" 'nothing matched' "$OUT"
su_run --config "$conf" --stop
check_status "stop" 0

testing_verdict
