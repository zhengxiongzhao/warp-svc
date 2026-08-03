ARG BASE_IMAGE=debian:stable-slim

# ================= Warp 下载阶段 =================
# 隔离 Cloudflare GPG key 和 apt 源配置到独立阶段，最终镜像无需安装 gnupg
FROM ${BASE_IMAGE} AS warp-downloader
ARG WARP_VERSION=2025.10.186.0

RUN set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    # Cloudflare apt 源仅保留最新版，madison 匹配特定版本用于可复现构建；
    # 若指定版本不存在则回退到最新版（与原行为一致）
    WARP_PKG_VER=$(apt-cache madison cloudflare-warp | grep "${WARP_VERSION}" | head -n1 | awk '{print $3}') && \
    if [ -n "$WARP_PKG_VER" ]; then \
        echo "Found cloudflare-warp=${WARP_PKG_VER}, downloading pinned version." && \
        apt-get download cloudflare-warp="${WARP_PKG_VER}"; \
    else \
        echo "Warning: Version ${WARP_VERSION} not found in repo, downloading latest instead." && \
        apt-get download cloudflare-warp; \
    fi && \
    mv cloudflare-warp_*.deb /tmp/cloudflare-warp.deb

# ================= Gost 下载阶段 =================
# --platform=$BUILDPLATFORM: 下载始终在宿主机原生 CPU 上执行，避免 QEMU 模拟拖慢
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS gost-downloader
ARG GOST_VERSION=3.0.0
ARG GH_PROXY
ARG TARGETPLATFORM

RUN set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tar && \
    case "${TARGETPLATFORM}" in \
        "linux/amd64") GOST_ARCH="amd64" ;; \
        "linux/arm64"|"linux/arm/v8") GOST_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}"; exit 1 ;; \
    esac && \
    # Prefer the pinned GOST_VERSION for reproducible builds; fall back to latest
    GOST_VER="${GOST_VERSION}" && \
    if [ -z "$GOST_VER" ]; then \
        GOST_VER=$(curl -sL "https://api.github.com/repos/go-gost/gost/releases/latest" \
            | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/'); \
    fi && \
    [ -n "$GOST_VER" ] || { echo "Failed to determine gost version"; exit 1; } && \
    echo "Downloading gost v${GOST_VER} (linux_${GOST_ARCH})" && \
    RAW_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz" && \
    DOWNLOAD_URL="${GH_PROXY:+${GH_PROXY%/}/}${RAW_URL}" && \
    curl -fsSL "$DOWNLOAD_URL" | tar -xz -C /tmp gost && \
    chmod +x /tmp/gost

# ================= 最终阶段 =================
FROM ${BASE_IMAGE}

ARG WARP_VERSION=2025.10.186.0
ARG GOST_VERSION=3.0.0
ARG COMMIT_SHA

LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

# All runtime-configurable environment variables in a single layer
ENV TZ=Asia/Shanghai \
    WARP_SLEEP=2 \
    WARP_LICENSE= \
    BIND_ADDR=:: \
    BIND_PORT=1080 \
    SOCKS_USER= \
    SOCKS_PASS= \
    LOG_LEVEL=error \
    REGISTER_WHEN_MDM_EXISTS= \
    BETA_FIX_HOST_CONNECTIVITY=1 \
    WARP_ENABLE_NAT= \
    WARP_AUTO_RESTART=1 \
    WARP_MONITOR_INTERVAL=30 \
    WARP_MONITOR_RETRIES=5

# COPY 从前面阶段构建的二进制产物与 deb 包
COPY --from=gost-downloader /tmp/gost /usr/local/bin/gost
COPY --from=warp-downloader /tmp/cloudflare-warp.deb /tmp/cloudflare-warp.deb

# 本地 deb 安装: apt-get 自动解析 warp 的所有依赖（dbus/bubblewrap 等），
# 最终镜像无需引入 gnupg、lsb-release 或 Cloudflare apt 源。
RUN set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl sudo jq ipcalc \
        dbus iproute2 nftables \
        /tmp/cloudflare-warp.deb && \
    rm -f /tmp/cloudflare-warp.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

# Copy scripts after the large RUN layer so that script changes don't
# invalidate the apt/warp/gost installation cache.
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0755 ./scripts /healthcheck

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]
