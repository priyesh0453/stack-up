#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # the pinned sentences quote the docs' literal backticks, and the lib probes quote lib source
# docs-cli.sh - the documentation is tested against the real CLI:
#   * --help lists the flags; the README flag table lists exactly the same set,
#     each row with the same text, so a new flag needs su_flag_table,
#     su_parse_args and the README table, and nothing else;
#   * the --root pins: Uninstall step 1, uninstall.sh's hints, AGENTS, SKILL,
#     the Ctrl-C FAQ and the lost-launch-table limitation all ask for the same
#     --root, with the condition under which it matters; the older-lockf
#     limitation says what the lockf code does;
#   * README and docs/LIMITATIONS.md pins: no sudo, installs or system
#     settings, and no claim that it writes only to its own folders; what a
#     [compose] entry changes for a --stop on a stack that never ran; what
#     --stop verifies, and the processes it cannot see;
#   * every flag the parser accepts is documented, and every documented flag is
#     accepted (FLAG [VALUE] --help exits 0; an unknown flag exits 2);
#   * every --flag on a stack-up, install.sh or uninstall.sh line in the docs
#     exists in that command's --help;
#   * docs/CONFIG.md has one row per schema key with its type, default and
#     required or repeat mark, and no row the schema lacks;
#   * the documented exit statuses match --help, and --version matches VERSION;
#   * every ini example in README.md and docs/CONFIG.md is a valid config;
#   * the never-signals claims hold for the shared lib's keep-awake release,
#     pinned by its text and run against a reused PID, its own caffeinate child
#     and a caffeinate that is not its child.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

flags_in() {
  printf '%s\n' "$1" | LC_ALL=C grep -E '^  -' | LC_ALL=C grep -o -E -- '(^|[ ,])--?[a-z][a-z-]*' | LC_ALL=C sed 's/^[ ,]*//' | LC_ALL=C sort -u
}

help=$(/bin/bash "$STACK_UP" --help 2>&1)
testing_check "--help exits 0" 0 "$?"
real=$(flags_in "$help")
testing_check "--help lists flags" yes "$( [ -n "$real" ] && echo yes || echo no)"

table=$(awk '/^### Command-line flags/ { on = 1; next } on && /^#/ { on = 0 } on && /^\| `-/' "$REPO/README.md" |
  LC_ALL=C grep -o -E -- '`--?[a-z][a-z-]*' | LC_ALL=C tr -d '`' | LC_ALL=C sort -u)
testing_check "the README flag table lists exactly the --help flags" "$real" "$table"
help_rows=$(awk '/^su_flag_table\(\) \{/ { on = 1; next } on && /^EOF$/ { on = 0 } on && /^-/' "$STACK_UP" | LC_ALL=C sort)
readme_rows=$(awk '/^### Command-line flags/ { on = 1; next } on && /^#/ { on = 0 } on && /^\| `-/' "$REPO/README.md" |
  LC_ALL=C sed -e 's/`//g' -e 's/\\|/|/g' -e 's/^| //' -e 's/ |$//' -e 's/ | /|/' | LC_ALL=C sort)
testing_check "each README flag row says what its --help row says" "$help_rows" "$readme_rows"
check_match "README Uninstall step 1 asks for the same --root, with no condition on state_dir" 'if you started the stack with `--root`, add the same `--root` here and in step 2' "$(cat "$REPO/README.md")"
testing_check "no doc ties the same --root to a relative state_dir" "" "$(cd "$REPO" && LC_ALL=C grep -rl -E 'relative `?state_dir`?, (give|add)' README.md AGENTS.md docs skills uninstall.sh bin 2>&1)"
testing_check "both of uninstall.sh's closing hints name the --root" 2 "$(LC_ALL=C grep -c -F 'print-paths in the repository (with the --root the stack was started with, if any)' "$REPO/uninstall.sh")"
check_match "the older-lockf limitation says a refused start counts as having run here" 'A start refused this way, or a `--stop` on a stack with a `\[compose\]` entry, already counts as having run here' "$(cat "$REPO/docs/LIMITATIONS.md")"
check_no_match "and does not promise that --stop or --clean with nothing to act on still work" 'that has nothing to act on' "$(cat "$REPO/README.md" "$REPO/docs/LIMITATIONS.md")"
check_match "AGENTS tells an agent to pass the same --root" 'When the stack was started with `--root`, give `--stop`, `--clean` and `--print-paths` the same `--root`' "$(cat "$REPO/AGENTS.md")"
check_match "and says when it matters" 'Without it, a `state_dir`, `log_dir` or `compose_files` that is relative or built on `\$\{STACK_ROOT\}` resolves against another folder' "$(cat "$REPO/AGENTS.md")"
check_no_match "and never says every run without it reads another state folder" 'Without it they read another state folder' "$(cat "$REPO/AGENTS.md")"
check_match "SKILL forbids a --stop, --clean or --print-paths without the --config and --root" 'without the `--config` and `--root` it was started with' "$(cat "$REPO/skills/stack-up/SKILL.md")"
check_match "the Ctrl-C FAQ names the same --config and --root" 'with the same `--config`, plus the `--root` you gave, if any' "$(cat "$REPO/README.md")"
check_match "A lost launch table names a missing --root with its condition" 'without the `--root` the stack was started with, when its `state_dir` is relative or built on `\$\{STACK_ROOT\}`' "$(cat "$REPO/docs/LIMITATIONS.md")"
check_match "README: no sudo, no installs, no system settings" 'It never uses `sudo`, installs software or changes system settings, except what the commands in your config do\.' "$(cat "$REPO/README.md")"
check_no_match "and no claim that it writes only to its own folders, which an entry log can leave" 'writes outside its own state and log folders|only writes to its own state and log folders' "$(cat "$REPO/README.md")"
check_match "the never-ran --stop limitation says what a [compose] entry changes" 'With one, it creates the state folder and a run log, then, once `engine_check` answers, asks compose to stop the services its `\[compose\]` entries name\.' "$(cat "$REPO/docs/LIMITATIONS.md")"
check_match "README: --stop verifies only what it recorded or can see" 'verifies that no recorded group or held launch token is left' "$(cat "$REPO/README.md")"
check_match "docs/LIMITATIONS.md names the processes --stop cannot see" 'A process a job, build, provider, check or heal leaves running' "$(cat "$REPO/docs/LIMITATIONS.md")"
check_no_match "no doc says a value's type error stops validation, which the engine's own types do not" "a value's type stops validation" "$(cat "$REPO/README.md" "$REPO/docs/CONFIG.md" "$REPO/docs/LIMITATIONS.md")"
check_no_match "no doc gives a relative-name cure for a space inside a compose file's path" 'name such a file relative to the root' "$(cat "$REPO/README.md" "$REPO/docs/LIMITATIONS.md")"
check_no_match "no doc quotes the unqualified stop line" 'Everything is down' "$(cat "$REPO/README.md" "$REPO/docs/ARCHITECTURE.md" "$REPO/docs/LIMITATIONS.md" "$REPO/AGENTS.md" "$REPO/skills/stack-up/SKILL.md")"

for flag in $real; do
  case $flag in
    --config|--root|--select|--with|--without) /bin/bash "$STACK_UP" "$flag" value --help >/dev/null 2>&1 ;;
    *) /bin/bash "$STACK_UP" "$flag" --help >/dev/null 2>&1 ;;
  esac
  testing_check "the parser accepts documented flag $flag" 0 "$?"
done
/bin/bash "$STACK_UP" --no-such-flag --help >/dev/null 2>&1
testing_check "control: the parser refuses an undocumented flag" 2 "$?"
usage_out=$(PATH="$T/shims:/usr/bin:/bin" /bin/bash "$STACK_UP" --no-such-flag 2>&1)
check_line "a usage error names the command that reaches this script" "Run $(LC_ALL=C; printf '%q' "$STACK_UP") --help for the flags." "$usage_out"

# Parser cases in su_parse_args, read from the source, must all be documented.
parsed=$(awk '/^su_parse_args\(\) \{/ { on = 1 } on && /^}/ { on = 0 } on' "$STACK_UP" |
  LC_ALL=C grep -E '^ +(-|--)[a-z|-]+\)' | LC_ALL=C sed 's/).*//' | LC_ALL=C tr '|' '\n' | LC_ALL=C grep -o -E -- '--?[a-z][a-z-]*' | LC_ALL=C sort -u)
testing_check "every flag the parser handles is in --help" "$parsed" "$real"

install_flags=$( { /bin/bash "$REPO/install.sh" --help; /bin/bash "$REPO/uninstall.sh" --help; } 2>&1 | LC_ALL=C grep -E '^  -' | LC_ALL=C grep -o -E -- '--?[a-z][a-z-]*' | LC_ALL=C sort -u)
# Word splitting is wanted: the lists hold one flag per line.
# shellcheck disable=SC2086
real_words=$(printf '%s ' $real)
# shellcheck disable=SC2086
install_words=$(printf '%s ' $install_flags)

# scan_docs FILE...: prints FILE:LINE:--flag for every unknown flag on a
# stack-up or install line.
scan_docs() {
  local doc lines line known token bad=""
  for doc in "$@"; do
    lines=$(LC_ALL=C grep -n -E '(^|[ `(])(bin/)?stack-up( |$)|install\.sh|uninstall\.sh' "$doc")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case $line in
        *install.sh*) known="$real_words $install_words" ;;
        *) known=$real_words ;;
      esac
      # --filter is the container engine's own flag in the printed cleanup command.
      for token in $(printf '%s\n' "$line" | LC_ALL=C grep -o -E -- '(^|[^[:alnum:]-])--[a-z][a-z-]*' | LC_ALL=C sed 's/^[^-]*//'); do
        case " $known --filter " in
          *" $token "*) ;;
          *) bad="$bad ${doc#"$REPO"/}:${line%%:*}:$token" ;;
        esac
      done
    done <<LINES
$lines
LINES
  done
  printf '%s' "$bad"
}

docs=$(find "$REPO" -name '*.md' ! -path '*/.git/*' | LC_ALL=C sort)
# shellcheck disable=SC2086
bad=$(scan_docs $docs)
testing_baseline "every --flag on a stack-up or install line in the docs exists" "$( [ -z "$bad" ] && echo 0 || echo 1)" "$bad"
[ -z "$bad" ] || printf 'unknown flags in docs:%s\n' "$bad"
printf 'Run bin/stack-up --config x --destroy to wipe it.\n' >| "$T/probe-doc.md"
testing_expect_fail "a doc that names a flag the CLI lacks" "$(scan_docs "$T/probe-doc.md")" 'probe-doc\.md:1:--destroy'

for flag in --prefix --copy --dry-run; do
  check_match "README documents install.sh $flag" "install\\.sh.*$flag" "$(cat "$REPO/README.md")"
done

schema=$(/bin/bash "$STACK_UP" --print-schema 2>&1)
missing=""
while IFS='|' read -r kind key shown flags default _; do
  [ -n "$kind" ] || continue
  [ "$flags" != - ] || flags=""
  row=$(awk -v kind="$kind" '/^<!-- schema:/ { on = ($0 == "<!-- schema:" kind " -->"); next } /^#/ { on = 0 } on' "$REPO/docs/CONFIG.md" | LC_ALL=C grep -F "| \`$key\` |")
  if [ -z "$row" ]; then
    missing="$missing $kind.$key(no row)"
    continue
  fi
  case $row in
    *"| $shown | $default | $flags |"*) ;;
    *) missing="$missing $kind.$key(type, default or required or repeat differs)" ;;
  esac
done <<EOF2
$schema
EOF2
testing_check "docs/CONFIG.md has a matching row for every schema key" "" "$missing"
documented=$(awk '/^<!-- schema:/ { kind = $0; sub(/^<!-- schema:/, "", kind); sub(/ -->$/, "", kind); on = 1; next } /^#/ { on = 0 } on && /^\| `/ { split($0, cell, "`"); print kind "|" cell[2] }' "$REPO/docs/CONFIG.md" | LC_ALL=C sort)
expected=$(printf '%s\n' "$schema" | awk -F'|' '{ print $1 "|" $2 }' | LC_ALL=C sort)
testing_check "docs/CONFIG.md documents no key the schema lacks" "$expected" "$documented"

for status in 0 1 2 3 4; do
  check_match "--help states exit status $status" "(^|[ ,:])$status [a-z]" "$(printf '%s\n' "$help" | LC_ALL=C sed -n '/^Exit status/,$p')"
  check_match "docs/CONFIG.md documents exit status $status" "^\\| $status \\| " "$(cat "$REPO/docs/CONFIG.md")"
done

testing_check "--version matches VERSION" "stack-up $(cat "$REPO/VERSION")" "$(/bin/bash "$STACK_UP" --version)"
testing_check "--version from the repository folder with CDPATH exported" "stack-up $(cat "$REPO/VERSION")" "$(cd "$REPO" && CDPATH=".:$T" /bin/bash bin/stack-up --version 2>&1)"
testing_check "--version with POSIXLY_CORRECT exported" "stack-up $(cat "$REPO/VERSION")" "$(POSIXLY_CORRECT=1 /bin/bash "$STACK_UP" --version 2>&1)"
# /bin/sh is bash on a stock Mac, but a system may point it at another shell.
if [ -n "$(/bin/sh -c 'printf "%s" "${BASH_VERSION:-}"' 2>/dev/null)" ]; then
  testing_check "--version when started with sh" "stack-up $(cat "$REPO/VERSION")" "$(/bin/sh "$STACK_UP" --version 2>&1)"
else
  printf 'SKIP  --version when started with sh: /bin/sh is not bash here\n'
fi
# A clone whose path has a space: the quickstart's --plan line, and a test
# file that resolves its folders through the shared harness.
spaced="$T/a folder with spaces/stack-up"
mkdir -p "${spaced%/*}" && cp -R "$REPO" "$spaced"
spaced_out=$(cd "$spaced" && /bin/bash bin/stack-up --config examples/demo/stack.conf --plan 2>&1)
testing_check "the quickstart --plan line from a clone path with a space (exit status)" 0 "$?"
check_match "its plan names the demo" 'hello-api' "$spaced_out"
spaced_out=$(/bin/bash "$spaced/tests/unit-manifest.sh" 2>&1)
testing_check "unit-manifest.sh from a clone path with a space (exit status)" 0 "$?"
check_match "and it reports its own result" '^RESULT: PASS' "$spaced_out"
# A shell that exports a proxy or a curl config (common on work networks):
# the harness must clear them, or the quickstart curl lines ask the proxy.
proxy_env=(http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 CURL_HOME="$T" XDG_CONFIG_HOME="$T")
proxy_names() {
  printf '%s\n' "$1" | LC_ALL=C grep -E -o '^(http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|ALL_PROXY|all_proxy|NO_PROXY|no_proxy|CURL_HOME|XDG_CONFIG_HOME)=' | LC_ALL=C tr -d '=' | LC_ALL=C sort | LC_ALL=C tr '\n' ' '
}
mkdir -p "$T/harness-env"
child_env=$(env "${proxy_env[@]}" TESTING_TMPDIR="$T/harness-env" /bin/bash -c '. "$1" && env' _ "$TESTS_DIR/lib/harness.sh" 2>&1)
testing_check "a shell that sources the harness gets the test HOME" 1 "$(printf '%s\n' "$child_env" | LC_ALL=C grep -c -F -x "HOME=$T/harness-env/home")"
testing_check "the harness clears every exported proxy and curl-config variable" "" "$(proxy_names "$child_env")"
testing_check "control: without the harness all ten are exported" "ALL_PROXY CURL_HOME HTTPS_PROXY HTTP_PROXY NO_PROXY XDG_CONFIG_HOME all_proxy http_proxy https_proxy no_proxy " "$(proxy_names "$(env "${proxy_env[@]}" /bin/bash -c env)")"
check_match "CHANGELOG has an entry for VERSION" "^## \\[$(cat "$REPO/VERSION" | sed 's/\./\\./g')\\]" "$(cat "$REPO/CHANGELOG.md")"
check_match "SKILL.md version matches VERSION" "^  version: $(cat "$REPO/VERSION" | sed 's/\./\\./g')$" "$(cat "$REPO/skills/stack-up/SKILL.md")"

order=""
for heading in "The 30-second pitch" "A reference design, not a product" "Who this is for" "What it never does" "Quickstart" "How it works" "Config reference" "Cross-platform notes" "Extend this" "FAQ" "Uninstall"; do
  order="$order$(LC_ALL=C grep -n -x "## $heading" "$REPO/README.md" | cut -d: -f1) "
done
# shellcheck disable=SC2086
sorted=$(printf '%s\n' $order | LC_ALL=C sort -n | tr '\n' ' ')
testing_check "README sections are all present, in the agreed order" "$order" "$sorted"
# shellcheck disable=SC2086
testing_check "README section count" 11 "$(printf '%s\n' $order | LC_ALL=C grep -c .)"
testing_check "no doc says it stops only what it started" "" "$(cd "$REPO" && LC_ALL=C grep -rl -i -E 'only ever touch|exactly what it started|stops? what (it|this stack) started' README.md AGENTS.md CHANGELOG.md docs skills 2>&1)"

# The shared lib sends TERM to its saved keep-awake PID at exit. The plain
# never-signals claims hold only while it first checks that the PID is still a
# child of the engine's shell named caffeinate; a lib without that check would
# make them false, so the check is pinned here and the old limitation and its
# pointers must stay gone.
release=$(awk '/^lifecycle_release_awake\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO/lib/lifecycle.sh")
case $release in *kill*) awake_kill=yes ;; *) awake_kill=no ;; esac
testing_check "lib/lifecycle.sh: lifecycle_release_awake signals the saved PID" yes "$awake_kill"
case $release in *'pgrep -P "$$" -x caffeinate'*'grep -x -e "$pid" >/dev/null || return 0'*'kill "$pid"'*) awake_checked=yes ;; *) awake_checked=no ;; esac
testing_check "lib/lifecycle.sh: the release signals only a caffeinate child of this shell" yes "$awake_checked"
# The same check, run: the release is handed a PID now held by another child
# of the shell (a reused PID), its own live caffeinate child, and a caffeinate
# that is not its child. A text pin alone passes a check that no longer returns.
cat >> "$T/awake-probe.sh" <<'PROBE'
. "$1" || exit 1
named() {
  local tries=0
  until pgrep -x caffeinate 2>/dev/null | LC_ALL=C grep -x -e "$1" >/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
}
state() { if kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi; }
sleep 30 &
other=$!
LIFECYCLE_AWAKE_PID=$other
lifecycle_release_awake
printf 'reused=%s\n' "$(state "$other")"
kill "$other" 2>/dev/null
wait "$other" 2>/dev/null
lifecycle_keep_awake || printf 'own=not started\n'
own=$LIFECYCLE_AWAKE_PID
named "$own" || printf 'own=never named caffeinate\n'
lifecycle_release_awake
printf 'own=%s\n' "$(state "$own")"
foreign=$( (caffeinate -i -w "$$" </dev/null >/dev/null 2>&1 & printf '%s\n' "$!") )
named "$foreign" || printf 'foreign=never named caffeinate\n'
LIFECYCLE_AWAKE_PID=$foreign
lifecycle_release_awake
printf 'foreign=%s\n' "$(state "$foreign")"
PROBE
awake_probe=$(/bin/bash "$T/awake-probe.sh" "$REPO/lib/lifecycle.sh" 2>/dev/null)
testing_check "keep-awake release: a reused PID held by another child, its own caffeinate child, a caffeinate that is not its child" "reused=alive own=gone foreign=alive" "$(printf '%s\n' "$awake_probe" | LC_ALL=C tr '\n' ' ' | LC_ALL=C sed 's/ $//')"
testing_check "no doc lists keep-awake PID reuse" 0 "$(cat "$REPO/README.md" "$REPO/docs/LIMITATIONS.md" | LC_ALL=C grep -c -i 'keep-awake PID reuse')"
never_signals=$(LC_ALL=C grep -E 'never signals a (program|process) it did not' "$REPO/README.md")
testing_check "README has two never-signals claims" 2 "$(printf '%s\n' "$never_signals" | LC_ALL=C grep -c .)"
testing_check "README never-signals claims carry no keep-awake exception" 0 "$(printf '%s\n' "$never_signals" | LC_ALL=C grep -c -i 'keep-awake')"
invariant_one=$(LC_ALL=C grep -E '^1\. \*\*Only signal what you started\.\*\*' "$REPO/docs/ARCHITECTURE.md")
testing_check "ARCHITECTURE has exactly one invariant 1 line" 1 "$(printf '%s' "$invariant_one" | LC_ALL=C grep -c .)"
testing_check "ARCHITECTURE invariant 1 carries no exception" 0 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -i 'exception')"
testing_check "ARCHITECTURE invariant 1 says how the keep-awake signal is proven" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'pgrep -P "$$" -x caffeinate')"
testing_check "ARCHITECTURE invariant 1 names the keep-awake test" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'docs-cli.sh keep-awake release')"
testing_check "ARCHITECTURE invariant 1 scopes the token rule to launched groups" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'A launched group is signalled only while')"
testing_check "ARCHITECTURE invariant 1 says KILL follows only a group that still exists" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'sends KILL only if the group still exists')"
testing_check "ARCHITECTURE invariant 1 names the launch-moment cases" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'two cases at the moment of launch')"
testing_check "ARCHITECTURE invariant 1 makes no exclusive lookup claim" 0 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'only other process lookup')"
testing_check "README install table: --copy still makes the link" 0 "$(LC_ALL=C grep -c -F 'instead of a link' "$REPO/README.md")"
windows=$(LC_ALL=C grep -E '^- \*\*Check-then-signal windows\.\*\*' "$REPO/docs/LIMITATIONS.md")
testing_check "docs/LIMITATIONS.md has exactly one check-then-signal windows bullet" 1 "$(printf '%s' "$windows" | LC_ALL=C grep -c .)"
testing_check "LIMITATIONS windows bullet: KILL only while the group still exists" 1 "$(printf '%s\n' "$windows" | LC_ALL=C grep -c -F 'the group still existing before KILL')"
testing_check "LIMITATIONS windows bullet: the launch-moment checks" 1 "$(printf '%s\n' "$windows" | LC_ALL=C grep -c -F 'at the moment of launch')"
testing_check "LIMITATIONS windows bullet: no leader-only KILL claim" 0 "$(printf '%s\n' "$windows" | LC_ALL=C grep -c -F 'the leader answering `kill -0` for a group run under the library')"
testing_check "ARCHITECTURE invariant 1: a launch that already ended is not signalled" 1 "$(printf '%s\n' "$invariant_one" | LC_ALL=C grep -c -F 'a launch that already ended is not signalled')"

# A comment at the end of a pasted line reaches the script as an argument in
# zsh, the default Mac shell, because zsh leaves interactive comments off.
for doc in "$REPO/README.md" "$REPO"/docs/*.md "$REPO/AGENTS.md" "$REPO"/skills/*/SKILL.md; do
  commented=$(LC_ALL=C awk '/^[[:space:]]*```(sh|bash|zsh|shell|console)[[:space:]]*$/ { inside = 1; next } /^[[:space:]]*```/ { inside = 0; next } inside && (/ #/ || /^[[:space:]]*#/) { n++ } END { print n + 0 }' "$doc")
  testing_check "no shell block line in ${doc##*/} ends with a comment" 0 "$commented"
done

# Every ini example in the docs must be a config the validator accepts.
for doc in "$REPO/README.md" "$REPO/docs/CONFIG.md"; do
  out_dir=$T/examples-$(basename "$doc" .md)
  mkdir -p "$out_dir"
  awk -v dir="$out_dir" '/^```ini$/ { on = 1; n++; next } /^```$/ { on = 0 } on { print >> (dir "/example-" n ".conf") }' "$doc"
  count=0
  for example in "$out_dir"/example-*.conf; do
    [ -f "$example" ] || continue
    count=$((count + 1))
    errors=$(/bin/bash "$STACK_UP" --config "$example" --print-config 2>&1 >/dev/null)
    testing_check "ini example $count in $(basename "$doc") is a valid config" "0 []" "$? [$errors]"
  done
  testing_check "$(basename "$doc") has an ini example" yes "$( [ "$count" -gt 0 ] && echo yes || echo no)"
done

testing_verdict
