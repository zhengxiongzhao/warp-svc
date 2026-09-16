# warp-svc

[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Image Size](https://img.shields.io/docker/image-size/zhengxiongzhao/warp-svc/latest)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](https://github.com/zhengxiongzhao/warp-svc/blob/master/LICENSE)

Run Cloudflare WARP as a SOCKS5 proxy server in Docker. Supports `amd64` and `arm64`.

---

## Two Variants

This image is available in **two variants**:

| | **Micro** | **Standard** |
|---|---|---|
| Image tag | `zhengxiongzhao/warp-svc:latest-micro` | `zhengxiongzhao/warp-svc:latest` |
| Base image | `alpine:latest` | `debian:stable-slim` |
| WARP implementation | Linux kernel WireGuard + `wgcf` | Official `warp-svc` client |
| Proxy engine | `vproxy` (Rust, single-port SOCKS5/HTTP/HTTPS) | `gost` (v3) |
| Image size | **Much smaller** | Larger |
| Config volume | `/etc/wireguard` (`wg0.conf`) | `/var/lib/cloudflare-warp` |
| WARP+ license | via `wgcf` profile | ✅ `WARP_LICENSE` |
| IPv6 dual-stack | ✅ (default on) | ✅ |
| Endpoint fallback selection | ✅ | — |
| Self-healing monitor | — | ✅ |

- **Micro** (`latest-micro`) — a minimal variant using a kernel-level WireGuard tunnel + lightweight `vproxy`, with a much smaller image size and single-port protocol auto-detection. Includes WARP Endpoint fallback selection.
- **Standard** (`latest`) — the full-featured variant built on the official Cloudflare WARP client, with WARP+ license support and built-in self-healing.

---

## Quick Start

### Micro (`latest-micro`)

```yaml
services:
  cloudflare-warp:
    image: zhengxiongzhao/warp-svc:latest-micro
    container_name: cloudflare-warp
    restart: always
    ports:
      - "1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
    environment:
      - TZ=Asia/Shanghai
      # - BIND_ADDR=::
      # - BIND_PORT=1080
      # - ENABLE_IPV6=1
      # - SOCKS_USER=admin                # optional: enable SOCKS5 auth
      # - SOCKS_PASS=123456               # requires SOCKS_USER
      # - ENDPOINT_IP=162.159.192.1:4500  # optional: manual WARP Endpoint (port hopping)
    volumes:
      - ./warp-data:/etc/wireguard          # persist wg0.conf (WARP account data)
```

```bash
docker compose up -d
```

> **Micro registration note:** the container auto-registers a new WARP device and generates `wg0.conf` on first start. If the auto-registration fails (commonly caused by datacenter IP rate limiting), generate the config on your local machine and mount it:

```bash
# On your local machine: download and run the registration helper
curl -Lso- zxzhao.com/t/warp_register.sh | bash

# Upload the generated wg0.conf to your VPS and mount it
# scp wg0.conf user@your-vps:/path/to/project/warp-data/wg0.conf
```

---

### Standard (`latest`)

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

For the Micro variant, you can also verify IPv6 egress:

```bash
curl -6 -x socks5h://[::1]:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep -E 'warp|ip='
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

### Micro (`latest-micro`)

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Asia/Shanghai` | Container timezone |
| `BIND_ADDR` | `::` | SOCKS5 bind address, `::` for IPv4/IPv6 dual-stack |
| `BIND_PORT` | `1080` | SOCKS5 listen port |
| `SOCKS_USER` | _(empty)_ | SOCKS5 authentication username, empty = no auth |
| `SOCKS_PASS` | _(empty)_ | SOCKS5 authentication password, requires `SOCKS_USER` |
| `ENABLE_IPV6` | `1` | Enable IPv6 routing and IPv6 egress, `0` to disable |
| `LOG_LEVEL` | `error` | `vproxy` log level: `trace`, `debug`, `info`, `warn`, `error` |
| `ENDPOINT_IP` | _(empty)_ | Manually pin a WARP Endpoint (e.g. `162.159.192.1:4500`), skips fallback selection |
| `ENDPOINT_AUTO` | `1` | `0` disables Endpoint fallback selection and uses the configured Endpoint |
| `ENDPOINT_TEST_TIMEOUT` | `8` | Seconds to wait for a handshake per Endpoint |
| `ENDPOINT_READY_RETRIES` | `5` | Data-plane readiness retries after a successful handshake |
| `ENDPOINT_READY_INTERVAL` | `3` | Seconds between readiness checks |
| `COOLDOWN_SECONDS` | `86400` | Cooldown (seconds) before retrying the full Endpoint chain after the direct `engage.cloudflareclient.com:2408` Endpoint and the top-10 preferred Endpoints all fail. Set `0` to retry immediately |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | CIDR whose return route is restored (e.g. Tailscale) |
| `WARP_PROXY` | _(empty)_ | HTTP(S) proxy used only by the native Cloudflare registration API. Must use the `http://` or `https://` scheme. This proxy is used only when a new configuration is generated; it is ignored when an existing `wg0.conf` is already present |
| `GH_PROXY` | _(empty)_ | GitHub proxy prefix for downloading `wgcf` |

#### `WARP_PROXY` Details

Use `WARP_PROXY` when direct access to `api.cloudflareclient.com` is unavailable or restricted during first-time registration:

```yaml
environment:
  - WARP_PROXY=http://192.168.1.10:8080
```

- Valid formats: `http://host:port`, `http://user:pass@host:port`, `https://host:port`, or `https://user:pass@host:port`.
- The proxy applies only to the native Cloudflare registration API. It does not affect WireGuard Endpoint connection testing, endpoint fallback selection, runtime proxy traffic, or WARP data forwarding.
- The registration process retries by default and respects the proxy for every registration request in that run.
- If `WARP_PROXY` is empty, Python's standard `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` environment variables may still be honored by `urllib`.
- Socks proxies (`socks://`, `socks5://`, or `socks5h://`) are not supported for this variable; convert the upstream service to an HTTP(S) proxy first.
- If `/etc/wireguard/wg0.conf` already exists, registration is skipped and `WARP_PROXY` has no effect.

### Standard (`latest`)

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

### Micro (`latest-micro`)

Generate a WARP+ profile locally with `wgcf` and mount it as `wg0.conf`:

```bash
# Register a device and obtain a WARP+ license first (see your wgcf docs),
# then generate the profile and upload it:
curl -Lso- zxzhao.com/t/warp_register.sh | bash
scp wg0.conf user@your-vps:/path/to/project/warp-data/wg0.conf
```

```yaml
volumes:
  - ./warp-data:/etc/wireguard   # contains wg0.conf
```

### Standard (`latest`)

Set your WARP+ license key to unlock unlimited data:

```yaml
environment:
  - WARP_LICENSE=your-license-key
```

> Each WARP+ license supports up to **4 devices**. Persist the data volume (`./data:/var/lib/cloudflare-warp`) to avoid unnecessary re-registration.

---

## SOCKS5 Authentication

Both variants support username/password protection:

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

> Standard (`latest`) only — the Micro variant does not include the self-healing monitor.

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
| `latest` | Latest stable release (Standard variant) |
| `latest-micro` | Latest Micro variant release |
| `slim-latest` | Standard variant on `debian:bookworm-slim` base |
| `slim-<warp>-<gost>` | Pinned slim variant (warp + gost version) |
| `<warp>-<gost>` | Pinned Standard variant (warp + gost version) |
| `v3.0.0` | Pinned version tag |

---

## Supported Architectures

Both variants support the following architectures:

| Architecture | Tag |
|--------------|-----|
| `linux/amd64` | `latest`, `latest-micro`, version tags |
| `linux/arm64` | `latest`, `latest-micro`, version tags |

---

## Links

- **GitHub**: [zhengxiongzhao/warp-svc](https://github.com/zhengxiongzhao/warp-svc)
- **Docker Hub**: [zhengxiongzhao/warp-svc](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
- **vproxy**: [zhengxiongzhao/vproxy](https://github.com/zhengxiongzhao/vproxy)
- **Issues**: [Report a bug](https://github.com/zhengxiongzhao/warp-svc/issues)
- **Cloudflare WARP Docs**: [developers.cloudflare.com/warp-client](https://developers.cloudflare.com/warp-client/)

---

## License

Apache License 2.0 — see [LICENSE](https://github.com/zhengxiongzhao/warp-svc/blob/master/LICENSE).
