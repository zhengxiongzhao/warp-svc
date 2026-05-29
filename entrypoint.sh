#!/bin/sh
set -e

# ==========================================
# 工具函数
# ==========================================
github_auth_header() {
    GITHUB_API_TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}
    if [ -n "$GITHUB_API_TOKEN" ]; then
        echo "Authorization: Bearer $GITHUB_API_TOKEN"
    fi
}

build_wgcf_download_url() {
    WGCF_VER=$1
    WGCF_ARCH=$2
    RAW_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"
    if [ -n "${GH_PROXY:-}" ]; then
        echo "${GH_PROXY%/}/${RAW_URL}"
    else
        echo "$RAW_URL"
    fi
}

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

WG_CONF="/etc/wireguard/wg0.conf"
mkdir -p /etc/wireguard

# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac

    GITHUB_AUTH_HEADER=$(github_auth_header)
    if [ -n "$GITHUB_AUTH_HEADER" ]; then
        WGCF_VER=$(curl -sL -H "$GITHUB_AUTH_HEADER" "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    else
        WGCF_VER=$(curl -sL "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    fi
    echo "==> [MicroWARP] 检测到最新 wgcf 版本: v${WGCF_VER}"
    wget --timeout=15 -qO wgcf "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")"
    chmod +x wgcf

    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    ./wgcf register --accept-tos > /dev/null

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null

    mv wgcf-profile.conf "$WG_CONF"

    # 阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
else
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 2. 配置清洗与参数注入
# ==========================================

# 提取纯 IPv4 地址
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

# 清除旧配置
sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"
sed -i '/^[Mm][Tt][Uu].*/d' "$WG_CONF"

# 注入新配置
if [ -n "$IPV4_ADDR" ]; then
    sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
fi

WG_MTU=${MTU:-1280}
sed -i "/\[Interface\]/a MTU = $WG_MTU" "$WG_CONF"
echo "==> [MicroWARP] MTU 值已设置为: $WG_MTU"

sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"

# 删除 Alpine 系统自带 wg-quick 中不兼容的路由标记
sed -i '/src_valid_mark/d' /usr/bin/wg-quick

# 强制注入 15 秒 UDP 心跳保活
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

# ==========================================
# 3. Endpoint 自动优选 & 启动 wg0
# ==========================================

# 默认候选 IP：WARP 核心段 + Cloudflare Anycast 抽样
DEFAULT_ENDPOINT_IPS="162.159.192.1 162.159.193.1 162.159.193.5 162.159.194.1 162.159.195.1 162.159.196.1 162.159.197.1 104.16.0.1 104.24.0.1 172.64.0.1 162.158.0.1"
# 默认候选端口：WARP 核心端口 + WireGuard 兼容端口
DEFAULT_ENDPOINT_PORTS="2408 500 4500 1701 4443 8443 51820"

# 环境变量覆盖
ENDPOINT_IPS="${ENDPOINT_IPS:-$DEFAULT_ENDPOINT_IPS}"
ENDPOINT_PORTS="${ENDPOINT_PORTS:-$DEFAULT_ENDPOINT_PORTS}"
ENDPOINT_TEST_TIMEOUT="${ENDPOINT_TEST_TIMEOUT:-8}"
ENDPOINT_AUTO="${ENDPOINT_AUTO:-1}"

# 设置 wg0.conf 的 Endpoint
set_wg_endpoint() {
    local ip="$1"
    local port="$2"
    sed -i "s/^Endpoint.*/Endpoint = ${ip}:${port}/g" "$WG_CONF"
}

# 检查 wg0 是否已有握手或接收字节
wg_has_handshake() {
    local latest
    latest=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -n 1)
    if [ -n "$latest" ] && [ "$latest" != "0" ] && [ "$latest" != "" ]; then
        return 0
    fi
    # 备选：检查 transfer 接收字节
    local rx
    rx=$(wg show wg0 transfer 2>/dev/null | awk '{print $3}' | head -n 1)
    if [ -n "$rx" ] && [ "$rx" != "0" ] && [ "$rx" != "" ]; then
        return 0
    fi
    return 1
}

# 尝试单个 Endpoint，成功返回 0，失败返回 1
try_wg_endpoint() {
    local ip="$1"
    local port="$2"
    echo "==> [MicroWARP] 测试 Endpoint: ${ip}:${port} ..."
    set_wg_endpoint "$ip" "$port"

    # 启动 wg0
    wg-quick up wg0 > /dev/null 2>&1 || return 1

    # 等待握手
    local waited=0
    while [ "$waited" -lt "$ENDPOINT_TEST_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
        if wg_has_handshake; then
            echo "==> [MicroWARP] ✅ Endpoint ${ip}:${port} 握手成功 (耗时 ${waited}s)"
            return 0
        fi
    done

    # 超时，关闭 wg0
    wg-quick down wg0 > /dev/null 2>&1 || true
    echo "==> [MicroWARP] ❌ Endpoint ${ip}:${port} 超时，尝试下一个..."
    return 1
}

# 构建候选列表并自动选择
select_and_start_warp_endpoint() {
    # 如果用户手动指定了 ENDPOINT_IP，则直接使用，跳过自动优选
    if [ -n "$ENDPOINT_IP" ]; then
        echo "==> [MicroWARP] 检测到手动指定 ENDPOINT_IP: $ENDPOINT_IP，跳过自动优选"
        set_wg_endpoint "$(echo "$ENDPOINT_IP" | cut -d: -f1)" "$(echo "$ENDPOINT_IP" | cut -d: -f2)"
        echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
        wg-quick up wg0 > /dev/null 2>&1
        return 0
    fi

    # 如果关闭自动优选，使用 wgcf 生成的默认 Endpoint
    if [ "$ENDPOINT_AUTO" != "1" ]; then
        echo "==> [MicroWARP] 自动优选已关闭 (ENDPOINT_AUTO=0)，使用 wgcf 默认 Endpoint"
        echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
        wg-quick up wg0 > /dev/null 2>&1
        return 0
    fi

    echo "==> [MicroWARP] 开始自动优选 Cloudflare WARP Endpoint..."

    # 构建候选列表
    for ip in $ENDPOINT_IPS; do
        for port in $ENDPOINT_PORTS; do
            if try_wg_endpoint "$ip" "$port"; then
                return 0
            fi
        done
    done

    # 所有候选均失败
    echo "==> [ERROR] 所有候选 Endpoint 均不可达，请检查网络或防火墙设置"
    echo "==> [ERROR] 容器将退出，Docker 会自动重启重试"
    return 1
}

# 执行 Endpoint 选择并启动 wg0
select_and_start_warp_endpoint

# ==========================================
# 4. 修复非对称路由
# ==========================================

# 记录原始回程路径
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

# 记录当前容器主网卡 IP 和网关
ORIG_GW=$(ip -4 route show default | awk '{print $3}' | head -n 1)
ORIG_DEV=$(ip -4 route show default | awk '{print $5}' | head -n 1)
if [ -n "$ORIG_DEV" ]; then
    ORIG_IP=$(ip -4 addr show dev "$ORIG_DEV" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
fi

# 注入源地址策略路由修复非对称路由
if [ -n "$ORIG_IP" ] && [ -n "$ORIG_GW" ] && [ -n "$ORIG_DEV" ]; then
    echo "==> [MicroWARP] 正在注入策略路由修复非对称路由 (源IP: $ORIG_IP)..."
    ip rule add from "$ORIG_IP" table 128 priority 100 2>/dev/null || true
    ip route add table 128 default via "$ORIG_GW" dev "$ORIG_DEV" 2>/dev/null || true
fi

# 恢复 Tailscale 等内网网段的回程路由
TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
    fi
fi

echo "==> [MicroWARP] 当前出口 IP 已成功变更为："
curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep ip= || echo "⚠️ 获取超时 (可能是底层握手延迟或节点被强阻断)"

# ==========================================
# 5. 启动 SOCKS5 代理服务
# ==========================================
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==> [MicroWARP] 身份认证已开启 (User: $SOCKS_USER)"
    echo "==> [MicroWARP] MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    echo "==> [MicroWARP] 未设置密码，当前为公开访问模式"
    echo "==> [MicroWARP] MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
