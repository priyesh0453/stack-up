#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-classify.sh - failure classification against committed fixture logs,
# with signatures and owners from config. Asserts the signature id and the
# owner, so two signatures with one owner are told apart. No stack is started:
# the engine is sourced and its classifier is called on the fixtures directly.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=../bin/stack-up
. "$STACK_UP"

FIX=$TESTS_DIR/fixtures
SU_CONFIG=$FIX/classify.conf
SU_ROOT_OVERRIDE=""
su_load_config

expect() {
  local log=$FIX/logs/$1 kind=$2
  classify_log "$log" "$kind" >/dev/null
  testing_check "$1 as $kind: signature" "$3" "$CLASSIFY_ID"
  testing_check "$1 as $kind: owner" "$4" "$CLASSIFY_OWNER"
}

expect port-in-use.log service port-in-use this-machine
expect config-and-refused.log service missing-setting local-config
expect refused-only.log service refused upstream
expect ignored-noise.log service disk this-machine
expect panic.log service panic upstream
expect unknown.log service no-match needs-a-look
expect empty.log service empty-log this-machine
expect missing.log service empty-log this-machine
expect build-module.log job module build-tools
expect build-module.log service no-match needs-a-look
printf 'job output\n\377\376 invalid bytes before the match\naddress already in use\n' >> "$T/invalid-bytes.log"
classify_log "$T/invalid-bytes.log" service >/dev/null
testing_check "a log with invalid bytes still matches (C locale)" port-in-use "$CLASSIFY_ID"

su_owner_label upstream
testing_check "owner label from [owner upstream]" "UPSTREAM CODE" "$SU_LABEL"
su_owner_label build-tools
testing_check "a new owner id from [owner build-tools]" "BUILD TOOLS" "$SU_LABEL"
su_owner_label local-data
testing_check "built-in label for local-data" "LOCAL DATA" "$SU_LABEL"

# A fault is classified on the entry's own output, which is cut from its log
# by run id into the run folder, so the test gives it both, as a start does.
SU_RUN_ID=classify-test
SU_RUN_DIR=$T
out=$(su_fault_from_log "$FIX/logs/panic.log" service)
check_match "the fault names WHO" 'WHO +UPSTREAM CODE' "$out"
check_match "the fault names WHAT" 'WHAT +the service crashed' "$out"
check_match "the fault names the LOG" 'LOG +.*panic\.log' "$out"
check_match "owner advice is printed under the fault" 'open an issue' "$out"

testing_verdict
