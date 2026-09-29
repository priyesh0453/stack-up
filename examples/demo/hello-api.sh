#!/bin/bash
# hello-api: answers every request with the GREETING from demo-settings.env.
set -u
BODY="${GREETING:-}"$'\n'
export BODY
exec bash serve.sh text/plain
