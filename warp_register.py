#!/usr/bin/env python3
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


API_BASE = "https://api.cloudflareclient.com/v0a2158/reg"
CLIENT_VERSION = "a-7.21-0721"

# 代理兜底：优先 --proxy 参数，其次 WARP_PROXY 环境变量。
# 标准 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 由 urllib 默认行为自动生效。
PROXY = os.environ.get("WARP_PROXY", "")


class RegistrationError(RuntimeError):
    pass


def log(message):
    print(f"==> [WARP-REGISTER] {message}", flush=True)


def build_opener(proxy):
    """根据代理配置构造 urllib opener。

    - proxy 为空：返回 None，走 urllib 默认行为（自动读取 HTTP_PROXY 等环境变量）。
    - proxy 为 http/https：返回带 ProxyHandler 的 opener。
    - proxy 为 socks/socks5：抛错，因为 urllib 不原生支持 socks。
    """
    if not proxy:
        return None
    if not proxy.lower().startswith(("http://", "https://")):
        raise RegistrationError(
            "unsupported proxy scheme, only http:// and https:// are supported: "
            f"{proxy}"
        )
    log(f"using proxy: {proxy}")
    handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    return urllib.request.build_opener(handler)


def request_json(url, method="GET", payload=None, token=None, proxy=None):
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("CF-Client-Version", CLIENT_VERSION)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")

    opener = build_opener(proxy)
    try:
        if opener is not None:
            with opener.open(request, timeout=10) as response:
                return json.loads(response.read())
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RegistrationError(str(error)) from error


def generate_wireguard_key():
    private = subprocess.run(
        ["wg", "genkey"], check=True, capture_output=True, text=True
    ).stdout.strip()
    public = subprocess.run(
        ["wg", "pubkey"], input=private, check=True, capture_output=True, text=True
    ).stdout.strip()
    return private, public


def get_reserved(client_id):
    try:
        return list(base64.b64decode(client_id, validate=True))
    except (ValueError, TypeError) as error:
        raise RegistrationError(f"invalid client_id: {client_id!r}") from error


def require_string(value, name):
    if not isinstance(value, str) or not value:
        raise RegistrationError(f"missing {name} in Cloudflare response")
    return value


def extract_warp_config(registration, details):
    config = details.get("config")
    interface = config.get("interface") if isinstance(config, dict) else None
    addresses = interface.get("addresses") if isinstance(interface, dict) else None
    peers = config.get("peers") if isinstance(config, dict) else None
    peer = peers[0] if isinstance(peers, list) and peers else None
    peer_endpoint = peer.get("endpoint") if isinstance(peer, dict) else None

    try:
        ipv4 = require_string(addresses["v4"], "IPv4 address")
        ipv6 = require_string(addresses["v6"], "IPv6 address")
        endpoint = require_string(peer_endpoint["host"], "peer endpoint")
        peer_public_key = require_string(peer["public_key"], "peer public key")
        reserved = get_reserved(config["client_id"])
    except (TypeError, KeyError) as error:
        raise RegistrationError(f"incomplete Cloudflare response: {error}") from error

    return ipv4, ipv6, endpoint, peer_public_key, reserved


def build_wg_conf(private_key, ipv4, ipv6, endpoint, peer_public_key, reserved):
    reserved_text = ", ".join(str(value) for value in reserved)
    return (
        "[Interface]\n"
        f"PrivateKey = {private_key}\n"
        f"Address = {ipv4}/32, {ipv6}/128\n"
        "ListenPort = 0\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {peer_public_key}\n"
        f"Endpoint = {endpoint}\n"
        "AllowedIPs = 0.0.0.0/0, ::/0\n"
        f"# Reserved = {reserved_text} (unsupported by wg-quick)\n"
    )


def register_once(output, private_key, public_key, proxy=None):
    tos = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    registration = request_json(
        API_BASE,
        method="POST",
        payload={
            "key": public_key,
            "tos": tos,
            "type": "PC",
            "model": "warp-register",
            "name": os.uname().nodename,
        },
        proxy=proxy,
    )

    try:
        device_id = require_string(registration["id"], "device id")
        token = require_string(registration["token"], "access token")
        license_key = require_string(
            registration["account"]["license"], "license key"
        )
    except (TypeError, KeyError) as error:
        raise RegistrationError(f"incomplete registration response: {error}") from error

    details = request_json(f"{API_BASE}/{device_id}", token=token, proxy=proxy)
    ipv4, ipv6, endpoint, peer_public_key, reserved = extract_warp_config(
        registration, details
    )
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.write_text(
        build_wg_conf(private_key, ipv4, ipv6, endpoint, peer_public_key, reserved)
    )
    temporary.replace(output)
    log(
        "registration succeeded; "
        f"device_id={device_id}, license_key={'present' if license_key else 'missing'}"
    )


def register(output, retries=3, retry_delay=5, proxy=None):
    if output.exists():
        raise RegistrationError(f"output already exists: {output}")

    for attempt in range(1, retries + 1):
        try:
            private_key, public_key = generate_wireguard_key()
            log(f"registering WARP device ({attempt}/{retries})...")
            register_once(output, private_key, public_key, proxy=proxy)
            return
        except (RegistrationError, subprocess.SubprocessError) as error:
            log(f"attempt {attempt} failed: {error}")
            if attempt < retries and retry_delay:
                time.sleep(retry_delay)

    raise RegistrationError(f"WARP registration failed after {retries} attempts")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--retry-delay", type=int, default=5)
    parser.add_argument(
        "--proxy",
        default=PROXY,
        help=(
            "HTTP(S) 代理地址，如 http://127.0.0.1:1080；"
            "默认取 WARP_PROXY 环境变量；空则使用系统 HTTP_PROXY/HTTPS_PROXY"
        ),
    )
    return parser.parse_args()


def main():
    args = parse_args()
    try:
        register(args.output, args.retries, args.retry_delay, proxy=args.proxy)
    except RegistrationError as error:
        log(str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
