#!/bin/bash
# docs-site: answers every request with www/index.html.
set -u
BODY=$(cat www/index.html)$'\n'
export BODY
exec bash serve.sh 'text/html; charset=us-ascii'
