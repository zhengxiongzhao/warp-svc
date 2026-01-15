# warp-svc

[![Publish Docker image to Docker Hub](https://img.shields.io/badge/Publish%20Docker%20image%20to%20Docker%20Hub-latest-g?logo=docker)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)

> **Built with the latest version of `warp-svc`, version: 2025.9.558.0**

> **⚠️ Requirement: International network access is required !**

## Overview

Run Cloudflare WARP client as a SOCKS5 proxy server in Docker.

This Docker image packages the official Cloudflare WARP client for Linux and provides a SOCKS5 proxy server that can be used in:
- Local machine applications
- Other Docker containers via docker-compose

**Why this project?** The official Cloudflare WARP client for Linux only listens on localhost, making it unusable in Docker containers that need to bind to 0.0.0.0. This image solves that problem by using `gost` to forward traffic.

---

## Features

✨ **Automatic Registration** - Register new Cloudflare WARP accounts automatically  
🛡️ **Families Mode** - Configurable DNS filtering (off/malware/full)  
⚡ **WARP+ Support** - Subscribe to Cloudflare WARP+ for unlimited data  
🔄 **Health Monitoring** - Built-in health checks with automatic recovery  
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
      PROXY_PORT: 1080
      FAMILIES_MODE: off
      LOG_LEVEL: error
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
  -e PROXY_PORT=1080 \
  -e FAMILIES_MODE=off \
  -p 1080:1080 \
  zhengxiongzhao/warp-svc:latest
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Asia/Shanghai` | Container timezone |
| `PROXY_PORT` | `1080` | SOCKS5 proxy server port |
| `LOG_LEVEL` | `error` | Logging level: `fatal`, `error`, `warn`, `info`, `debug`, `trace` |
| `FAMILIES_MODE` | `off` | DNS filtering mode:<br/>• `off` - No filtering<br/>• `malware` - Block malware<br/>• `full` - Block malware and adult content |
| `WARP_LICENSE` | _(empty)_ | WARP+ license key for unlimited data |
| `WARP_SLEEP` | `2` | Seconds to wait for warp-svc initialization |

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

## Additional Resources

- [Cloudflare WARP Documentation](https://developers.cloudflare.com/warp-client/)
- [Docker Hub Repository](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
- [GitHub Issues](https://github.com/zhengxiongzhao/docker-warp-proxy/issues)

---

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.
