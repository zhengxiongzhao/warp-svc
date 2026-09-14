# warp-svc

[![Publish Docker image to Docker Hub](https://img.shields.io/badge/Publish%20Docker%20image%20to%20Docker%20Hub-latest-g?logo=docker)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhengxiongzhao/warp-svc)](https://hub.docker.com/r/zhengxiongzhao/warp-svc)

Run Cloudflare WARP via a kernel-level WireGuard tunnel and expose it as a **SOCKS5 / HTTP / HTTPS** proxy in Docker. Supports `amd64` and `arm64`.

---

## Quick Start

```yaml
services:
  cloudflare-warp:
    image: zhengxiongzhao/warp-svc:latest
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
      # - SOCKS_USER=admin                # optional: enable proxy auth
      # - SOCKS_PASS=123456               # requires SOCKS_USER
      # - LOG_LEVEL=error                 # vproxy log level
      # - ENDPOINT_IP=162.159.192.1:4500  # optional: manual WARP Endpoint (port hopping)
      # - WARP_PROXY=http://127.0.0.1:1080  # optional: HTTP(S) proxy for registration API
    volumes:
      - ./warp-data:/etc/wireguard          # persist wg0.conf (WARP account data)
```

```bash
docker compose up -d
```

> **Registration note:** the container tries the **native registration flow** first (up to 3 attempts) via `warp_register.py`. If it fails (commonly caused by datacenter IP rate limiting), it falls back automatically to the `wgcf` registration flow. Generate the config on your local machine and mount it if both fail:

```bash
# On your local machine: download and run the registration helper
curl -Lso- zxzhao.com/t/warp_register.sh | bash

# Upload the generated wg0.conf to your VPS and mount it
# scp wg0.conf user@your-vps:/path/to/project/warp-data/wg0.conf
```

---

## Verify

Verify that WARP is active and working:

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

Verify IPv6 egress:

```bash
curl -6 -x socks5h://[::1]:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep -E 'warp|ip='
```

The proxy speaks SOCKS5, HTTP and HTTPS on the same port (auto-detected by vproxy), so it also works with plain HTTP clients:

```bash
curl -x http://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp
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
| `BIND_ADDR` | `::` | Proxy bind address, `::` for IPv4/IPv6 dual-stack |
| `BIND_PORT` | `1080` | Proxy listen port (auto-detects SOCKS5/HTTP/HTTPS) |
| `SOCKS_USER` | _(empty)_ | Proxy authentication username, empty = no auth |
| `SOCKS_PASS` | _(empty)_ | Proxy authentication password, requires `SOCKS_USER` |
| `LOG_LEVEL` | `error` | vproxy log level: `trace`, `debug`, `info`, `warn`, `error` |
| `ENABLE_IPV6` | `1` | Enable IPv6 routing and IPv6 egress, `0` to disable |
| `MTU` | `1280` | WireGuard interface MTU |
| `ENDPOINT_IP` | _(empty)_ | Manually pin a WARP Endpoint (e.g. `162.159.192.1:4500`), skips auto-selection |
| `ENDPOINT_AUTO` | `1` | `0` disables Endpoint auto-selection and uses the wgcf default |
| `ENDPOINT_IPS` | built-in list | Space-separated candidate WARP Endpoint IPs for auto-selection |
| `ENDPOINT_PORTS` | built-in list | Space-separated candidate WARP Endpoint ports (2408 500 4500 …) |
| `ENDPOINT_TEST_TIMEOUT` | `8` | Seconds to wait for a handshake per Endpoint |
| `ENDPOINT_READY_RETRIES` | `5` | Data-plane readiness retries after a successful handshake |
| `ENDPOINT_READY_INTERVAL` | `3` | Seconds between readiness checks |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | CIDR whose return route is restored (e.g. Tailscale) |
| `WARP_PROXY` | _(empty)_ | HTTP(S) proxy for the native registration API (e.g. `http://127.0.0.1:1080`); socks is not supported |
| `GH_PROXY` | _(empty)_ | GitHub proxy prefix for downloading `wgcf` |
| `GITHUB_TOKEN` / `GH_TOKEN` | _(empty)_ | GitHub API token, avoids rate limits when resolving the latest `wgcf` version |
| `MICROWARP_TEST_MODE` | `0` | `1` skips all initialization logic (for CI/debugging) |

---

## Registration Flows

The container supports **two automatic registration paths**, tried in order:

1. **Native Python registration** ([`warp_register.py`](warp_register.py)) — registers a WARP device directly against `api.cloudflareclient.com`, generates `wg0.conf` locally. Up to 3 attempts.
   - Needs the HTTP(S) proxy for the registration API when the host cannot reach Cloudflare directly — set `WARP_PROXY`.
2. **wgcf registration** — falls back when the native flow fails (3 attempts). Downloads `wgcf` from GitHub Releases (accelerated by `GH_PROXY`) and registers via your current account.

If both fail (most often because the datacenter IP is rate-limited by Cloudflare), generate `wg0.conf` locally and mount it — see [Quick Start](#quick-start).

---

## WARP+ (Unlimited Data)

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

> Each WARP+ license supports up to **4 devices**. Persist the data volume to avoid unnecessary re-registration.

---

## Proxy Authentication

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

## Supported Tags

| Tag | Description |
|-----|-------------|
| `latest` | Latest stable release |
| `<version>` | Pinned version tag (e.g. `v3.0.0`) |

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
- **vproxy**: [zhengxiongzhao/vproxy](https://github.com/zhengxiongzhao/vproxy)
- **Issues**: [Report a bug](https://github.com/zhengxiongzhao/warp-svc/issues)
- **Cloudflare WARP Docs**: [developers.cloudflare.com/warp-client](https://developers.cloudflare.com/warp-client/)

---

## License

Apache License 2.0 — see the LICENSE file for details.