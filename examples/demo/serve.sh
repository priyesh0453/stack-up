#!/bin/bash
# serve.sh TYPE: answers every HTTP request on 127.0.0.1:$PORT with $BODY.
# nc serves one connection per run, so two workers share the port (nc sets
# SO_REUSEPORT) and one keeps listening while the other starts over.
set -u
export LC_ALL=C
: "${PORT:?PORT is not set; stack-up exports it from the port key}"
type=${1:-text/plain}
body=${BODY:-}

worker() {
  local failures=0
  while :; do
    if printf 'HTTP/1.0 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
      "$type" "${#body}" "$body" | nc -l 127.0.0.1 "$PORT"; then
      failures=0
    else
      failures=$((failures + 1))
      [ "$failures" -lt 5 ] || exit 1
      sleep 1
    fi
  done
}

worker &
worker
