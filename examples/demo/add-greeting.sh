#!/bin/bash
# add-greeting.sh FILE: the repair for [check greeting]. It writes a new copy
# next to FILE and moves it into place, so a failure leaves FILE as it was.
set -u
file=${1:?usage: add-greeting.sh FILE}
next=$file.next.$$
{ cat -- "$file" && printf 'GREETING=hello from the demo stack\n'; } > "$next" || exit 1
mv -f -- "$next" "$file"
