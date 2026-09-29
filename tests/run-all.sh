#!/bin/bash
# run-all.sh - runs every test file with /bin/bash, one after another, and
# prints one line per file, the FAIL lines of any file that failed, and a
# closing RESULT line. It never stops at a failed file, so one run reports
# every failure. Exit status 0 only when every file passed.
#   /bin/bash tests/run-all.sh

set -u
# An exported CDPATH makes cd print the folder it found.
unset CDPATH
here=$(cd "$(dirname "$0")" && pwd -P) || exit 2
total=0
failed=0
started=$SECONDS

for test in "$here"/unit-manifest.sh "$here"/unit-*.sh "$here"/e2e-*.sh "$here"/docs-*.sh; do
  [ -f "$test" ] || continue
  name=${test##*/}
  case " ${seen:-} " in
    *" $name "*) continue ;;
  esac
  seen="${seen:-} $name"
  total=$((total + 1))
  file_started=$SECONDS
  output=$(/bin/bash "$test" </dev/null 2>&1)
  status=$?
  counts=$(printf '%s\n' "$output" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -n 1)
  last=$(printf '%s\n' "$output" | tail -n 1)
  if [ "$status" = 0 ] && [ "$last" = "RESULT: PASS" ]; then
    printf 'PASS  %-22s %s (%ss)\n' "$name" "$counts" "$((SECONDS - file_started))"
  else
    failed=$((failed + 1))
    printf 'FAIL  %-22s exit %s, %s (%ss)\n' "$name" "$status" "${counts:-no summary}" "$((SECONDS - file_started))"
    printf '%s\n' "$output" | grep -E '^FAIL|^DENY|^RESULT' | sed 's/^/        /'
  fi
done

printf '\n%s test files, %s failed, %ss\n' "$total" "$failed" "$((SECONDS - started))"
if [ "$total" -eq 0 ]; then
  printf 'no test files ran\nRESULT: FAIL 1\n'
  exit 1
fi
if [ "$failed" -eq 0 ]; then
  printf 'RESULT: PASS\n'
  exit 0
fi
printf 'RESULT: FAIL %s\n' "$failed"
exit 1
