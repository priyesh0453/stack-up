#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-manifest.sh - lib/ is vendored byte for byte from the shared library:
# every file must match lib/MANIFEST.sha256, and no file may be added beside
# them. Two probes on a copy prove the check catches an edit and an extra file.
# The manifest itself is pinned by its own checksum, so an edit to lib/ cannot
# pass by regenerating the manifest with it; that value changes only when lib/
# is vendored again. The probes edit copies under the test folder; lib/ itself
# is only read.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

verify_lib() {
  local dir=$1 listed actual extra
  if ! (cd "$dir" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1); then
    printf 'checksum mismatch:\n'
    (cd "$dir" && shasum -a 256 -c MANIFEST.sha256 2>&1 | LC_ALL=C grep -v ': OK$')
    return 1
  fi
  listed=$(awk '{ print $2 }' "$dir/MANIFEST.sha256" | LC_ALL=C sort)
  actual=$(cd "$dir" && LC_ALL=C find . -type f ! -name MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort)
  extra=$(printf '%s\n' "$actual" | LC_ALL=C grep -v -x -F -f <(printf '%s\n' "$listed"))
  if [ -n "$extra" ]; then
    printf 'not in the manifest: %s\n' "$extra"
    return 1
  fi
  return 0
}

out=$(verify_lib "$REPO/lib")
testing_baseline "lib/ matches lib/MANIFEST.sha256" "$?" "$out"
testing_check "the manifest lists 9 files" 9 "$(LC_ALL=C grep -c . "$REPO/lib/MANIFEST.sha256")"
testing_check "the manifest itself is the vendored one" bb216e81209567ac8347605bc54a9d2a6fe309d22a8f73cd0766a2a5064a8b38 "$(shasum -a 256 < "$REPO/lib/MANIFEST.sha256" | awk '{ print $1 }')"

cp -R "$REPO/lib" "$T/lib-edited"
printf '# local edit\n' >> "$T/lib-edited/util.sh"
out=$(verify_lib "$T/lib-edited")
testing_expect_fail "an edited lib file is caught" "$out" 'util\.sh: FAILED'

cp -R "$REPO/lib" "$T/lib-extra"
printf 'helper() { :; }\n' >> "$T/lib-extra/proc.sh"
out=$(verify_lib "$T/lib-extra")
testing_expect_fail "an extra lib file is caught" "$out" 'not in the manifest: proc\.sh'

testing_verdict
