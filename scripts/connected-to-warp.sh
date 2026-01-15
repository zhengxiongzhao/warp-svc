#!/bin/bash

curl -x 127.0.0.1:40000 -fsS "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0