# warp-svc

[![Publish Docker image to Docker Hub](https://img.shields.io/badge/Publish%20Docker%20image%20to%20Docker%20Hub-latest-g?logo=docker)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)

## Overview

Run Cloudflare WARP as a **SOCKS5 / HTTP / HTTPS** proxy server in Docker.

This image uses the Linux kernel WireGuard tunnel (built-in) + the lightweight **vproxy** (Rust) engine, which auto-detects SOCKS5 / HTTP / HTTPS on a single port. It can be used in:
- Local machine applications
- Other Docker containers via docker-compose

> **📖 Full documentation** is available in [README-hub.md](README-hub.md) — Quick Start, environment variable reference, registration flows, WARP+ and more.

---

## Features

✨ **Automatic Registration** - Native Python registration flow with automatic `wgcf` fallback
🛡️ **Single-port Multi-protocol** - vproxy auto-detects SOCKS5/HTTP/HTTPS on one port
⚡ **WARP+ Support** - Via locally generated `wgcf` profile
🌐 **IPv6 Dual-stack Support** - Proxy IPv4 and IPv6 traffic through WARP
🔄 **Endpoint Auto-selection** - Picks the fastest WARP Endpoint automatically
🐳 **Multi-arch Support** - Works on amd64 and arm64 platforms

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting-manual-warp-config-generation)

---

## Prerequisites

### Host System Requirements

The container requires specific kernel modules and capabilities:

**Required Docker flags:**
- `--device /dev/net/tun` - Access to TUN device for virtual network interface
- `--cap-add NET_ADMIN` - Modify network configuration (interfaces, routing)
- `--cap-add SYS_MODULE` - Load kernel modules

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
    ports:
      - "1080:1080"
    environment:
      TZ: Asia/Shanghai
      BIND_ADDR: "::"
      BIND_PORT: "1080"
      ENABLE_IPV6: "1"
      # - SOCKS_USER=admin              # optional: enable proxy auth
      # - SOCKS_PASS=your-password      # requires SOCKS_USER
      # - WARP_PROXY=http://127.0.0.1:1080  # optional: HTTP(S) proxy for registration API
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
    volumes:
      - warp-data:/etc/wireguard
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

---

## Troubleshooting: Manual WARP Config Generation

On first startup, the container tries the **native registration flow** first (up to 3 attempts) via `warp_register.py`. If all attempts fail, it falls back automatically to the original `wgcf` registration flow.

If the container logs show WARP registration failures (typically caused by datacenter IP rate limiting by Cloudflare), you can generate the WireGuard config on your local machine and mount it into the container.

### Step 1: Generate `wg0.conf` locally

Run the one-liner script on your **local machine** (supports Linux/macOS):

```bash
curl -Lso- zxzhao.com/t/warp_register.sh | bash
```

This will:
- Auto-detect your OS and CPU architecture
- Download the latest `wgcf` binary
- Register a WARP device and generate `wgcf-profile.conf`
- Rename it to `wg0.conf`

### Step 2: Upload `wg0.conf` to your VPS

```bash
scp wg0.conf user@your-vps:/path/to/project/warp-data/wg0.conf
```

### Step 3: Enable volume mount in `docker-compose.yml`

Uncomment or add the `volumes` section:

```yaml
    volumes:
      - ./warp-data:/etc/wireguard
```

### Step 4: Restart the container

```bash
docker-compose restart
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Asia/Shanghai` | Container timezone |
| `BIND_ADDR` | `::` | Proxy bind address, `::` for IPv4/IPv6 dual-stack |
| `BIND_PORT` | `1080` | Proxy listen port (auto-detects SOCKS5/HTTP/HTTPS) |
| `SOCKS_USER` | _(empty)_ | Proxy authentication username, empty = no auth |
| `SOCKS_PASS` | _(empty)_ | Proxy authentication password, requires `SOCKS_USER` |
| `LOG_LEVEL` | `error` | vproxy log level: `trace`, `debug`, `info`, `warn`, `error` |
| `ENABLE_IPV6` | `1` | Enable IPv6 routing and IPv6 egress, `0` to disable |
| `MTU` | `1280` | WireGuard interface MTU |
| `ENDPOINT_IP` | _(empty)_ | Manually pin a WARP Endpoint (e.g. `162.159.192.1:4500`) |
| `ENDPOINT_AUTO` | `1` | `0` disables Endpoint auto-selection |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | CIDR whose return route is restored (e.g. Tailscale) |
| `WARP_PROXY` | _(empty)_ | HTTP(S) proxy for the native registration API |
| `GH_PROXY` | _(empty)_ | GitHub proxy prefix for downloading `wgcf` |
| `MICROWARP_TEST_MODE` | `0` | `1` skips all initialization logic (for CI/debugging) |

> For the complete variable reference (including Endpoint auto-selection tuning and registration flows), see [README-hub.md](README-hub.md).

### IPv6 Dual-stack

IPv6 support is enabled by default. The container will preserve the IPv6 address generated by WARP, route both `0.0.0.0/0` and `::/0` through WireGuard, and listen on `::` for dual-stack proxy access.

Recommended Docker Compose settings:

```yaml
ports:
  - "127.0.0.1:1080:1080"
  - "[::1]:1080:1080"
environment:
  - BIND_ADDR=::
  - ENABLE_IPV6=1
sysctls:
  - net.ipv4.conf.all.src_valid_mark=1
  - net.ipv6.conf.all.forwarding=1
  - net.ipv6.conf.default.forwarding=1
```

If your Docker daemon or host network does not support IPv6, disable IPv6 routing explicitly:

```yaml
environment:
  - ENABLE_IPV6=0
  - BIND_ADDR=0.0.0.0
```

### Persistent Storage

To persist your WARP account data (recommended for WARP+ users):

```yaml
volumes:
  - ./warp-data:/etc/wireguard
```

**Important:** Each WARP+ license supports only 4 devices. Persisting data prevents unnecessary re-registration.

---

## Verification

### Test WARP Connection

Verify that WARP is active and working:

```bash
curl -x socks5h://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

Verify IPv6 egress:

```bash
curl -6 -x socks5h://[::1]:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep -E 'warp|ip='
```

**Expected output:**
```
warp=on
```

or for WARP+ users:
```
warp=plus
```

The proxy also speaks plain HTTP on the same port (vproxy auto-detection):

```bash
curl -x http://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

---

## Additional Resources

- [README-hub.md](README-hub.md) — full Docker Hub documentation
- [Cloudflare WARP Documentation](https://developers.cloudflare.com/warp-client/)
- [Docker Hub Repository](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
- [GitHub Issues](https://github.com/zhengxiongzhao/docker-warp-proxy/issues)

---

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.