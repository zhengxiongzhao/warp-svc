#!/bin/bash

# WARP connectivity self-healing monitor.
#
# Runs as a background process inside the container. Periodically checks whether
# the WARP tunnel is healthy. When consecutive failures exceed the configured
# threshold, it terminates gost (PID 1) so that `restart: always` / `--restart`
# can recreate the container and bring warp-svc back online.
#
# This script intentionally does NOT use `set -e` — it runs an infinite loop
# and must tolerate transient curl failures without exiting prematurely.

INTERVAL="${WARP_MONITOR_INTERVAL:-30}"
RETRIES="${WARP_MONITOR_RETRIES:-5}"

echo "[warp-monitor] Started (interval=${INTERVAL}s, threshold=${RETRIES})"

fail_count=0

while true; do
    sleep "$INTERVAL"

    # Reuse the same detection logic as connected-to-warp.sh
    if curl -fsS --connect-timeout 5 --max-time 10 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null \
        | grep -qE "warp=(plus|on)"; then
        if [ "$fail_count" -gt 0 ]; then
            echo "[warp-monitor] Connection restored after $fail_count consecutive failure(s)."
        fi
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        echo "[warp-monitor] WARP connectivity check failed ($fail_count/$RETRIES)."

        if [ "$fail_count" -ge "$RETRIES" ]; then
            echo "[warp-monitor] Failure threshold reached ($fail_count/$RETRIES). Restarting container..."
            # gost is PID 1 (via exec in entrypoint.sh); sending SIGTERM causes
            # the container to exit, which triggers restart:always.
            kill -TERM 1 2>/dev/null || true
            exit 0
        fi
    fi
done
