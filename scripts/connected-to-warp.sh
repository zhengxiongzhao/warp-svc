#!/bin/bash

# exit when any command fails; fail on any pipe segment error
set -eo pipefail

curl -fsS --connect-timeout 5 --max-time 10 \
    "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0
