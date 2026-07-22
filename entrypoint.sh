#!/bin/bash

# exit when any command fails
set -e

export WARP_SLEEP=${WARP_SLEEP:-2}
export WARP_LICENSE_KEY=${WARP_LICENSE}

# create a tun device if not exist
# allow passing device to ensure compatibility with Podman
if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the daemon
# In debug/trace mode, forward warp-svc logs to stdout for troubleshooting.
# In all other modes, discard warp-svc output to keep container logs clean.
if [ "${LOG_LEVEL}" = "debug" ] || [ "${LOG_LEVEL}" = "trace" ]; then
    sudo warp-svc --accept-tos &
else
    sudo warp-svc --accept-tos > /dev/null &
fi

# sleep to wait for the daemon to start, default 5 seconds
sleep "$WARP_SLEEP"

# if /var/lib/cloudflare-warp/reg.json not exists, setup new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    # if /var/lib/cloudflare-warp/mdm.xml not exists or REGISTER_WHEN_MDM_EXISTS not empty, register the warp client
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        warp-cli registration new && echo "Warp client registered!"
        # if a license key is provided, register the license
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "License key found, registering license..."
            warp-cli registration license "$WARP_LICENSE_KEY" && echo "Warp license registered!"
        fi
    fi
    # connect to the warp server
    warp-cli --accept-tos connect
else
    echo "Warp client already registered, skip registration"
fi

# disable qlog if DEBUG_ENABLE_QLOG is empty
if [ -z "$DEBUG_ENABLE_QLOG" ]; then
    warp-cli --accept-tos debug qlog disable
else
    warp-cli --accept-tos debug qlog enable
fi

# if WARP_ENABLE_NAT is provided, enable NAT and forwarding
if [ -n "$WARP_ENABLE_NAT" ]; then
    # switch to warp mode
    echo "[NAT] Switching to warp mode..."
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect

    # wait another seconds for the daemon to reconfigure
    sleep "$WARP_SLEEP"

    # enable NAT
    echo "[NAT] Enabling NAT..."
    sudo nft add table ip nat
    sudo nft add chain ip nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip mangle
    sudo nft add chain ip mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

    sudo nft add table ip6 nat
    sudo nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip6 mangle
    sudo nft add chain ip6 mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
fi

# start the proxy
# gost v3 natively reads log level from GOST_LOGGER_LEVEL environment variable
# optional values (low to high): fatal error warn info debug trace
export GOST_LOGGER_LEVEL="${LOG_LEVEL:-error}"

# format listen host: IPv6 addresses need square brackets (e.g. [::]), IPv4 stays as-is
format_listen_host() {
    case "$1" in
        *:*) echo "[$1]" ;;
        *)   echo "$1"  ;;
    esac
}

# URL-encode user/pass to avoid breaking gost URL parsing with special characters
url_encode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' \
        -e 's/@/%40/g' \
        -e 's/:/%3A/g' \
        -e 's/#/%23/g' \
        -e 's/\?/%3F/g' \
        -e 's/&/%26/g' \
        -e 's/ /%20/g'
}

LISTEN_HOST=$(format_listen_host "${BIND_ADDR:-::}")
LISTEN_PORT="${BIND_PORT:-1080}"

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    URL_USER=$(url_encode "$SOCKS_USER")
    URL_PASS=$(url_encode "$SOCKS_PASS")
    GOST_LISTEN="socks5://${URL_USER}:${URL_PASS}@${LISTEN_HOST}:${LISTEN_PORT}"
    echo "SOCKS5 authentication enabled (User: $SOCKS_USER)"
else
    GOST_LISTEN="socks5://${LISTEN_HOST}:${LISTEN_PORT}"
    echo "SOCKS5 running in no-auth mode"
fi

echo "gost listening on ${BIND_ADDR:-::}:${LISTEN_PORT} (log level: ${GOST_LOGGER_LEVEL})"

# Start the self-healing monitor as a background process.
# When enabled, it periodically checks WARP connectivity and terminates the
# container (gost = PID 1) after repeated failures so that restart:always
# can bring everything back online.
if [ -n "$WARP_AUTO_RESTART" ]; then
    DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    # In the image, scripts are at /healthcheck/. Fall back to ./scripts for local dev.
    if [ ! -f "$DIR/scripts/warp-monitor.sh" ] && [ -f "/healthcheck/warp-monitor.sh" ]; then
        bash /healthcheck/warp-monitor.sh &
    else
        bash "$DIR/scripts/warp-monitor.sh" &
    fi
    echo "[warp-monitor] Self-healing monitor enabled."
fi

exec gost -L "$GOST_LISTEN"
