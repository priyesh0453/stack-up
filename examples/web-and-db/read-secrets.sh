#!/bin/bash
# read-secrets.sh FILE: the [env secrets] provider. Prints the KEY=VALUE lines
# of FILE for stack-up to hand to the entries that name the provider in
# env_from. It is a script rather than a plain cat so that comments and blank
# lines never reach the provider parser, a missing file fails with the fix in
# the message, and a bad line is named by its number and never by its
# content. Nothing is printed until the whole file has been read, so a bad
# line means no value leaves this script. Values pass as written: quotes
# stay, nothing is expanded, an export prefix is dropped, the same rules
# stack-up applies to an env_file. Replace the body with a call to your
# secret manager's CLI when you have one; the contract is only "print
# KEY=VALUE lines and exit 0".
set -u
file=${1:?usage: read-secrets.sh FILE}
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  printf 'read-secrets.sh: %s is missing or not readable; copy .env.example to %s and fill in the values\n' "$file" "$file" >&2
  exit 1
fi
n=0
out=""
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line=${line%$'\r'}
  line=${line#"${line%%[![:space:]]*}"}
  case $line in
    ''|'#'*) continue ;;
    export\ *|export$'\t'*)
      line=${line#export}
      line=${line#"${line%%[![:space:]]*}"}
      ;;
  esac
  key=${line%%=*}
  case $key in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) key="" ;;
  esac
  case $line in
    *=*) ;;
    *) key="" ;;
  esac
  if [ -z "$key" ]; then
    printf 'read-secrets.sh: line %s of %s is not KEY=VALUE\n' "$n" "$file" >&2
    exit 1
  fi
  out="$out$line"$'\n'
done < "$file"
printf '%s' "$out"
