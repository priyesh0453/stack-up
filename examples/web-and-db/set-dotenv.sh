#!/bin/bash
# set-dotenv.sh FILE KEY VALUE: the repair for [check web-api-url]. Sets KEY
# to VALUE in a KEY=VALUE file: the line KEY already has is replaced in place
# (an export prefix counts, and a duplicate is dropped), otherwise a line is
# appended, and a missing FILE is created. The new content goes to a copy
# beside FILE that is then moved into place, so a failure part-way leaves
# FILE as it was; stack-up has copied FILE into its backups folder before this
# runs. KEY must be a variable name because it becomes part of a pattern;
# VALUE is written as given, without quotes.
set -u
usage='usage: set-dotenv.sh FILE KEY VALUE'
file=${1:?$usage}
key=${2:?$usage}
value=${3:?$usage}
case $key in
  ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
    printf 'set-dotenv.sh: %s is not a variable name\n' "$key" >&2
    exit 2
    ;;
esac
next=$file.next.$$
if [ -e "$file" ]; then
  KEY=$key VALUE=$value awk '
    BEGIN { pattern = "^[ \t]*(export[ \t]+)?" ENVIRON["KEY"] "=" }
    $0 ~ pattern { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"] }
  ' < "$file" > "$next" || { rm -f -- "$next"; exit 1; }
else
  printf '%s=%s\n' "$key" "$value" > "$next" || { rm -f -- "$next"; exit 1; }
fi
mv -f -- "$next" "$file"
