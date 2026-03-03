#!/bin/bash

# Don't exit on error, handle failures gracefully
set +e

# get where the script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
MONITOR_INTERVAL=${MONITOR_INTERVAL:-5}
MAX_CHECK_RETRIES=${MAX_CHECK_RETRIES:-3}
RESTART_WAIT=${RESTART_WAIT:-${WARP_SLEEP:-2}}

# Monitor started silently

# Check count
check_count=0
# Failed check count
failed_count=0

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
    check_count=$((check_count + 1))
    # Check if warp-svc process is running
    WARP_PID=$(get_warp_svc_pid)
    
    if [ -z "$WARP_PID" ]; then
        failed_count=$((failed_count + 1))
        
        # If failed count reaches max, restart warp-svc
        if [ $failed_count -ge $MAX_CHECK_RETRIES ]; then
            echo "[Monitor] Max failed checks reached, restarting warp-svc..."
            failed_count=0
            
            # Stop any lingering processes and clean up
            stop_warp_svc
            
            # Start warp-svc
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
                echo "[Monitor] Waiting ${RESTART_WAIT}s for WARP connection to establish..."
                sleep $RESTART_WAIT
                echo "[Monitor] warp-svc restarted and reconnected"
            else
                echo "[Monitor] Error: Failed to restart warp-svc"
            fi
        fi
    else
        failed_count=0
    fi
    
    sleep $MONITOR_INTERVAL
done
