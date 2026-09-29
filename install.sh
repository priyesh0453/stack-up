#!/bin/bash
# install.sh - puts stack-up on PATH for the current user. Never uses sudo.
#   default   a symlink PREFIX/bin/stack-up -> this folder's bin/stack-up
#   --copy    a copy in PREFIX/share/stack-up, linked from PREFIX/bin
# It creates PREFIX/bin and PREFIX/share/stack-up as needed, writes nothing
# else, and refuses to replace a link or folder it did not make.
# Exit status: 0 installed (or already installed), 1 refused or failed, 2 usage.

set -u
# An exported CDPATH makes cd print the folder it found, which would end up in
# the $(cd ... && pwd -P) below.
unset CDPATH

usage() {
  cat <<'USAGE'
Usage: install.sh [--prefix DIR] [--copy] [--dry-run]

  --prefix DIR   install under DIR (default: $HOME/.local); stack-up goes in DIR/bin
  --copy         copy the tool into DIR/share/stack-up instead of linking to this folder
  --dry-run      print what would change, change nothing
  -h, --help     print this help

Undo with: ./uninstall.sh --prefix DIR, from this folder
USAGE
}

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
prefix=${HOME:+$HOME/.local}
mode="link"
dry=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --prefix)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'install.sh: --prefix needs a folder\n' >&2; exit 2; }
      prefix=$2
      shift 2
      continue
      ;;
    --copy) mode=copy ;;
    --dry-run) dry=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$prefix" ] || { printf 'install.sh: HOME is not set; pass --prefix\n' >&2; exit 2; }
case $prefix in
  /*) ;;
  *) prefix=$PWD/$prefix ;;
esac
# A trailing slash would make bin_dir end in //bin, which no PATH entry equals.
while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]; do prefix=${prefix%/}; done

version=$(cat "$here/VERSION" 2>/dev/null) || version=unknown
bin_dir=$prefix/bin
link=$bin_dir/stack-up
share=$prefix/share/stack-up
if [ "$mode" = copy ]; then target=$share/bin/stack-up; else target=$here/bin/stack-up; fi

say() { printf '  %s\n' "$*"; }
# %q under the C locale keeps a printed command ASCII in every locale.
quote() {
  local LC_ALL=C
  printf '%q' "$1"
}
run() {
  local word
  if [ "$dry" = 1 ]; then
    printf '  would run:'
    for word in "$@"; do printf ' %s' "$(quote "$word")"; done
    printf '\n'
    return 0
  fi
  "$@"
}
# A link that points at the right file proves nothing about the tool behind
# it: a failed install, a damaged copy or an older copy all look the same.
installed_ok() {
  got=$("$link" --version 2>&1) && [ "$got" = "stack-up $version" ]
}

printf 'stack-up %s: %s install into %s\n' "$version" "$mode" "$prefix"

if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
  if installed_ok; then
    say "already installed: $link -> $target"
    exit 0
  fi
  say "already linked, but $link --version printed: $got"
  [ "$mode" != copy ] || say "the copy in $share is not this version; run $(quote "$here/uninstall.sh") --prefix $(quote "$prefix"), then install again"
  exit 1
fi
if [ -e "$link" ] || [ -L "$link" ]; then
  say "refusing: $link already exists and is not this install"
  say "remove it yourself, or run $(quote "$here/uninstall.sh") --prefix $(quote "$prefix") if it came from here"
  exit 1
fi
if [ "$mode" = copy ] && [ -L "$share" ]; then
  say "refusing: $share is a link, not a copy this install made; remove the link yourself if it is not needed"
  exit 1
fi
# uninstall.sh removes only a share folder with the marker, so sending the
# person there for any other folder would lead nowhere.
if [ "$mode" = copy ] && [ -e "$share" ]; then
  if [ -f "$share/INSTALLED" ]; then
    say "refusing: $share already exists; run $(quote "$here/uninstall.sh") --prefix $(quote "$prefix") first"
  else
    say "refusing: $share already exists and was not made by install.sh --copy; move it away, or remove it yourself if it is not needed"
  fi
  exit 1
fi
probe=$prefix
while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
if [ ! -w "$probe" ]; then
  say "refusing: $probe is not writable by you; pick --prefix under your home folder (no sudo)"
  exit 1
fi

copy_failed() {
  say "the copy into $share failed; run $(quote "$here/uninstall.sh") --prefix $(quote "$prefix") to remove the partial copy"
  exit 1
}

run mkdir -p "$bin_dir" || exit 1
if [ "$mode" = copy ]; then
  run mkdir -p "$share/bin" || exit 1
  # The marker goes in first, so uninstall.sh can remove a copy that failed
  # half way; install.sh refuses an existing share folder, so it is ours.
  if [ "$dry" = 0 ]; then
    printf 'stack-up %s, copied from %s\n' "$version" "$here" >> "$share/INSTALLED" || copy_failed
  else
    say "would write: $share/INSTALLED"
  fi
  run cp -p "$here/bin/stack-up" "$share/bin/stack-up" || copy_failed
  run cp -R -p "$here/lib" "$share/lib" || copy_failed
  run cp -p "$here/VERSION" "$here/LICENSE" "$share/" || copy_failed
fi
run ln -s "$target" "$link" || exit 1
[ "$dry" = 0 ] || exit 0

if ! installed_ok; then
  say "installed, but $link --version printed: $got"
  exit 1
fi
say "installed: $link -> $target ($got)"
case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *)
    say "$bin_dir is not on PATH yet, so the bare name stack-up will not be found."
    # shellcheck disable=SC2088 # printed for the person to paste, not expanded here
    case ${SHELL:-} in
      */bash) profile='~/.bash_profile'; shell_is="For bash, your login shell" ;;
      *) profile='~/.zprofile'; shell_is="For zsh, the default shell on a Mac" ;;
    esac
    # Pasted, the echo line would break on a quote, or run $(...) and backquotes
    # at every login, so such a folder is named instead.
    case $bin_dir in
      *"'"*|*'"'*|*'$'*|*'`'*|*"\\"*)
        say "Add $(quote "$bin_dir") to PATH in $profile, then open a new Terminal window."
        ;;
      *)
        say "$shell_is, run this once, then open a new Terminal window:"
        say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> $profile"
        ;;
    esac
    say "Until then, run $link by its full path."
    ;;
esac
exit 0
