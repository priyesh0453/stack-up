#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # single-quoted $ is literal config or shell text on purpose
# unit-contract.sh - the config contract: verify -> backup -> repair -> verify
# against a fake settings store (a file under the state folder), through the
# real CLI. Covers repair success, repair failure with the target unchanged or
# changed, a failing backup command, gates (which run whenever a check they
# gate runs), --no-repair, advisory checks, repair = ask without a terminal,
# --check (which counts a gated check apart from an unmet one), a target that
# cannot be copied, a target that does not exist yet, and a repair log that
# cannot be written.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

make_conf() {
  local name=$1 file=$T/$1/stack.conf
  mkdir -p "$T/$name"
  {
    printf '[stack]\nname = %s\nstages = prepare build\nkeep_awake = off\n' "$name"
    [ -z "${EXTRA_STACK:-}" ] || printf '%s\n' "$EXTRA_STACK"
    printf '\n[job seed]\nstage = prepare\nalways = yes\n'
    printf 'run = mkdir -p "$STACK_STATE/store" && printf '"'"'region=dev\\n'"'"' > "$STACK_STATE/store/app.env"\n'
    printf '\n[job consumer]\nstage = build\nalways = yes\non_fail = count\n'
    default_run='grep "^api_url=" "$STACK_STATE/store/app.env"'
    printf 'run = %s\n\n' "${CONSUMER_RUN:-$default_run}"
    cat
  } >> "$file"
  CONF=$file
  STATE=$(state_of "$name")
}

API_CHECK='[check api-url]
stage = prepare
dependent = consumer
probe = grep -q "^api_url=" "$STACK_STATE/store/app.env"
target = ${STACK_STATE}/store/app.env
consequence = consumer would call an empty address'
GOOD_REPAIR='repair = f="$STACK_STATE/store/app.env"; { cat "$f"; printf "api_url=http://127.0.0.1:8001\\n"; } > "$f.next" && mv "$f.next" "$f"'

# A: the repair works; the original is kept first.
make_conf contract-a <<CONF
$API_CHECK
$GOOD_REPAIR
CONF
su_run --config "$CONF" --yes
check_status "A: repair succeeds" 0
check_match "A: says missing, repairing" 'check api-url: missing, repairing' "$OUT"
check_match "A: repaired and re-verified" 'check api-url: repaired and re-verified' "$OUT"
check_match "A: consumer ran after the repair" 'job consumer finished' "$OUT"
backup=""
for path in "$STATE"/backups/api-url-*.bak; do [ -e "$path" ] && backup=$path; done
testing_check "A: one backup was written" 1 "$(count_files "$STATE/backups" "api-url-*.bak")"
testing_check "A: backup holds the original" "region=dev" "$(cat "$backup")"
testing_check "A: backup mode is 600" "-rw-------" "$(mode_of "$backup")"
testing_check "A: backups folder mode is 700" "drwx------" "$(mode_of "$STATE/backups")"
audit=$(cat "$STATE/repair.log")
check_match "A: audit block header" '^=== [0-9-]+ [0-9:]+ check api-url$' "$audit"
check_match "A: audit names the backup" '^result: written, original kept at .*api-url-[0-9]+\.bak$' "$audit"
check_match "A: audit records the re-verify" '^re-verify: satisfied$' "$audit"

# A2: the seed job rewrites the store on every run, so a second run finds the
# key missing again, repairs it again and adds one more audit block.
su_run --config "$CONF" --yes
check_status "A2: rerun" 0
blocks_before=$(printf '%s\n' "$audit" | LC_ALL=C grep -c '^=== ')
check_match "A2: seed rewrote the store, so the check repairs again" 'repaired and re-verified' "$OUT"
testing_check "A2: one more audit block" $((blocks_before + 1)) "$(LC_ALL=C grep -c '^=== ' "$STATE/repair.log")"

# H: --check probes only and repairs nothing.
su_run --config "$CONF" --check
check_status "H: --check after a repaired run" 0
check_match "H: --check lists the check as satisfied" 'api-url +required +satisfied' "$OUT"
printf 'region=dev\n' >| "$STATE/store/app.env"
su_run --config "$CONF" --check
check_status "H: --check with the key missing" 1
testing_check "H: --check did not repair" "region=dev" "$(cat "$STATE/store/app.env")"

# B: the repair fails without touching the target.
make_conf contract-b <<CONF
$API_CHECK
repair = exit 1
CONF
su_run --config "$CONF" --yes
check_status "B: failed repair is partial" 1
check_match "B: the check is still unmet" 'check api-url is still unmet after its repair' "$OUT"
check_match "B: the dependent is not started" 'consumer not started: required check api-url is unmet' "$OUT"
check_match "B: fault names local configuration" 'WHO +LOCAL CONFIGURATION' "$OUT"
check_match "B: closing line is Partial" '^  Partial: ' "$OUT"
check_match "B: audit says target unchanged, measured" 'result: FAILED \(exit 1\), target unchanged \(compared with the backup\)' "$(cat "$STATE/repair.log")"
check_match "B: history row is partial with exit 1" '	start	partial	exit=1 ' "$(cat "$STATE/history.tsv")"

# C: the repair damages the target and then fails; the audit says so.
make_conf contract-c <<CONF
$API_CHECK
repair = printf 'garbage\n' > "\$STACK_STATE/store/app.env"; exit 1
CONF
su_run --config "$CONF" --yes
check_status "C: damaging repair is partial" 1
check_match "C: audit says the target changed and where the original is" 'result: FAILED \(exit 1\), target CHANGED; original kept at .*\.bak' "$(cat "$STATE/repair.log")"

# D: a failing backup command stops the repair before it runs.
make_conf contract-d <<'CONF'
[check api-url]
stage = prepare
dependent = consumer
probe = grep -q "^api_url=" "$STACK_STATE/store/app.env"
backup = exit 3
repair = touch "$STACK_STATE/repair-ran"
CONF
su_run --config "$CONF" --yes
check_status "D: failed backup is partial" 1
check_match "D: says the repair was not attempted" 'its backup command failed, so the repair was not attempted' "$OUT"
testing_check "D: the repair never ran" no "$( [ -e "$STATE/repair-ran" ] && echo yes || echo no)"

# E: a check behind a failing gate reports "not checked" once.
make_conf contract-e <<CONF
[check store-up]
stage = prepare
dependent = consumer
probe = test -d "\$STACK_STATE/no-such-store"
$API_CHECK
gate = store-up
$GOOD_REPAIR
CONF
su_run --config "$CONF" --yes
check_status "E: failing gate is partial" 1
check_match "E: gated check is not checked" 'check api-url not checked: its gate store-up did not pass' "$OUT"
testing_check "E: the gated repair did not run" no "$( [ -e "$STATE/repair.log" ] && LC_ALL=C grep -q 'check api-url' "$STATE/repair.log" && echo yes || echo no)"
testing_check "E: one counted failure for the gate plus one for the blocked consumer" 2 "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c '^    x  ')"
su_run --config "$CONF" --check
check_status "E: --check with the gate unmet" 1
check_match "E: --check counts the gated check as not checked, not unmet" '1 required check\(s\) unmet, 1 not checked' "$OUT"

# E2: a required check that was not checked fails --check on its own, with no
# required check unmet.
make_conf contract-e2 <<CONF
[check store-up]
stage = prepare
level = advisory
probe = test -d "\$STACK_STATE/no-such-store"
$API_CHECK
gate = store-up
CONF
su_run --config "$CONF" --check
check_status "E2: --check with a required check not checked" 1
check_match "E2: it is counted as not checked" '0 required check\(s\) unmet, 1 not checked' "$OUT"

# F: --no-repair reports and leaves the target alone.
make_conf contract-f <<CONF
$API_CHECK
$GOOD_REPAIR
CONF
su_run --config "$CONF" --yes --no-repair
check_status "F: --no-repair with an unmet check" 1
check_match "F: says repair is off" 'check api-url is unmet; repair is off' "$OUT"
testing_check "F: target untouched" "region=dev" "$(cat "$STATE/store/app.env")"
testing_check "F: no backup was taken" no "$( [ -d "$STATE/backups" ] && echo yes || echo no)"

# G: an unmet advisory check warns but does not change the exit code.
CONSUMER_RUN=true make_conf contract-g <<'CONF'
[check nice-to-have]
stage = prepare
level = advisory
probe = test -f "$STACK_STATE/optional-cache"
consequence = the first page load is slower
CONF
su_run --config "$CONF" --yes
check_status "G: advisory only" 0
check_match "G: one warning for advisory checks" '1 advisory check\(s\) unmet' "$OUT"
check_match "G: the closing line still reports it" '^  Open: everything that started is running \(1 advisory check\(s\) unmet\)' "$OUT"

# I: repair = ask fails closed when nobody can answer.
EXTRA_STACK='repair = ask' make_conf contract-i <<CONF
$API_CHECK
$GOOD_REPAIR
CONF
su_run --config "$CONF" --yes
check_status "I: repair = ask without a terminal" 1
check_match "I: the repair was declined" 'the repair was declined' "$OUT"
testing_check "I: target untouched" "region=dev" "$(cat "$STATE/store/app.env")"

if [ "$(id -u)" != 0 ]; then
  # J: a target that cannot be copied is never repaired.
  CONSUMER_RUN=true make_conf contract-j <<'CONF'
[check locked]
stage = prepare
dependent = consumer
probe = grep -q '^api_url=' "$STACK_STATE/store/locked.env"
target = ${STACK_STATE}/store/locked.env
repair = f="$STACK_STATE/store/locked.env"; { cat "$f"; printf "api_url=http://127.0.0.1:8001\n"; } > "$f.next" && mv "$f.next" "$f"
CONF
  mkdir -p "$STATE/store"
  printf 'region=dev\n' >| "$STATE/store/locked.env"
  chmod 000 "$STATE/store/locked.env"
  su_run --config "$CONF" --yes
  chmod 600 "$STATE/store/locked.env"
  check_status "J: a target that cannot be copied" 1
  check_match "J: the repair is not attempted" 'the backup of .*/locked\.env failed, so the repair was not attempted' "$OUT"
  testing_check "J: the target is unchanged" "region=dev" "$(cat "$STATE/store/locked.env")"
  testing_check "J: no backup was kept" 0 "$(count_files "$STATE/backups" 'locked-*.bak')"
  check_match "J: the audit says the copy failed" 'result: FAILED, could not copy' "$(cat "$STATE/repair.log")"

  # K: a repair whose audit log cannot be written does not run.
  make_conf contract-k <<CONF
$API_CHECK
$GOOD_REPAIR
CONF
  su_run --config "$CONF" --yes
  check_status "K: the first run repairs and writes the audit log" 0
  chmod 444 "$STATE/repair.log"
  su_run --config "$CONF" --yes
  chmod 644 "$STATE/repair.log"
  check_status "K: a repair log that cannot be written" 1
  check_match "K: the repair is not attempted" 'its repair log .*/repair\.log cannot be written, so the repair was not attempted' "$OUT"
  testing_check "K: the target is unchanged" "region=dev" "$(cat "$STATE/store/app.env")"
  testing_check "K: no second backup was taken" 1 "$(count_files "$STATE/backups" 'api-url-*.bak')"
else
  printf 'SKIP  J and K: running as root, where no file is unreadable or read-only\n'
fi

# L: a target that does not exist yet has nothing to lose, so the repair runs
# with no copy, and the audit says so.
CONSUMER_RUN=true make_conf contract-l <<'CONF'
[check absent]
stage = prepare
dependent = consumer
probe = test -f "$STACK_STATE/store/absent.txt"
target = ${STACK_STATE}/store/absent.txt
repair = touch "$STACK_STATE/store/absent.txt"
CONF
su_run --config "$CONF" --yes
check_status "L: a repair whose target does not exist yet" 0
check_match "L: the audit says there was nothing to copy" '^backup: .*/absent\.txt did not exist, nothing to copy$' "$(cat "$STATE/repair.log")"
testing_check "L: no backups folder was made" no "$( [ -e "$STATE/backups" ] && echo yes || echo no)"

# M: a gate runs whenever a check it gates runs, even when its own dependent
# is not selected; a gate that fails still leaves the gated check not checked.
gated_conf() {
  CONSUMER_RUN=true make_conf "$1" <<CONF
[job other]
stage = build
run = true
[check reach]
stage = prepare
dependent = other
probe = $2
[check schema]
stage = prepare
dependent = consumer
gate = reach
probe = true
CONF
}
gated_conf contract-m true
su_run --config "$CONF" --yes
check_status "M: a gate whose own dependent is not selected" 0
check_match "M: the gate runs" 'check reach: satisfied' "$OUT"
check_no_match "M: the gated check is checked" 'not checked' "$OUT"
gated_conf contract-m2 false
su_run --config "$CONF" --yes
check_status "M: a gate that fails" 1
check_match "M: the gated check is not checked" 'check schema not checked: its gate reach did not pass' "$OUT"
check_match "M: its dependent does not start" 'consumer not started' "$OUT"

testing_verdict
