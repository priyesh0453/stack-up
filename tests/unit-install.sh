#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# unit-install.sh - install.sh and uninstall.sh against temporary prefixes:
# link and copy installs, idempotence (only when the installed tool answers
# with this version), --version through the installed name, refusal to
# overwrite or remove what they did not create (a foreign link, absolute or
# relative, and a file added beside a copy), --dry-run, a prefix that is not
# writable or ends in a slash, hints that stay ASCII from a non-ASCII clone,
# a PATH hint that is never a broken paste, and no HOME or a relative one.
# Nothing outside the test folder is touched.

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

version=$(cat "$REPO/VERSION")
inst() { OUT=$(/bin/bash "$REPO/install.sh" "$@" </dev/null 2>&1); STATUS=$?; }
uninst() { OUT=$(/bin/bash "$REPO/uninstall.sh" "$@" </dev/null 2>&1); STATUS=$?; }

P=$T/prefix-link
inst --prefix "$P" --dry-run
check_status "link install, dry run" 0
check_match "dry run says what it would do" 'would run: ln -s' "$OUT"
testing_check "dry run changed nothing" no "$( [ -e "$P" ] && echo yes || echo no)"
inst --prefix "$T/prefix-copy-dry" --copy --dry-run
check_status "copy install, dry run" 0
check_match "the copy dry run says what it would copy" 'would run: cp -p ' "$OUT"
testing_check "the copy dry run changed nothing" no "$( [ -e "$T/prefix-copy-dry" ] && echo yes || echo no)"

inst --prefix "$P"
check_status "link install" 0
testing_check "the link points at this checkout" "$REPO/bin/stack-up" "$(readlink "$P/bin/stack-up")"
testing_check "--version through the installed name" "stack-up $version" "$("$P/bin/stack-up" --version)"
check_match "PATH hint when the bin folder is not on PATH" 'is not on PATH' "$OUT"
uninst --prefix "$P"
OUT=$(SHELL=/bin/zsh /bin/bash "$REPO/install.sh" --prefix "$P" </dev/null 2>&1)
check_match "the PATH hint for a zsh login shell names ~/.zprofile" ">> ~/\\.zprofile\$" "$OUT"
uninst --prefix "$P"
OUT=$(SHELL=/bin/bash /bin/bash "$REPO/install.sh" --prefix "$P" </dev/null 2>&1)
check_match "the PATH hint for a bash login shell names ~/.bash_profile" ">> ~/\\.bash_profile\$" "$OUT"
check_no_match "and not ~/.zprofile" 'zprofile' "$OUT"
OUT=$(cd "$REPO/.." && CDPATH=".:$T" /bin/bash "${REPO##*/}/install.sh" --prefix "$T/prefix-cdpath" --dry-run </dev/null 2>&1)
testing_check "install.sh by a relative path with CDPATH exported (exit status)" 0 "$?"
testing_check "it names this checkout, quoted as install prints it" yes "$(printf '%s\n' "$OUT" | LC_ALL=C grep -F -q -- "would run: ln -s $(LC_ALL=C; printf '%q' "$REPO/bin/stack-up") " && echo yes || echo no)"
inst --prefix "$P"
check_status "installing twice" 0
check_match "second install is a no-op" 'already installed' "$OUT"

uninst --prefix "$P" --dry-run
check_status "uninstall, dry run" 0
testing_check "dry run kept the link" yes "$( [ -L "$P/bin/stack-up" ] && echo yes || echo no)"
uninst --prefix "$P"
check_status "uninstall of a link install" 0
testing_check "the link is gone" no "$( [ -L "$P/bin/stack-up" ] && echo yes || echo no)"
testing_check "the checkout is untouched" yes "$( [ -x "$REPO/bin/stack-up" ] && echo yes || echo no)"
check_match "uninstall says state is kept" 'state and logs were kept' "$OUT"
uninst --prefix "$P"
check_status "uninstall with nothing installed" 0

C=$T/prefix-copy
inst --prefix "$C" --copy
check_status "copy install" 0
testing_check "the copy has the lib" yes "$( [ -f "$C/share/stack-up/lib/conf.sh" ] && echo yes || echo no)"
testing_check "the copy has the marker" yes "$( [ -f "$C/share/stack-up/INSTALLED" ] && echo yes || echo no)"
testing_check "--version through the copied tool" "stack-up $version" "$("$C/bin/stack-up" --version)"
OUT=$("$C/bin/stack-up" --config "$DEMO/stack.conf" --print-config 2>&1)
check_match "the copied tool reads a config" '^stack\|\|name\|demo$' "$OUT"
uninst --prefix "$C" --dry-run
check_status "uninstall of a copy, dry run" 0
check_match "it says it would remove the copy" 'would remove the copy' "$OUT"
testing_check "the dry run kept the copy and its marker" yes "$( [ -f "$C/share/stack-up/INSTALLED" ] && [ -f "$C/share/stack-up/lib/conf.sh" ] && echo yes || echo no)"
uninst --prefix "$C"
check_status "uninstall of a copy install" 0
testing_check "the copy is gone" no "$( [ -e "$C/share/stack-up" ] && echo yes || echo no)"
testing_check "the link is gone" no "$( [ -L "$C/bin/stack-up" ] && echo yes || echo no)"
testing_check "the prefix bin folder itself is kept" yes "$( [ -d "$C/bin" ] && echo yes || echo no)"

M="$T/sp ace clone"
cp -Rp "$REPO" "$M"
W="$T/prefix-with-foreign-file"
mkdir -p "$W/bin"
printf '#!/bin/bash\necho someone else\n' >> "$W/bin/stack-up"
OUT=$(/bin/bash "$M/install.sh" --prefix "$W" </dev/null 2>&1)
expected="run $(LC_ALL=C; printf '%q' "$M/uninstall.sh") --prefix "
testing_check "the refusal names the uninstall.sh beside this install.sh, quoted" yes "$(printf '%s\n' "$OUT" | LC_ALL=C grep -F -q -- "$expected" && echo yes || echo no)"
mkdir -p "$W-copy/share/stack-up"
: > "$W-copy/share/stack-up/INSTALLED"
OUT=$(/bin/bash "$M/install.sh" --prefix "$W-copy" --copy </dev/null 2>&1)
testing_check "the share-folder refusal names the same quoted path" yes "$(printf '%s\n' "$OUT" | LC_ALL=C grep -F -q -- "$expected" && echo yes || echo no)"
OUT=$(/bin/bash "$M/install.sh" --prefix "$T/prefix-moved" --dry-run </dev/null 2>&1)
STATUS=$?
check_status "dry run from a clone path with a space" 0
check_match "the printed command quotes the path so it can be pasted" 'would run: ln -s .*/sp\\ ace\\ clone/bin/stack-up ' "$OUT"
OUT=$(/bin/bash "$M/install.sh" --prefix "$T/prefix-moved" --copy </dev/null 2>&1)
STATUS=$?
check_status "copy install from a clone that moves later" 0
mv "$M" "$M moved"
testing_check "--version through the copy after the clone moved" "stack-up $version" "$("$T/prefix-moved/bin/stack-up" --version 2>&1)"
OUT=$("$T/prefix-moved/bin/stack-up" --config "$M moved/examples/demo/stack.conf" --plan </dev/null 2>&1)
STATUS=$?
check_status "--plan through the copy after the clone moved" 0

F=$T/prefix-foreign
mkdir -p "$F/bin"
printf '#!/bin/bash\necho someone else\n' >> "$F/bin/stack-up"
inst --prefix "$F"
check_status "install over a file it did not create" 1
check_match "install says why" 'already exists and is not this install' "$OUT"
G="$T/prefix foreign"
mkdir -p "$G/bin"
printf '#!/bin/bash\necho someone else\n' >> "$G/bin/stack-up"
inst --prefix "$G"
check_status "install over a file it did not create, prefix with a space" 1
check_match "the printed uninstall command names this clone's script and quotes the prefix" "run .*/uninstall\\.sh'? --prefix .*/prefix\\\\ foreign if it came from here" "$OUT"
G2="$T/prefix share"
mkdir -p "$G2/share/stack-up"
: > "$G2/share/stack-up/INSTALLED"
inst --prefix "$G2" --copy
check_status "copy install over an earlier copy's share folder, prefix with a space" 1
check_match "that refusal quotes the prefix too" "already exists; run .*/uninstall\\.sh'? --prefix .*/prefix\\\\ share first" "$OUT"
# uninstall.sh leaves a share folder without the marker alone, so the refusal
# does not send the person there.
mkdir -p "$T/prefix-unmarked/share/stack-up"
inst --prefix "$T/prefix-unmarked" --copy
check_status "copy install over an unmarked share folder" 1
check_match "it says install.sh did not make that folder" 'was not made by install.sh --copy' "$OUT"
check_no_match "it does not send the person to uninstall.sh" 'uninstall\.sh --prefix' "$OUT"
if [ "$(LC_ALL=en_US.UTF-8 /bin/bash -c 'printf "%s" "${#1}"' _ "$(printf '\303\251')")" = 1 ]; then
  G3=$T/$(printf 'pr\303\244fix foreign')
  mkdir -p "$G3/bin"
  printf '#!/bin/bash\necho someone else\n' >> "$G3/bin/stack-up"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 inst --prefix "$G3"
  check_status "install over a file it did not create, non-ASCII prefix, UTF-8 locale" 1
  testing_check "its printed uninstall command is ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep 'uninstall\.sh' | LC_ALL=C grep '[^ -~]')"
  check_match "and names the prefix in escapes" "--prefix .*pr\\\\303\\\\244fix" "$OUT"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 inst --prefix "$T/$(printf 'dr\303\244y')" --dry-run
  check_status "a dry run with a non-ASCII prefix, UTF-8 locale" 0
  testing_check "its would-run lines are ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep 'would run:' | LC_ALL=C grep '[^ -~]')"
  check_match "and name the prefix in escapes" "would run: .*dr\\\\303\\\\244y" "$OUT"
  testing_check "that dry run created nothing" no "$( [ -e "$T/$(printf 'dr\303\244y')" ] && echo yes || echo no)"
  # A clone in a folder with a non-ASCII letter: each uninstall hint names its
  # uninstall.sh in escapes, whatever the caller's locale.
  U=$T/$(printf 'Code \303\204rger')/clone
  U2=${U%/*}/clone-nolib
  mkdir -p "$U/bin" "$U2/bin"
  cp "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/VERSION" "$REPO/LICENSE" "$U/"
  cp "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/VERSION" "$REPO/LICENSE" "$U2/"
  cp "$REPO/bin/stack-up" "$U/bin/"
  cp "$REPO/bin/stack-up" "$U2/bin/"
  cp -R "$REPO/lib" "$U/lib"
  mkdir -p "$T/prefix-u81/bin"
  printf '#!/bin/bash\necho someone else\n' >> "$T/prefix-u81/bin/stack-up"
  OUT=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /bin/bash "$U/install.sh" --prefix "$T/prefix-u81" </dev/null 2>&1)
  STATUS=$?
  check_status "a link refusal from a non-ASCII clone, UTF-8 locale" 1
  testing_check "its uninstall hint is ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep 'uninstall\.sh' | LC_ALL=C grep '[^ -~]')"
  check_match "and names the clone's uninstall.sh in escapes" "\\$'.*/clone/uninstall\\.sh' --prefix " "$OUT"
  mkdir -p "$T/prefix-u89/share/stack-up"
  : > "$T/prefix-u89/share/stack-up/INSTALLED"
  OUT=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /bin/bash "$U/install.sh" --prefix "$T/prefix-u89" --copy </dev/null 2>&1)
  STATUS=$?
  check_status "a share-folder refusal from a non-ASCII clone, UTF-8 locale" 1
  testing_check "its uninstall hint is ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep 'uninstall\.sh' | LC_ALL=C grep '[^ -~]')"
  check_match "and names the clone's uninstall.sh in escapes" "\\$'.*/clone/uninstall\\.sh' --prefix " "$OUT"
  OUT=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /bin/bash "$U2/install.sh" --prefix "$T/prefix-u100" --copy </dev/null 2>&1)
  STATUS=$?
  check_status "a copy that fails from a non-ASCII clone, UTF-8 locale" 1
  testing_check "its partial-copy hint is ASCII" "" "$(printf '%s\n' "$OUT" | LC_ALL=C grep 'to remove the partial copy' | LC_ALL=C grep '[^ -~]')"
  check_match "and names that clone's uninstall.sh in escapes" "\\$'.*/clone-nolib/uninstall\\.sh' --prefix .* to remove the partial copy" "$OUT"
  for prefix in prefix-u81 prefix-u89 prefix-u100; do
    uninst --prefix "$T/$prefix"
  done
else
  printf 'SKIP  non-ASCII prefix: the en_US.UTF-8 locale is not available here\n'
fi
testing_check "the foreign file is intact" "echo someone else" "$(sed -n 2p "$F/bin/stack-up")"
uninst --prefix "$F" --dry-run
check_status "the uninstall dry run over a file it did not create exits 1 as well" 1
uninst --prefix "$F"
check_status "uninstall of a file it did not create" 1
testing_check "the foreign file is still there" yes "$( [ -f "$F/bin/stack-up" ] && echo yes || echo no)"
mkdir -p "$F/share/stack-up"
uninst --prefix "$F"
check_status "uninstall of a share folder without the marker" 1
testing_check "the unmarked folder is kept" yes "$( [ -d "$F/share/stack-up" ] && echo yes || echo no)"

# A copy that fails half way leaves its marker, so uninstall can remove it.
H="$T/prefix half"
mkdir -p "$T/no-lib/bin"
cp "$REPO/install.sh" "$REPO/VERSION" "$REPO/LICENSE" "$T/no-lib/"
cp "$REPO/bin/stack-up" "$T/no-lib/bin/"
OUT=$(/bin/bash "$T/no-lib/install.sh" --prefix "$H" --copy </dev/null 2>&1)
STATUS=$?
check_status "a copy install that fails half way" 1
check_match "it says how to remove the partial copy, with the prefix quoted" 'the copy into .* failed; run .*/uninstall\.sh --prefix .*/prefix\\ half to remove the partial copy' "$OUT"
testing_check "the partial copy carries the marker" yes "$( [ -f "$H/share/stack-up/INSTALLED" ] && echo yes || echo no)"
testing_check "no link was made to the partial copy" no "$( [ -L "$H/bin/stack-up" ] && echo yes || echo no)"
uninst --prefix "$H"
check_status "uninstall of a half-done copy" 0
testing_check "the partial copy is gone" no "$( [ -e "$H/share/stack-up" ] && echo yes || echo no)"
inst --prefix "$H" --copy
check_status "a copy install after that" 0
uninst --prefix "$H"

# A copy whose removal fails part way keeps its marker and is listed.
if [ "$(id -u)" != 0 ]; then
  R=$T/prefix-stuck
  inst --prefix "$R" --copy
  check_status "copy install to remove part way" 0
  chmod 555 "$R/share/stack-up/lib"
  uninst --prefix "$R"
  chmod 755 "$R/share/stack-up/lib"
  check_status "an uninstall that cannot remove all of the copy" 1
  check_match "it lists the copy as still present" 'still present: .*/prefix-stuck/share/stack-up' "$OUT"
  testing_check "the copy keeps its INSTALLED marker" yes "$( [ -f "$R/share/stack-up/INSTALLED" ] && echo yes || echo no)"
  uninst --prefix "$R"
  check_status "a rerun finishes the removal" 0
  testing_check "the copy is gone after the rerun" no "$( [ -e "$R/share/stack-up" ] && echo yes || echo no)"

  # The same holds when only the folder itself cannot be removed.
  R2=$T/prefix-stuck-folder
  inst --prefix "$R2" --copy
  check_status "copy install whose folder cannot be removed" 0
  chmod 555 "$R2/share"
  uninst --prefix "$R2"
  chmod 755 "$R2/share"
  check_status "an uninstall that cannot remove the copy's folder" 1
  check_match "it lists that folder as still present" 'still present: .*/prefix-stuck-folder/share/stack-up' "$OUT"
  testing_check "the folder keeps an INSTALLED marker" yes "$( [ -f "$R2/share/stack-up/INSTALLED" ] && echo yes || echo no)"
  uninst --prefix "$R2"
  check_status "a rerun removes the folder" 0
  testing_check "the folder is gone after the rerun" no "$( [ -e "$R2/share/stack-up" ] && echo yes || echo no)"
else
  printf 'SKIP  partial copy removals: running as root, where nothing is read-only\n'
fi

# A share folder that is a link is never walked into.
LA=$T/prefix-link-target
LB=$T/prefix-link-source
inst --prefix "$LA" --copy
check_status "copy install that another prefix links to" 0
mkdir -p "$LB/share"
ln -s "$LA/share/stack-up" "$LB/share/stack-up"
uninst --prefix "$LB" --dry-run
check_status "the dry run over a linked share folder exits 1" 1
uninst --prefix "$LB"
check_status "uninstall over a linked share folder exits 1" 1
check_match "it says the share folder is a link and leaves it" 'left alone: .*/prefix-link-source/share/stack-up is a link' "$OUT"
inst --prefix "$LB" --copy
check_status "a copy install over a linked share folder is refused" 1
check_match "the refusal says it is a link and does not send the person to uninstall.sh" 'refusing: .*/prefix-link-source/share/stack-up is a link, not a copy this install made' "$OUT"
check_no_match "the refusal does not loop through uninstall.sh" 'uninstall\.sh --prefix' "$OUT"
testing_check "the linked copy is intact" yes "$( [ -f "$LA/share/stack-up/INSTALLED" ] && [ -f "$LA/share/stack-up/lib/conf.sh" ] && echo yes || echo no)"
testing_check "the link is still there" yes "$( [ -L "$LB/share/stack-up" ] && echo yes || echo no)"

D=$T/prefix-dangling
mkdir -p "$D/bin"
ln -s "$T/moved-away/bin/stack-up" "$D/bin/stack-up"
uninst --prefix "$D"
check_status "uninstall of a dangling link from a moved checkout" 0
testing_check "the dangling link is gone" no "$( [ -L "$D/bin/stack-up" ] && echo yes || echo no)"

R=$T/read-only
mkdir -p "$R"
chmod 555 "$R"
inst --prefix "$R/inner"
check_status "install into a folder that is not writable" 1
check_match "no sudo, a hint instead" 'not writable by you; pick --prefix under your home folder \(no sudo\)' "$OUT"
chmod 755 "$R"

for script in install.sh uninstall.sh; do
  OUT=$(/bin/bash "$REPO/$script" --prefix '' --dry-run </dev/null 2>&1)
  STATUS=$?
  check_status "$script with an empty --prefix" 2
  check_match "$script names the empty --prefix, not HOME" "^${script%.sh}\\.sh: --prefix needs a folder\$" "$OUT"
done
OUT=$(XDG_STATE_HOME=relstate /bin/bash "$REPO/uninstall.sh" --prefix "$T/prefix-xdg" </dev/null 2>&1)
STATUS=$?
check_status "uninstall with a relative XDG_STATE_HOME" 0
check_match "uninstall names the HOME default, as the engine does" "by default under $HOME/\\.local/state/stack-up" "$OUT"
check_no_match "uninstall ignores the relative XDG_STATE_HOME" 'relstate' "$OUT"
OUT=$(HOME='' XDG_STATE_HOME='' /bin/bash "$REPO/uninstall.sh" --prefix "$T/prefix-xdg" </dev/null 2>&1)
STATUS=$?
check_status "uninstall with an empty HOME and a --prefix" 0
check_match "uninstall says no default folder can be named" 'no absolute HOME is set, so no default folder can be named' "$OUT"
check_no_match "uninstall names no state folder under /" '/\.local/state' "$OUT"
OUT=$(HOME=relhome XDG_STATE_HOME='' /bin/bash "$REPO/uninstall.sh" --prefix "$T/prefix-xdg" </dev/null 2>&1)
STATUS=$?
check_status "uninstall with a relative HOME and a --prefix" 0
check_match "uninstall ignores a relative HOME, as the engine does" 'no absolute HOME is set, so no default folder can be named' "$OUT"

# No HOME (unset, as under env -i, or empty) and no --prefix: both refuse to
# guess a prefix instead of working on /.local.
for script in install.sh uninstall.sh; do
  OUT=$(/usr/bin/env -i PATH=/usr/bin:/bin /bin/bash "$REPO/$script" --dry-run </dev/null 2>&1)
  STATUS=$?
  check_status "$script with HOME unset and no --prefix" 2
  check_match "$script asks for --prefix" "^${script%.sh}\\.sh: HOME is not set; pass --prefix\$" "$OUT"
  OUT=$(HOME='' /bin/bash "$REPO/$script" --dry-run </dev/null 2>&1)
  STATUS=$?
  check_status "$script with an empty HOME and no --prefix" 2
  check_no_match "$script names no prefix under /" '/\.local' "$OUT"
  OUT=$(/usr/bin/env -i PATH=/usr/bin:/bin /bin/bash "$REPO/$script" --prefix "$T/prefix-no-home" --dry-run </dev/null 2>&1)
  STATUS=$?
  check_status "$script with HOME unset and a --prefix" 0
done

# A file the person added beside a --copy install is not removed with it.
X=$T/prefix-extra
inst --prefix "$X" --copy
check_status "copy install to add a file to" 0
printf 'mine\n' >| "$X/share/stack-up/my-stack.conf"
uninst --prefix "$X" --dry-run
check_status "the uninstall dry run over a copy with an added file" 1
check_match "it says the copy holds files install.sh did not put there" 'left alone: .*/prefix-extra/share/stack-up also holds files' "$OUT"
uninst --prefix "$X"
check_status "uninstall of a copy with an added file" 1
testing_check "the added file is kept" mine "$(cat "$X/share/stack-up/my-stack.conf" 2>/dev/null)"
testing_check "the copy is kept with it" yes "$( [ -f "$X/share/stack-up/lib/conf.sh" ] && echo yes || echo no)"
testing_check "the install's own link is removed" no "$( [ -L "$X/bin/stack-up" ] && echo yes || echo no)"
rm "$X/share/stack-up/my-stack.conf"
uninst --prefix "$X"
check_status "uninstall once the added file is moved out" 0
testing_check "then the copy is gone" no "$( [ -e "$X/share/stack-up" ] && echo yes || echo no)"

# A link to another program is left alone, whether its target is absolute or
# relative to the link's folder; a relative link to a clone is ours.
mkdir -p "$T/other-tool/bin" "$T/prefix-fl/bin"
printf '#!/bin/bash\necho other\n' >> "$T/other-tool/bin/stack-up"
chmod +x "$T/other-tool/bin/stack-up"
ln -s "$T/other-tool/bin/stack-up" "$T/prefix-fl/bin/stack-up"
uninst --prefix "$T/prefix-fl" --dry-run
check_status "the uninstall dry run over a link to another program" 1
uninst --prefix "$T/prefix-fl"
check_status "uninstall over a link to another program" 1
check_match "it says the link is not an install link" 'left alone: .*/prefix-fl/bin/stack-up is not a stack-up install link' "$OUT"
testing_check "that link is kept" yes "$( [ -L "$T/prefix-fl/bin/stack-up" ] && echo yes || echo no)"
mkdir -p "$T/prefix-rl/opt/other/bin" "$T/prefix-rl/bin"
printf '#!/bin/bash\necho other\n' >> "$T/prefix-rl/opt/other/bin/stack-up"
chmod +x "$T/prefix-rl/opt/other/bin/stack-up"
(cd "$T/prefix-rl/bin" && ln -s ../opt/other/bin/stack-up stack-up)
OUT=$(cd "$T" && /bin/bash "$REPO/uninstall.sh" --prefix "$T/prefix-rl" </dev/null 2>&1)
STATUS=$?
check_status "uninstall over a relative link to another program" 1
check_match "it leaves that link alone" 'left alone: .*/prefix-rl/bin/stack-up is not a stack-up install link' "$OUT"
testing_check "the relative link is kept" yes "$( [ -L "$T/prefix-rl/bin/stack-up" ] && echo yes || echo no)"
mkdir -p "$T/prefix-rc/clone" "$T/prefix-rc/bin"
cp -R "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/bin" "$REPO/lib" "$REPO/VERSION" "$T/prefix-rc/clone/"
(cd "$T/prefix-rc/bin" && ln -s ../clone/bin/stack-up stack-up)
OUT=$(cd "$T" && /bin/bash "$REPO/uninstall.sh" --prefix "$T/prefix-rc" </dev/null 2>&1)
STATUS=$?
check_status "uninstall of a relative link to a clone" 0
testing_check "that link is removed" no "$( [ -L "$T/prefix-rc/bin/stack-up" ] && echo yes || echo no)"
testing_check "the clone is untouched" yes "$( [ -x "$T/prefix-rc/clone/bin/stack-up" ] && [ -f "$T/prefix-rc/clone/lib/conf.sh" ] && echo yes || echo no)"

# A rerun is "already installed" only when the installed tool answers with
# this version: a clone whose lib is broken, and a copy older than the clone,
# both exit 1.
BR=$T/broken-clone
cp -Rp "$REPO" "$BR"
mv "$BR/lib/term.sh" "$T/term.sh.moved"
OUT=$(/bin/bash "$BR/install.sh" --prefix "$T/prefix-broken" </dev/null 2>&1)
STATUS=$?
check_status "a link install from a clone whose lib is broken" 1
check_match "it says the installed name does not work" 'installed, but ' "$OUT"
OUT=$(/bin/bash "$BR/install.sh" --prefix "$T/prefix-broken" </dev/null 2>&1)
STATUS=$?
check_status "the same install again" 1
check_match "it is not called already installed" 'already linked, but .*--version printed' "$OUT"
OC=$T/old-clone
cp -Rp "$REPO" "$OC"
OUT=$(/bin/bash "$OC/install.sh" --prefix "$T/prefix-old" --copy </dev/null 2>&1)
STATUS=$?
check_status "a copy install to outgrow" 0
printf '9.9.9\n' >| "$OC/VERSION"
OUT=$(/bin/bash "$OC/install.sh" --prefix "$T/prefix-old" --copy </dev/null 2>&1)
STATUS=$?
check_status "a copy install over a copy older than the clone" 1
check_match "it says the link is there but the tool is not this version" 'already linked, but ' "$OUT"
check_match "and how to replace the copy" 'is not this version; run .*uninstall\.sh.* --prefix' "$OUT"
uninst --prefix "$T/prefix-broken"
uninst --prefix "$T/prefix-old"

# A --prefix with a trailing slash names the same folder.
OUT=$(PATH="$T/p-slash/bin:$PATH" /bin/bash "$REPO/install.sh" --prefix "$T/p-slash/" </dev/null 2>&1)
STATUS=$?
check_status "install with a trailing slash on --prefix" 0
check_match "it installs under that prefix" 'installed: .*/p-slash/bin/stack-up ' "$OUT"
check_no_match "it knows the bin folder is already on PATH" 'is not on PATH' "$OUT"
check_no_match "no path has a doubled slash" '//bin' "$OUT"
uninst --prefix "$T/p-slash/"
check_status "uninstall with a trailing slash on --prefix" 0
testing_check "the link is gone" no "$( [ -L "$T/p-slash/bin/stack-up" ] && echo yes || echo no)"

# A bin folder that the pasted PATH line would break on is named, not pasted.
OUT=$(SHELL=/bin/zsh /bin/bash "$REPO/install.sh" --prefix "$T/cost\$5" </dev/null 2>&1)
STATUS=$?
check_status "install into a folder with a \$ in its name" 0
check_no_match "no echo line to paste" "echo 'export PATH=" "$OUT"
check_match "the folder is named for the profile instead" 'to PATH in ~/\.zprofile' "$OUT"
uninst --prefix "$T/cost\$5"

inst --bogus
check_status "install with an unknown argument" 2
uninst --bogus
check_status "uninstall with an unknown argument" 2

testing_verdict
