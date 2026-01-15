#!/bin/bash
set -e

export WARP_SLEEP=${WARP_SLEEP:-2}
export GOST_LOGGER_LEVEL=${LOG_LEVEL:-error}
export GOMAXPROCS=${GOMAXPROCS:-1}

if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf


sudo /usr/bin/warp-svc --accept-tos > /dev/null &

WARP_PID=$!

sleep "$WARP_SLEEP"

current_license=$(warp-cli --accept-tos registration show | grep 'License:' | awk '{print $2}' || echo "")

if [ -n "$WARP_LICENSE" ]; then
    if [ "$current_license" = "$WARP_LICENSE" ]; then
        echo "Current License matches $WARP_LICENSE, no need to re-register."
    else
        echo "Applying License key..."
        if warp-cli --accept-tos registration license "$WARP_LICENSE" | grep -q "Success"; then
            echo "License applied successfully."
        else
            echo "License failed, registering new..."
            warp-cli --accept-tos registration delete > /dev/null || true
            warp-cli --accept-tos registration new  > /dev/null || true
        fi
    fi
else
    if [ -n "$current_license" ]; then
        echo "License exists: $current_license, skipping new registration."
    else
        echo "No License found, registering new..."
        warp-cli --accept-tos registration new  > /dev/null || true
    fi
fi

# warp-cli --accept-tos proxy port "${PROXY_PORT}"
warp-cli --accept-tos mode proxy > /dev/null || true
warp-cli --accept-tos dns families "${FAMILIES_MODE:-off}" > /dev/null || true
warp-cli --accept-tos connect > /dev/null || true
warp-cli --accept-tos status

# wait $WARP_PID

# Health monitor configuration
export HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-15}
export HEALTH_CHECK_RETRIES=${HEALTH_CHECK_RETRIES:-3}

# Start gost in background
gost -L "tcp://:${PROXY_PORT}/127.0.0.1:40000?keepalive=true&ttl=5s&readBufferSize=2048" -L "udp://:${PROXY_PORT}/127.0.0.1:40000?keepalive=true&ttl=5s&readBufferSize=2048" &
GOST_PID=$!

# Fix： first health check failed
sleep "$WARP_SLEEP"

# Health monitor loop
failure_count=0
while true; do
    # Check if gost process is still running
    if ! kill -0 $GOST_PID 2>/dev/null; then
        echo "gost process died, restarting..."
        gost -L "tcp://:${PROXY_PORT}/127.0.0.1:40000?keepalive=true&ttl=5s&readBufferSize=2048" -L "udp://:${PROXY_PORT}/127.0.0.1:40000?keepalive=true&ttl=5s&readBufferSize=2048" &
        GOST_PID=$!
        failure_count=0
    fi
    
    if /scripts/healthcheck.sh; then
        failure_count=0
    else
        failure_count=$((failure_count + 1))
        echo "Health check failed ($failure_count/$HEALTH_CHECK_RETRIES)"
        
        if [ $failure_count -ge $HEALTH_CHECK_RETRIES ]; then
            echo "Health check failed $failure_count times, exiting to trigger container restart..."
            kill $GOST_PID 2>/dev/null || true
            exit 1
        fi
    fi
    
    sleep $HEALTH_CHECK_INTERVAL
done