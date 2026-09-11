# ==========================================
# 阶段 1：下载 vproxy (Rust) 静态二进制
# ==========================================
FROM alpine:latest AS builder
# 安装下载工具
RUN apk add --no-cache curl tar
ARG TARGETARCH
# vproxy (0x676e67/vproxy) 预编译 musl 静态二进制，vproxy run auto 单端口自动识别协议
# Release 地址: https://github.com/0x676e67/vproxy/releases
ARG GH_PROXY=""
RUN case "${TARGETARCH}" in \
        amd64) VPROXY_ARCH="x86_64-unknown-linux-musl" ;; \
        arm64) VPROXY_ARCH="aarch64-unknown-linux-musl" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac && \
    VPROXY_VER="2.5.5" && \
    VPROXY_URL="https://github.com/0x676e67/vproxy/releases/download/v${VPROXY_VER}/vproxy-${VPROXY_VER}-${VPROXY_ARCH}.tar.gz" && \
    if [ -n "${GH_PROXY}" ]; then VPROXY_URL="${GH_PROXY%/}/${VPROXY_URL}"; fi && \
    echo "==> [MicroWARP] Downloading vproxy ${VPROXY_VER} (${VPROXY_ARCH})..." && \
    echo "==> [MicroWARP] URL: ${VPROXY_URL}" && \
    for i in 1 2 3; do \
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/vproxy.tar.gz "$VPROXY_URL" && break || { echo "==> [MicroWARP] 下载失败 (第 ${i}/3 次)，重试..."; sleep 3; }; \
    done && \
    test -s /tmp/vproxy.tar.gz && \
    tar -xzf /tmp/vproxy.tar.gz -C /tmp && \
    find /tmp -name 'vproxy' -type f -exec cp {} /tmp/vproxy-bin \;

# ==========================================
# 阶段 2：极净运行环境
# ==========================================
FROM alpine:latest

# 仅安装必要的内核级 WireGuard 和网络控制工具
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl

# 打包 vproxy
COPY --from=builder /tmp/vproxy-bin /usr/local/bin/vproxy

WORKDIR /app
COPY entrypoint.sh .
COPY warp_register.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]