ARG BASE_IMAGE=debian:stable-slim

FROM ${BASE_IMAGE}

ARG WARP_VERSION=2025.10.186.0
ARG GOST_VERSION=2.12.0
ARG TARGETPLATFORM
ARG COMMIT_SHA

LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

ENV PROXY_PORT=1080 \
    TZ=Asia/Shanghai \
    LOG_LEVEL=error \
    WARP_SLEEP=5 \
    FAMILIES_MODE=off \
    WARP_LICENSE=

COPY entrypoint.sh /entrypoint.sh
COPY ./scripts /healthcheck

# install dependencies
RUN case ${TARGETPLATFORM} in \
      "linux/amd64")   export ARCH="amd64" ;; \
      "linux/arm64")   export ARCH="armv8" ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    echo "Building for ${TARGETPLATFORM} with GOST ${GOST_VERSION}" &&\
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y curl gnupg lsb-release sudo jq ipcalc procps && \
    curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y cloudflare-warp && \
    apt-get clean && \
    apt-get autoremove -y && \
    MAJOR_VERSION=$(echo ${GOST_VERSION} | cut -d. -f1) && \
    MINOR_VERSION=$(echo ${GOST_VERSION} | cut -d. -f2) && \
    # detect if version >= 2.12.0, which uses new filename syntax
    if [ "${MAJOR_VERSION}" -ge 3 ] || [ "${MAJOR_VERSION}" -eq 2 -a "${MINOR_VERSION}" -ge 12 ]; then \
      NAME_SYNTAX="new" && \
      if [ "${TARGETPLATFORM}" = "linux/arm64" ]; then \
        ARCH="arm64"; \
      fi && \
      FILE_NAME="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"; \
    else \
      NAME_SYNTAX="legacy" && \
      FILE_NAME="gost-linux-${ARCH}-${GOST_VERSION}.gz"; \
    fi && \
    echo "File name: ${FILE_NAME}" && \
    curl -LO https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/${FILE_NAME} && \
    if [ "${NAME_SYNTAX}" = "new" ]; then \
      tar -xzf ${FILE_NAME} -C /usr/bin/ gost; \
    else \
      gunzip ${FILE_NAME} && \
      mv gost-linux-${ARCH}-${GOST_VERSION} /usr/bin/gost; \
    fi && \
    chmod +x /usr/bin/gost && \
    chmod +x /entrypoint.sh && \
    chmod +x /healthcheck/index.sh && \
    chmod +x /healthcheck/monitor-warp.sh && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV REGISTER_WHEN_MDM_EXISTS=
ENV BETA_FIX_HOST_CONNECTIVITY=
ENV WARP_ENABLE_NAT=
ENV ENABLE_MONITOR=
ENV MONITOR_INTERVAL=
ENV MAX_RETRIES=
ENV RETRY_DELAY=
ENV RECONNECT_WAIT=
ENV RESTART_WAIT=

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]