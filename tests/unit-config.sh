#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-config.sh - the config reader, through the real CLI: rows, literal
# values, CRLF endings, a last line without a newline, and --print-config and
# --check, which write no state.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

conf=$T/literal/stack.conf
mkdir -p "$T/literal"
{
  printf '%s\r\n' \
    '# a comment line' \
    '   # an indented comment' \
    '' \
    '[stack]' \
    'name = literal' \
    'stages = run' \
    '' \
    '[job pipes]' \
    'stage = run' \
    "run = printf '%s\\n' 'a|b=c # not a comment' | tr '|' '-'" \
    'description =   spaces around are trimmed   '
  printf '%s' '[job last]'
  printf '\r\nstage = run\r\nrun = echo "quoted \\"value\\""'
} >> "$conf"

su_run --config "$conf" --print-config
check_status "print-config of a valid file" 0
check_match "stack name row" '^stack\|\|name\|literal$' "$OUT"
check_match "value keeps |, = and # literally" "^job\\|pipes\\|run\\|printf '%s\\\\n' 'a\\|b=c # not a comment' \\| tr '\\|' '-'$" "$OUT"
check_match "value is trimmed on both sides" '^job\|pipes\|description\|spaces around are trimmed$' "$OUT"
check_match "last line without a newline is read, quotes kept" '^job\|last\|run\|echo "quoted \\"value\\""$' "$OUT"
check_no_match "no row carries a carriage return" $'\r' "$OUT"
check_no_match "comments produce no rows" 'comment line' "$OUT"
testing_check "row count" 7 "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c '|')"

su_run --config "$DEMO/stack.conf" --print-config
check_status "print-config of the demo" 0
check_match "demo check rows are printed, advisory or not" '^check\|greeting\|probe\|' "$OUT"
check_match "demo placeholders stay literal in rows" '^service\|hello-api\|env_file\|\$\{STACK_STATE\}/demo-settings.env$' "$OUT"
testing_check "print-config writes no state" no "$( [ -e "$XDG_STATE_HOME/stack-up/demo" ] && echo yes || echo no)"
su_run --config "$DEMO/stack.conf" --check
check_status "--check of the demo, whose greeting check is unmet" 1
testing_check "--check writes no state" no "$( [ -e "$XDG_STATE_HOME/stack-up/demo" ] && echo yes || echo no)"

su_run --config "$T/missing.conf" --print-config
check_status "a missing config file" 2
check_match "missing file is named" 'no config file at .*missing.conf' "$OUT"

su_run --print-schema
check_status "print-schema needs no config" 0
check_match "schema lists service.start as required" '^service\|start\|command\|required\|' "$OUT"
check_match "schema lists the shared entry keys" '^entry\|depends_on\|entry list\|' "$OUT"

testing_verdict
