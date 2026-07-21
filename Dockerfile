# ==========================================
# 阶段 1：下载 gost 代理引擎（动态获取最新版本）
# ==========================================
FROM alpine:latest AS builder

RUN apk add --no-cache curl tar

# 支持 GitHub 代理加速（构建期通过 --build-arg GH_PROXY=https://xxx 传入）
ARG GH_PROXY

# 容器内检测架构，与 entrypoint.sh 中 wgcf 架构检测逻辑保持一致
# go-gost release 资源命名为 gost_<ver>_linux_<arch>.tar.gz
RUN set -eux && \
    ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  GOST_ARCH="amd64" ;; \
        aarch64) GOST_ARCH="arm64" ;; \
        *) echo "不支持的架构: $ARCH"; exit 1 ;; \
    esac && \
    # 动态获取最新版本号（与项目 wgcf 下载逻辑风格一致）
    GOST_VER=$(curl -sL "https://api.github.com/repos/go-gost/gost/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/') && \
    [ -n "$GOST_VER" ] || GOST_VER="3.0.0" && \
    echo "==> 下载 gost v${GOST_VER} (linux_${GOST_ARCH})" && \
    RAW_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${GOST_ARCH}.tar.gz" && \
    # 支持 GitHub 代理加速（构建期通过 --build-arg GH_PROXY=xxx 传入）
    DOWNLOAD_URL="${GH_PROXY:+${GH_PROXY%/}/}${RAW_URL}" && \
    curl -fsSL "$DOWNLOAD_URL" | tar -xz -C /tmp gost && \
    chmod +x /tmp/gost

# ==========================================
# 阶段 2：极净运行环境
# ==========================================
FROM alpine:latest

# 仅安装必要的内核级 WireGuard 和网络控制工具
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl

# 打包 gost
COPY --from=builder /tmp/gost /usr/local/bin/gost

WORKDIR /app
COPY entrypoint.sh .
COPY warp_register.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
