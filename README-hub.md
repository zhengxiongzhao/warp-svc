# warp-svc

[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Image Size](https://img.shields.io/docker/image-size/zhengxiongzhao/warp-svc/latest)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](https://github.com/zhengxiongzhao/warp-svc/blob/master/LICENSE)

Run Cloudflare WARP as a SOCKS5 proxy server in Docker. Supports `amd64` and `arm64`.

---
## Features

✨ **Automatic Registration** - Register new Cloudflare WARP accounts automatically

⚡ **WARP+ Support** - Subscribe to Cloudflare WARP+ for unlimited data

🔄 **Health Monitoring** - Built-in health checks with automatic recovery

🔧 **Self-Healing** - Optional auto-restart when WARP tunnel goes down

🐳 **Multi-arch Support** - Works on amd64 and arm64 platforms

## Quick Start

### docker run

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

### docker compose

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
      - TZ=Asia/Shanghai
      - BIND_PORT=1080
      - LOG_LEVEL=error
      # - WARP_LICENSE=your-license-key   # optional: WARP+ unlimited data
      # - SOCKS_USER=admin                # optional: enable SOCKS5 auth
      # - SOCKS_PASS=123456               # requires SOCKS_USER
    volumes:
      - ./data:/var/lib/cloudflare-warp   # persist WARP account data
```

```bash
docker compose up -d
```

---

## Verify

```bash
curl -x socks5h://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

Expected output:

```
warp=on
```

For WARP+ users:

```
warp=plus
```

---

## Host System Setup

Run these commands **on the host** before starting the container:

```bash
# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p

# Load required kernel modules
modprobe nf_conntrack
modprobe tun

# Auto-load on boot
echo -e "nf_conntrack\ntun" > /etc/modules-load.d/custom-modules.conf

# Allow masquerading in firewall (required for RHEL 9)
firewall-cmd --zone=public --add-masquerade --permanent
```

---

## Environment Variables

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
| `WARP_AUTO_RESTART` | `1` | Self-healing: auto-restart when WARP tunnel is down. Set empty to disable |
| `WARP_MONITOR_INTERVAL` | `30` | Self-healing check interval in seconds |
| `WARP_MONITOR_RETRIES` | `5` | Consecutive check failures before triggering restart |
| `WARP_ENABLE_NAT` | _(empty)_ | Enable NAT mode (experimental) |
| `BETA_FIX_HOST_CONNECTIVITY` | _(empty)_ | Enable host-to-container connectivity fix (BETA) |
| `REGISTER_WHEN_MDM_EXISTS` | _(empty)_ | Force re-registration even when `mdm.xml` already exists |

---

## WARP+ (Unlimited Data)

Set your WARP+ license key to unlock unlimited data:

```yaml
environment:
  - WARP_LICENSE=your-license-key
```

> Each WARP+ license supports up to **4 devices**. Persist the data volume (`./data:/var/lib/cloudflare-warp`) to avoid unnecessary re-registration.

---

## SOCKS5 Authentication

Enable username/password protection:

```yaml
environment:
  - SOCKS_USER=admin
  - SOCKS_PASS=your-password
```

Test with auth:

```bash
curl -x socks5h://admin:your-password@127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
```

---

## Self-Healing (Auto-Restart)

Docker's health check only marks the container as `unhealthy` — it does **not** restart it. If the WARP tunnel goes down while the proxy process keeps running, traffic would be routed through your direct connection.

Self-healing is **enabled by default**. A background monitor checks WARP connectivity every `WARP_MONITOR_INTERVAL` seconds. If unreachable for `WARP_MONITOR_RETRIES` consecutive checks, the container terminates and Docker's `restart: always` recreates it.

To disable:

```yaml
environment:
  - WARP_AUTO_RESTART=
```

---

## Supported Tags

| Tag | Description |
|-----|-------------|
| `latest` | Latest stable release |
| `v3.0.0` | Pinned version tag |
| `3.0.0` | Semver without `v` prefix |

---

## Supported Architectures

| Architecture | Tag |
|--------------|-----|
| `linux/amd64` | `latest`, version tags |
| `linux/arm64` | `latest`, version tags |

---

## Links

- **GitHub**: [zhengxiongzhao/warp-svc](https://github.com/zhengxiongzhao/warp-svc)
- **Docker Hub**: [zhengxiongzhao/warp-svc](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
- **Issues**: [Report a bug](https://github.com/zhengxiongzhao/warp-svc/issues)
- **Cloudflare WARP Docs**: [developers.cloudflare.com/warp-client](https://developers.cloudflare.com/warp-client/)

---

## License

Apache License 2.0 — see [LICENSE](https://github.com/zhengxiongzhao/warp-svc/blob/master/LICENSE).
