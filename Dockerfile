# ==========================================
# 极净运行环境（vproxy 直接使用官方 Release 预编译二进制）
# ==========================================
# vproxy 源码: https://github.com/zhengxiongzhao/vproxy/tree/master
# Release 资产: vproxy-<version>-<target>.tar.gz (+ .sha256)
#   amd64 -> x86_64-unknown-linux-musl
#   arm64 -> aarch64-unknown-linux-musl
#
# VPROXY_TAG:
#   - 缺省: 自动跟随 zhengxiongzhao/vproxy 的最新 release
#   - 显式指定: --build-arg VPROXY_TAG=v2.5.5-fix.2 可固定/回退版本
# GH_PROXY: 可选 GitHub 下载加速前缀, 如 --build-arg GH_PROXY=https://ghproxy.example/
FROM alpine:latest

ARG TARGETARCH
ARG VPROXY_TAG=
ARG GH_PROXY=

RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl python3 bash gcompat libstdc++

# 下载并校验 vproxy 预编译二进制 (musl 静态链接, 无运行时依赖)
RUN set -eux; \
    if [ -z "$VPROXY_TAG" ]; then \
        VPROXY_TAG="$(wget -qO- "https://api.github.com/repos/zhengxiongzhao/vproxy/releases/latest" | grep -oE '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"; \
    fi; \
    [ -n "$VPROXY_TAG" ] || { echo "ERROR: failed to resolve latest vproxy release tag" >&2; exit 1; }; \
    case "$TARGETARCH" in \
        amd64) VPROXY_TARGET=x86_64-unknown-linux-musl ;; \
        arm64) VPROXY_TARGET=aarch64-unknown-linux-musl ;; \
        *) echo "ERROR: unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    VPROXY_VER="${VPROXY_TAG#v}"; \
    BASE_URL="https://github.com/zhengxiongzhao/vproxy/releases/download/${VPROXY_TAG}/vproxy-${VPROXY_VER}-${VPROXY_TARGET}"; \
    if [ -n "$GH_PROXY" ]; then BASE_URL="${GH_PROXY%/}/${BASE_URL}"; fi; \
    cd /tmp; \
    wget -q "${BASE_URL}.tar.gz"; \
    wget -q "${BASE_URL}.tar.gz.sha256"; \
    sha256sum -c "vproxy-${VPROXY_VER}-${VPROXY_TARGET}.tar.gz.sha256"; \
    tar xzf "vproxy-${VPROXY_VER}-${VPROXY_TARGET}.tar.gz"; \
    mv vproxy /usr/local/bin/vproxy; \
    vproxy --version; \
    cd /; rm -rf /tmp/vproxy*

WORKDIR /app
COPY entrypoint.sh .
COPY warp_register.sh .
COPY warp_register.py /app/warp_register.py
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
