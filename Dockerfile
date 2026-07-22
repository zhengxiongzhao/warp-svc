ARG BASE_IMAGE=debian:stable-slim

FROM ${BASE_IMAGE}

ARG WARP_VERSION=2025.10.186.0
ARG GOST_VERSION=3.0.0
ARG TARGETPLATFORM
ARG COMMIT_SHA
ARG GH_PROXY

LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

ENV TZ=Asia/Shanghai \
    WARP_SLEEP=2 \
    WARP_LICENSE= \
    BIND_ADDR=:: \
    BIND_PORT=1080 \
    SOCKS_USER= \
    SOCKS_PASS= \
    LOG_LEVEL=error

COPY entrypoint.sh /entrypoint.sh
COPY ./scripts /healthcheck

# install dependencies and download gost
# NOTE: WARP apt repo uses "armv8" for arm64, but gost releases use "arm64".
# To avoid the naming mismatch, WARP keeps TARGETPLATFORM while gost uses uname -m.
RUN set -eux && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y curl gnupg lsb-release sudo jq ipcalc && \
    curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y cloudflare-warp && \
    apt-get clean && \
    apt-get autoremove -y && \
    ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  GOST_ARCH="amd64" ;; \
        aarch64) GOST_ARCH="arm64" ;; \
        *) echo "Unsupported ARCH: $ARCH"; exit 1 ;; \
    esac && \
    GOST_VER=$(curl -sL "https://api.github.com/repos/go-gost/gost/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/') && \
    [ -n "$GOST_VER" ] || GOST_VER="${GOST_VERSION:-3.0.0}" && \
    echo "Downloading gost v${GOST_VER} (linux_${GOST_ARCH})" && \
    RAW_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz" && \
    DOWNLOAD_URL="${GH_PROXY:+${GH_PROXY%/}/}${RAW_URL}" && \
    curl -fsSL "$DOWNLOAD_URL" | tar -xz -C /usr/local/bin gost && \
    chmod +x /usr/local/bin/gost && \
    chmod +x /entrypoint.sh && \
    chmod +x /healthcheck/index.sh && \
    chmod +x /healthcheck/warp-monitor.sh && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV REGISTER_WHEN_MDM_EXISTS=
ENV BETA_FIX_HOST_CONNECTIVITY=
ENV WARP_ENABLE_NAT=

# Self-healing: monitor WARP connectivity and restart the container when
# the tunnel is down for too long. Enabled by default.
ENV WARP_AUTO_RESTART=1
ENV WARP_MONITOR_INTERVAL=30
ENV WARP_MONITOR_RETRIES=5

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]