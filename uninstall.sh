#!/bin/bash
# uninstall.sh - removes the link and the copy that install.sh made, and
# nothing else. Never uses sudo. It keeps PREFIX/bin and PREFIX/share even when
# install.sh created them, since other tools use them too, and it keeps every
# stack's state and logs; stack-up --print-paths (with the --root the stack was
# started with, if any) shows where they are, so run it before uninstalling if
# you want to delete them.
# Exit status: 0 removed (or nothing to remove), 1 refused or something left, 2 usage.

set -u

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--prefix DIR] [--dry-run]

  --prefix DIR   the prefix given to install.sh (default: $HOME/.local)
  --dry-run      print what would be removed, remove nothing
  -h, --help     print this help
USAGE
}

prefix=${HOME:+$HOME/.local}
dry=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --prefix)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'uninstall.sh: --prefix needs a folder\n' >&2; exit 2; }
      prefix=$2
      shift 2
      continue
      ;;
    --dry-run) dry=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'uninstall.sh: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$prefix" ] || { printf 'uninstall.sh: HOME is not set; pass --prefix\n' >&2; exit 2; }
case $prefix in
  /*) ;;
  *) prefix=$PWD/$prefix ;;
esac
# install.sh drops trailing slashes the same way, so both name the same paths.
while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]; do prefix=${prefix%/}; done

link=$prefix/bin/stack-up
share=$prefix/share/stack-up
left=0
say() { printf '  %s\n' "$*"; }

# A link is ours when it points at a bin/stack-up with the stack-up lib and
# VERSION beside it, or into this prefix's share folder, or when it dangles (a
# moved clone); anything else at that path is left alone.
is_our_link() {
  local target dir
  [ -L "$link" ] || return 1
  target=$(readlink "$link") || return 1
  # A relative target is relative to the link's folder, not to this one.
  case $target in
    /*) ;;
    *) target=${link%/*}/$target ;;
  esac
  case $target in
    */bin/stack-up) ;;
    *) return 1 ;;
  esac
  dir=${target%/bin/stack-up}
  [ -e "$target" ] || return 0
  [ -f "$dir/VERSION" ] && [ -f "$dir/lib/conf.sh" ] || [ "$dir" = "$share" ]
}

printf 'stack-up uninstall from %s\n' "$prefix"
if [ -L "$link" ] || [ -e "$link" ]; then
  if is_our_link; then
    if [ "$dry" = 1 ]; then say "would remove the link $link"; else rm -f -- "$link" && say "removed $link"; fi
  else
    say "left alone: $link is not a stack-up install link"
    left=1
  fi
else
  say "no link at $link"
fi
# The marker goes last and comes back if the folder itself cannot be removed,
# so a removal that fails part way leaves a copy that a rerun still
# recognizes as this install's.
remove_copy() {
  local marker
  find "$share" -mindepth 1 -maxdepth 1 ! -name INSTALLED -exec rm -r -- {} + || return 1
  [ -z "$(find "$share" -mindepth 1 -maxdepth 1 ! -name INSTALLED)" ] || return 1
  marker=$(cat "$share/INSTALLED" 2>/dev/null)
  rm -- "$share/INSTALLED" || return 1
  if ! rmdir -- "$share"; then
    printf '%s\n' "$marker" > "$share/INSTALLED" 2>/dev/null
    return 1
  fi
}

copy_was_ours=0
if [ -L "$share" ]; then
  say "left alone: $share is a link, not a copy made by install.sh --copy"
  left=1
elif [ -d "$share" ]; then
  if [ -f "$share/INSTALLED" ]; then
    # A file the person added beside the copy is not install.sh's to remove.
    extra=$(find "$share" -mindepth 1 -maxdepth 1 ! -name INSTALLED ! -name bin ! -name lib ! -name VERSION ! -name LICENSE)
    if [ -n "$extra" ]; then
      say "left alone: $share also holds files install.sh --copy did not put there; move them out, then run uninstall.sh again"
      left=1
    else
      copy_was_ours=1
      if [ "$dry" = 1 ]; then say "would remove the copy $share"; elif remove_copy; then say "removed $share"; fi
    fi
  else
    say "left alone: $share has no INSTALLED marker from install.sh --copy"
    left=1
  fi
fi
[ "$dry" = 0 ] || exit "$left"

if [ -L "$link" ] && is_our_link; then left=1; say "still present: $link"; fi
if [ "$copy_was_ours" = 1 ] && { [ -e "$share" ] || [ -L "$share" ]; }; then
  left=1
  say "still present: $share; fix what stopped the removal (a folder you cannot write, for example), then rerun"
fi
# The default state folder named below must be the one the engine uses, and
# the engine ignores a relative XDG_STATE_HOME, as the XDG spec says, and a
# relative HOME.
state_home=${XDG_STATE_HOME:-}
case $state_home in
  /*) ;;
  *)
    state_home=""
    case ${HOME:-} in
      /*) state_home=$HOME/.local/state ;;
    esac
    ;;
esac
if [ -n "$state_home" ]; then
  say "state and logs were kept; bin/stack-up --config FILE --print-paths in the repository (with the --root the stack was started with, if any) shows where for each stack (by default under $state_home/stack-up, unless its config sets state_dir)"
else
  say "state and logs were kept; bin/stack-up --config FILE --print-paths in the repository (with the --root the stack was started with, if any) shows where for each stack (no absolute HOME is set, so no default folder can be named)"
fi
if [ "$left" = 0 ]; then
  say "done"
  exit 0
fi
exit 1
