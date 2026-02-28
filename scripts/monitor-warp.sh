#!/bin/bash

# Don't exit on error, handle failures gracefully
set +e

# get where the script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
MONITOR_INTERVAL=${MONITOR_INTERVAL:-30}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-10}
RECONNECT_WAIT=${RECONNECT_WAIT:-10}
RESTART_WAIT=${RESTART_WAIT:-15}

echo "[Monitor] Starting WARP connection monitor..."
echo "[Monitor] Configuration: interval=${MONITOR_INTERVAL}s, max_retries=${MAX_RETRIES}, retry_delay=${RETRY_DELAY}s, reconnect_wait=${RECONNECT_WAIT}s, restart_wait=${RESTART_WAIT}s"

# Function to get warp-svc PID
get_warp_svc_pid() {
    ps aux | grep '[w]arp-svc' | awk '{print $2}'
}

# Function to stop warp-svc
stop_warp_svc() {
    echo "[Monitor] Stopping warp-svc..."
    
    # Try to disconnect first
    warp-cli --accept-tos disconnect 2>&1 || true
    
    # Remove WARP data directory to force re-registration (only if WARP_LICENSE is not set)
    if [ -z "$WARP_LICENSE" ]; then
        echo "[Monitor] Removing WARP data directory (no WARP_LICENSE set)..."
        sudo rm -rf /var/lib/cloudflare-warp/* 2>/dev/null || true
    else
        echo "[Monitor] Preserving WARP data directory (WARP_LICENSE is set)"
    fi
    
    # Try to kill warp-svc using killall (preferred over pkill)
    if command -v killall >/dev/null 2>&1; then
        sudo killall -9 warp-svc 2>/dev/null || true
    elif command -v pkill >/dev/null 2>&1; then
        sudo pkill -9 warp-svc 2>/dev/null || true
    else
        # Fallback: manually find and kill
        WARP_PID=$(get_warp_svc_pid)
        if [ -n "$WARP_PID" ]; then
            sudo kill -9 $WARP_PID 2>/dev/null || true
        fi
    fi
    
    # Wait for process to terminate
    sleep 3
    
    # Verify it's stopped
    WARP_PID=$(get_warp_svc_pid)
    if [ -n "$WARP_PID" ]; then
        echo "[Monitor] Warning: warp-svc still running (PID: $WARP_PID), trying again..."
        if command -v killall >/dev/null 2>&1; then
            sudo killall -9 warp-svc 2>/dev/null || true
        elif command -v pkill >/dev/null 2>&1; then
            sudo pkill -9 warp-svc 2>/dev/null || true
        else
            sudo kill -9 $WARP_PID 2>/dev/null || true
        fi
        sleep 2
    fi
    
    # Clean up socket if exists
    sudo rm -f /run/warp-svc.sock 2>/dev/null || true
    sudo rm -f /var/run/warp-svc.sock 2>/dev/null || true
    
    echo "[Monitor] warp-svc stopped"
}

# Function to start warp-svc
start_warp_svc() {
    echo "[Monitor] Starting warp-svc..."
    sudo warp-svc --accept-tos > /dev/null 2>&1 &
    echo "[Monitor] Waiting ${RESTART_WAIT}s for warp-svc to start..."
    sleep $RESTART_WAIT
    
    # Verify it's running
    WARP_PID=$(get_warp_svc_pid)
    if [ -z "$WARP_PID" ]; then
        echo "[Monitor] Error: warp-svc failed to start"
        return 1
    fi
    
    echo "[Monitor] warp-svc started (PID: $WARP_PID)"
    return 0
}

while true; do
    # Check WARP connection using the same logic as healthcheck
    echo "[Monitor] Checking WARP connection..."
    TRACE_OUTPUT=$(curl -fsS --max-time 10 "https://cloudflare.com/cdn-cgi/trace" 2>&1)
    CURL_EXIT_CODE=$?
    
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "[Monitor] curl failed with exit code $CURL_EXIT_CODE: $TRACE_OUTPUT"
    fi
    
    if ! echo "$TRACE_OUTPUT" | grep -qE "warp=(plus|on)"; then
        echo "[Monitor] WARP connection lost, attempting to reconnect..."
        
        retry_count=0
        while [ $retry_count -lt $MAX_RETRIES ]; do
            echo "[Monitor] Reconnect attempt $((retry_count + 1))/${MAX_RETRIES}..."
            
            # Try to reconnect
            warp-cli --accept-tos disconnect 2>&1 || true
            sleep 2
            warp-cli --accept-tos connect 2>&1 || true
            
            # Wait for connection to establish (longer wait time)
            echo "[Monitor] Waiting ${RECONNECT_WAIT}s for WARP connection to establish..."
            sleep $RECONNECT_WAIT
            
            # Check if reconnection was successful
            echo "[Monitor] Checking connection status after reconnect..."
            TRACE_OUTPUT=$(curl -fsS --max-time 10 "https://cloudflare.com/cdn-cgi/trace" 2>&1)
            CURL_EXIT_CODE=$?
            
            if [ $CURL_EXIT_CODE -eq 0 ] && echo "$TRACE_OUTPUT" | grep -qE "warp=(plus|on)"; then
                echo "[Monitor] WARP reconnected successfully!"
                break
            else
                echo "[Monitor] Reconnection check failed (curl exit code: $CURL_EXIT_CODE)"
                if [ $CURL_EXIT_CODE -eq 0 ]; then
                    echo "[Monitor] Trace output: $TRACE_OUTPUT"
                fi
            fi
            
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $MAX_RETRIES ]; then
                echo "[Monitor] Reconnect attempt failed, retrying in ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
            fi
        done
        
        # If max retries reached, restart warp-svc service
        if [ $retry_count -ge $MAX_RETRIES ]; then
            echo "[Monitor] Max retries reached, restarting warp-svc..."
            stop_warp_svc
            start_warp_svc
            
            if [ $? -eq 0 ]; then
                # Check if registration is needed (reg.json doesn't exist)
                if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
                    echo "[Monitor] WARP client not registered, registering..."
                    
                    # Register new WARP client
                    if warp-cli --accept-tos registration new 2>&1; then
                        echo "[Monitor] WARP client registered successfully!"
                        
                        # Register license if provided
                        if [ -n "$WARP_LICENSE" ]; then
                            echo "[Monitor] Registering WARP+ license..."
                            warp-cli --accept-tos registration license "$WARP_LICENSE" 2>&1 && echo "[Monitor] WARP+ license registered!"
                        fi
                    else
                        echo "[Monitor] Error: Failed to register WARP client"
                    fi
                else
                    echo "[Monitor] WARP client already registered, skipping registration"
                fi
                
                # Connect to WARP
                warp-cli --accept-tos connect 2>&1 || true
                echo "[Monitor] Waiting ${RECONNECT_WAIT}s for WARP connection to establish..."
                sleep $RECONNECT_WAIT
                echo "[Monitor] warp-svc restarted and reconnected"
            else
                echo "[Monitor] Error: Failed to restart warp-svc"
            fi
        fi
    else
        echo "[Monitor] WARP connection OK"
    fi
    
    sleep $MONITOR_INTERVAL
done
