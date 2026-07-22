# warp-svc

[![Publish Docker image to Docker Hub](https://img.shields.io/badge/Publish%20Docker%20image%20to%20Docker%20Hub-latest-g?logo=docker)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)

> **Built with the latest version of `warp-svc`, version: 2025.10.186.0**

> **⚠️ Requirement: International network access is required !**

## Overview

Run Cloudflare WARP client as a SOCKS5 proxy server in Docker.

This Docker image packages the official Cloudflare WARP client for Linux and provides a SOCKS5 proxy server that can be used in:
- Local machine applications
- Other Docker containers via docker-compose

**Why this project?** The official Cloudflare WARP client for Linux only listens on localhost, making it unusable in Docker containers that need to bind to 0.0.0.0. This image solves that problem by using `gost` (v3) to forward traffic.

---

## Features

✨ **Automatic Registration** - Register new Cloudflare WARP accounts automatically
⚡ **WARP+ Support** - Subscribe to Cloudflare WARP+ for unlimited data
🔄 **Health Monitoring** - Built-in health checks with automatic recovery
🔧 **Self-Healing** - Optional auto-restart when WARP tunnel goes down
🐳 **Multi-arch Support** - Works on amd64 and arm64 platforms

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)

---

## Prerequisites

### Host System Requirements

The container requires specific kernel modules and capabilities:

**Required Docker flags:**
- `--device /dev/net/tun` - Access to TUN device for virtual network interface
- `--cap-add NET_ADMIN` - Modify network configuration (interfaces, routing)
- `--cap-add MKNOD` - Create device nodes
- `--cap-add AUDIT_WRITE` - Write to audit log

### Host System Setup

Run these commands on your host system before starting the container:

```bash
# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p

# Allow masquerading in firewall (required for RHEL 9)
firewall-cmd --zone=public --add-masquerade --permanent

# Load required kernel modules
modprobe nf_conntrack
modprobe tun

# Set modules to auto-load on boot
echo -e "nf_conntrack\ntun" > /etc/modules-load.d/custom-modules.conf

# Verify setup
lsmod | grep -E "nf_conntrack|tun"
ls -l /dev/net/tun
```

---

## Quick Start

### Using Docker Compose (Recommended)

Create a `docker-compose.yml` file:

```yaml
services:
  cloudflare-warp:
    image: zhengxiongzhao/warp-svc:latest
    container_name: cloudflare-warp
    restart: always
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    mem_limit: 512m
    devices:
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
      - MKNOD
      - AUDIT_WRITE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      TZ: Asia/Shanghai
      BIND_PORT: 1080
      LOG_LEVEL: error
      # SOCKS_USER: admin       # optional: enable SOCKS5 auth
      # SOCKS_PASS: 123456      # requires SOCKS_USER
    # Optional: Persist WARP account data
    # volumes:
    #   - ./data:/var/lib/cloudflare-warp
```

Start the container:

```bash
docker-compose up -d
```

Verify that WARP is active and working:

```bash
curl -x socks5h://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

**Expected output:**
```
warp=on
```

or for WARP+ users:
```
warp=plus
```


### Using Docker CLI

```bash
docker run -d \
  --name cloudflare-warp \
  --restart always \
  --device /dev/net/tun \
  --cap-add NET_ADMIN \
  --cap-add MKNOD \
  --cap-add AUDIT_WRITE \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e TZ=Asia/Shanghai \
  -e BIND_PORT=1080 \
  -p 1080:1080 \
  zhengxiongzhao/warp-svc:latest
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Asia/Shanghai` | Container timezone |
| `WARP_SLEEP` | `2` | Seconds to wait for warp-svc initialization |
| `WARP_LICENSE` | _(empty)_ | WARP+ license key for unlimited data |
| `BIND_ADDR` | `::` | SOCKS5 bind address, `::` for IPv4/IPv6 dual-stack |
| `BIND_PORT` | `1080` | SOCKS5 listen port |
| `SOCKS_USER` | _(empty)_ | SOCKS5 authentication username, empty = no auth |
| `SOCKS_PASS` | _(empty)_ | SOCKS5 authentication password, requires `SOCKS_USER` |
| `LOG_LEVEL` | `error` | gost log level: `fatal`, `error`, `warn`, `info`, `debug`, `trace` |
| `WARP_ENABLE_NAT` | _(empty)_ | Enable NAT mode (experimental): route container traffic through WARP interface |
| `BETA_FIX_HOST_CONNECTIVITY` | _(empty)_ | Enable host-to-container connectivity fix via nft rules (BETA) |
| `REGISTER_WHEN_MDM_EXISTS` | _(empty)_ | Force re-registration even when `mdm.xml` already exists |
| `DEBUG_ENABLE_QLOG` | _(empty)_ | Enable WARP QUIC logging (qlog) for debugging |
| `WARP_AUTO_RESTART` | `1` | Set to empty to disable self-healing: auto-restart container when WARP tunnel is down |
| `WARP_MONITOR_INTERVAL` | `30` | Self-healing check interval in seconds |
| `WARP_MONITOR_RETRIES` | `5` | Consecutive check failures before triggering container restart |

### Persistent Storage

To persist your WARP account data (recommended for WARP+ users):

```yaml
volumes:
  - ./data:/var/lib/cloudflare-warp
```

**Important:** Each WARP+ license supports only 4 devices. Persisting data prevents unnecessary re-registration.

---

## Verification

### Test WARP Connection

Verify that WARP is active and working:

```bash
curl -x socks5h://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

**Expected output:**
```
warp=on
```

or for WARP+ users:
```
warp=plus
```

---

## Self-Healing (Auto-Restart on WARP Failure)

Docker's built-in health check only marks the container as `unhealthy` — it does **not** restart it. If the WARP tunnel goes down while gost (the proxy process) keeps running, the container stays up but traffic is routed through your direct connection instead of WARP.

Self-healing mode is **enabled by default** (`WARP_AUTO_RESTART=1`). To disable it, set the variable to empty:

```yaml
environment:
  - WARP_AUTO_RESTART=         # disable self-healing
  # WARP_MONITOR_INTERVAL=30   # check every 30 seconds (default)
  # WARP_MONITOR_RETRIES=5     # restart after 5 consecutive failures (default)
```

**How it works:**

1. A background monitor runs inside the container, checking WARP connectivity every `WARP_MONITOR_INTERVAL` seconds.
2. If WARP is unreachable for `WARP_MONITOR_RETRIES` consecutive checks, the monitor terminates gost (the container's main process).
3. Docker's `restart: always` policy then recreates the container, starting a fresh WARP session.

> ⚠️ This feature requires `restart: always` (or equivalent restart policy) to be set. Without it, the container will simply stop after termination.

With the default settings, the maximum time to detect and recover from a failure is approximately **2.5 minutes** (30s × 5 retries).

---

## Additional Resources

- [Cloudflare WARP Documentation](https://developers.cloudflare.com/warp-client/)
- [Docker Hub Repository](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
- [GitHub Issues](https://github.com/zhengxiongzhao/docker-warp-proxy/issues)

---

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.
