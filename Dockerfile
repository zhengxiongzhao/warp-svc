ARG BASE_IMAGE=debian:stable-slim

FROM ${BASE_IMAGE}

ARG GOST_VERSION=3.2.6
ARG TARGETPLATFORM
ENV ARCH=${TARGETPLATFORM}

RUN ARCH=$(echo "${TARGETPLATFORM:-linux/amd64}" | sed 's#linux/#linux_#')

ENV DEBIAN_FRONTEND=noninteractive

ENV PROXY_PORT=1080 \
    TZ=Asia/Shanghai \
    LOG_LEVEL=error \
    FAMILIES_MODE=off \
    WARP_LICENSE=


COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 ./scripts /scripts

RUN apt-get update && \
  apt-get install curl wget ca-certificates dbus gpg tzdata gnupg lsb-release sudo jq ipcalc iputils-ping -y && \
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
  apt-get update && \
  apt-get install cloudflare-warp -y --no-install-recommends  && \
  apt-get clean && \
  apt-get autoremove -y && \
  rm -rf /var/lib/apt/lists/*

RUN set -eux; \ 
    ARCH=$(echo "${TARGETPLATFORM:-linux_amd64}" | sed 's#linux/#linux_#') && \ 
    echo "ARCH=$ARCH" && \
    curl -L https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_${ARCH}.tar.gz | \ 
    tar -xOzf - gost > /usr/local/bin/gost && \ 
    chmod +x /usr/local/bin/gost 

RUN useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

USER warp

RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /scripts/healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
