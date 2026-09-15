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

# 将 warp_register.sh 复制到 /etc/wireguard，方便用户在本地生成配置
cp -f /app/warp_register.sh /etc/wireguard/warp_register.sh

# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    echo "==> [MicroWARP] 优先使用原生注册流程..."
    if python3 /app/warp_register.py "$WG_CONF" --retries 3; then
        echo "==> [MicroWARP] 原生注册流程成功！"
    else
        echo "==> [MicroWARP] 原生注册流程 3 次失败，回退到 wgcf 注册流程..."
    fi
fi

if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 正在使用 wgcf 初始化 Cloudflare WARP..."

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

    # 注册重试逻辑：最多 3 次，指数退避 30s -> 60s
    MAX_REGISTER_RETRIES=3
    register_attempt=0
    register_success=false
    register_delay=30

    while [ "$register_attempt" -lt "$MAX_REGISTER_RETRIES" ]; do
        register_attempt=$((register_attempt + 1))
        echo "==> [MicroWARP] 正在向 CF 注册设备 (${register_attempt}/${MAX_REGISTER_RETRIES})..."

        if ./wgcf register --accept-tos > /dev/null 2>&1; then
            register_success=true
            break
        fi

        if [ "$register_attempt" -lt "$MAX_REGISTER_RETRIES" ]; then
            echo "==> [MicroWARP] 注册失败，${register_delay} 秒后重试..."
            sleep "$register_delay"
            register_delay=$((register_delay * 2))
        fi
    done

    if [ "$register_success" = "false" ]; then
        # 获取当前 VPS 出口 IP
        CURRENT_IP=$(curl -4 -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2 || true)

        echo ""
        echo "==> [ERROR] =========================================="
        echo "==> [ERROR] WARP 设备注册失败（已重试 ${MAX_REGISTER_RETRIES} 次）"
        echo "==> [ERROR] 当前 VPS 出口 IP: ${CURRENT_IP:-未知}"
        echo "==> [ERROR] 该 IP 地址（通常是数据中心/机房 IP 段）向 Cloudflare 接口请求注册 WARP 设备的频率过高"
        echo "==> [ERROR] =========================================="
        echo ""
        echo "==> [解决方案] 请在本地生成 wg0.conf 并挂载到容器后重启："
        echo "   1. 修改 docker-compose.yml 挂载卷: ./warp-data:/etc/wireguard"
        echo "   2. 执行: curl -Lso- zxzhao.com/t/warp_register.sh | bash"
        echo "   3. 将 wg0.conf 上传到 ./warp-data "
        echo ""
        echo "==> [MicroWARP] 容器将在 1 小时后退出，请在此期间完成配置..."
        sleep 3600
        exit 1
    fi

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

# 提取 WARP 分配的 IPv4/IPv6 地址
ADDRESS_LINE=$(grep '^Address' "$WG_CONF" | head -n 1 || true)
IPV4_ADDR=$(printf '%s\n' "$ADDRESS_LINE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1 || true)
IPV6_ADDR=$(printf '%s\n' "$ADDRESS_LINE" | tr ',' '\n' | grep ':' | grep -oE '[0-9A-Fa-f:]+/[0-9]{1,3}' | head -n 1 || true)
ENABLE_IPV6=${ENABLE_IPV6:-1}

# 清除旧配置
sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"
sed -i '/^[Mm][Tt][Uu].*/d' "$WG_CONF"

# 注入新配置
ADDRESS_LIST=""
if [ -n "$IPV4_ADDR" ]; then
    ADDRESS_LIST="$IPV4_ADDR"
fi
if [ "$ENABLE_IPV6" = "1" ] && [ -n "$IPV6_ADDR" ]; then
    if [ -n "$ADDRESS_LIST" ]; then
        ADDRESS_LIST="$ADDRESS_LIST, $IPV6_ADDR"
    else
        ADDRESS_LIST="$IPV6_ADDR"
    fi
fi
if [ -n "$ADDRESS_LIST" ]; then
    sed -i "/\[Interface\]/a Address = $ADDRESS_LIST" "$WG_CONF"
    echo "==> [MicroWARP] WireGuard 地址已设置为: $ADDRESS_LIST"
fi

WG_MTU=${MTU:-1280}
sed -i "/\[Interface\]/a MTU = $WG_MTU" "$WG_CONF"
echo "==> [MicroWARP] MTU 值已设置为: $WG_MTU"

if [ "$ENABLE_IPV6" = "1" ] && [ -n "$IPV6_ADDR" ]; then
    sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0, ::\/0" "$WG_CONF"
    echo "==> [MicroWARP] 已启用 IPv4/IPv6 双栈代理路由"
else
    sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
    echo "==> [MicroWARP] 已启用 IPv4 代理路由"
fi

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
ENDPOINT_READY_RETRIES="${ENDPOINT_READY_RETRIES:-5}"
ENDPOINT_READY_INTERVAL="${ENDPOINT_READY_INTERVAL:-3}"
ENDPOINT_AUTO="${ENDPOINT_AUTO:-1}"

# 格式化 Endpoint，IPv6 地址需要使用 [addr]:port 格式
format_wg_endpoint() {
    local ip="$1"
    local port="$2"
    case "$ip" in
        *:*) echo "[${ip}]:${port}" ;;
        *) echo "${ip}:${port}" ;;
    esac
}

# 设置 wg0.conf 的 Endpoint
set_wg_endpoint() {
    local ip="$1"
    local port="$2"
    local endpoint
    endpoint=$(format_wg_endpoint "$ip" "$port")
    sed -i "s/^Endpoint.*/Endpoint = ${endpoint}/g" "$WG_CONF"
}

# 解析手动指定的 ENDPOINT_IP，支持 IPv4:port、hostname:port 和 [IPv6]:port
parse_manual_endpoint() {
    local endpoint="$1"
    case "$endpoint" in
        \[*\]:*)
            MANUAL_ENDPOINT_HOST=$(printf '%s\n' "$endpoint" | sed 's/^\[\(.*\)\]:[^:]*$/\1/')
            MANUAL_ENDPOINT_PORT=$(printf '%s\n' "$endpoint" | sed 's/^\[.*\]:\([^:]*\)$/\1/')
            ;;
        *)
            MANUAL_ENDPOINT_HOST=$(printf '%s\n' "$endpoint" | sed 's/:\([^:]*\)$/\n\1/' | sed -n '1p')
            MANUAL_ENDPOINT_PORT=$(printf '%s\n' "$endpoint" | sed 's/.*://')
            ;;
    esac
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

# 检查 WARP IPv4 数据面是否可用
warp_ipv4_ready() {
    curl -4 -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep -q '^warp='
}

# 检查 WARP IPv6 数据面是否可用
warp_ipv6_ready() {
    curl -6 -s -m 5 'https://[2606:4700:4700::1111]/cdn-cgi/trace' | grep -q '^warp='
}

# 尝试单个 Endpoint，成功返回 0，失败返回 1
try_wg_endpoint() {
    local ip="$1"
    local port="$2"
    echo "==> [MicroWARP] 测试 Endpoint: ${ip}:${port} ..."
    set_wg_endpoint "$ip" "$port"

    # 启动 wg0
    wg-quick up wg0 > /dev/null 2>&1 || return 1

    # 等待握手。握手只代表 WireGuard 控制面成功，不代表隧道数据面已经可用。
    local waited=0
    while [ "$waited" -lt "$ENDPOINT_TEST_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
        if wg_has_handshake; then
            echo "==> [MicroWARP] Endpoint ${ip}:${port} 握手成功 (耗时 ${waited}s)，继续检测 IPv4 数据面..."
            local ready_attempt=0
            while [ "$ready_attempt" -lt "$ENDPOINT_READY_RETRIES" ]; do
                ready_attempt=$((ready_attempt + 1))
                if warp_ipv4_ready; then
                    echo "==> [MicroWARP] ✅ Endpoint ${ip}:${port} IPv4 数据面可用 (第 ${ready_attempt} 次检测成功)"
                    return 0
                fi
                echo "==> [MicroWARP] Endpoint ${ip}:${port} IPv4 数据面暂不可用，等待 ${ENDPOINT_READY_INTERVAL}s 后重试 (${ready_attempt}/${ENDPOINT_READY_RETRIES})..."
                sleep "$ENDPOINT_READY_INTERVAL"
            done

            wg-quick down wg0 > /dev/null 2>&1 || true
            echo "==> [MicroWARP] ❌ Endpoint ${ip}:${port} 握手成功但 IPv4 数据面不可用，尝试下一个..."
            return 1
        fi
    done

    # 超时，关闭 wg0
    wg-quick down wg0 > /dev/null 2>&1 || true
    echo "==> [MicroWARP] ❌ Endpoint ${ip}:${port} 握手超时，尝试下一个..."
    return 1
}

# 运行 Misaka warp-yxip 优选，成功时导出 YXIP_CANDIDATES（前 10 个 IP:Port）
run_yxip_preference() {
    local workdir="/tmp/warp-yxip"
    rm -rf "$workdir"; mkdir -p "$workdir" || return 1
    cd "$workdir" || return 1

    echo "==> [MicroWARP] 正在下载 Misaka WARP Endpoint 优选脚本..."
    # 用户指定的原始命令；附加 -T 超时与 -q 静默
    if ! wget -N -T 20 -q "https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-yxip/warp-yxip.sh"; then
        echo "==> [MicroWARP] ❌ 优选脚本下载失败"
        cd / || return 1
        return 1
    fi
    chmod +x warp-yxip.sh

    # 脚本菜单在 stdin 为空/EOF 时走默认分支 (IPv4 优选)，无头安全
    echo "==> [MicroWARP] 正在运行 Endpoint 优选测试 (约 1-3 分钟)..."
    if ! bash warp-yxip.sh < /dev/null > yxip.log 2>&1; then
        echo "==> [MicroWARP] ❌ 优选脚本执行失败:"
        tail -5 yxip.log | sed 's/^/    [yxip] /'
        cd / || return 1
        return 1
    fi
    tail -15 yxip.log | sed 's/^/    [yxip] /'

    # result.csv 格式: IP:Port,Loss,Latency (首行为表头)
    if [ ! -s result.csv ]; then
        echo "==> [MicroWARP] ❌ 优选完成但未生成 result.csv"
        cd / || return 1
        return 1
    fi

    YXIP_CANDIDATES=$(tail -n +2 result.csv | grep -E '^[0-9a-fA-F:.]+:[0-9]+,' | head -10 | cut -d, -f1)
    if [ -z "$YXIP_CANDIDATES" ]; then
        echo "==> [MicroWARP] ❌ result.csv 无有效候选"
        cd / || return 1
        return 1
    fi

    echo "==> [MicroWARP] 优选候选 (前 10):"
    printf '%s\n' "$YXIP_CANDIDATES" | sed 's/^/    [yxip]   /'
    cd / || return 1
    return 0
}

# 构建候选列表并自动选择
select_and_start_warp_endpoint() {
    # 如果用户手动指定了 ENDPOINT_IP，则直接使用，跳过自动优选
    if [ -n "$ENDPOINT_IP" ]; then
        echo "==> [MicroWARP] 检测到手动指定 ENDPOINT_IP: $ENDPOINT_IP，跳过自动优选"
        parse_manual_endpoint "$ENDPOINT_IP"
        set_wg_endpoint "$MANUAL_ENDPOINT_HOST" "$MANUAL_ENDPOINT_PORT"
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

    # ===== Tier 1/3: 官方域名 engage.cloudflareclient.com:2408 =====
    echo "==> [MicroWARP] [Tier 1/3] 尝试官方 Endpoint: engage.cloudflareclient.com:2408 ..."
    if try_wg_endpoint "engage.cloudflareclient.com" "2408"; then
        echo "==> [MicroWARP] ✅ [Tier 1/3] 官方 Endpoint 连接成功"
        return 0
    fi
    echo "==> [MicroWARP] ❌ [Tier 1/3] 官方 Endpoint 失败，进入 Tier 2 优选..."

    # ===== Tier 2/3: Misaka warp-yxip 优选前 10 个 IP:Port =====
    if run_yxip_preference; then
        for cand in $YXIP_CANDIDATES; do
            yxip="${cand%%:*}"
            yxport="${cand##*:}"
            echo "==> [MicroWARP] [Tier 2/3] 尝试优选 Endpoint: ${yxip}:${yxport} ..."
            if try_wg_endpoint "$yxip" "$yxport"; then
                echo "==> [MicroWARP] ✅ [Tier 2/3] 优选 Endpoint ${yxip}:${yxport} 连接成功"
                return 0
            fi
        done
        echo "==> [MicroWARP] ❌ [Tier 2/3] 全部优选 Endpoint 失败，进入 Tier 3 冷却..."
    else
        echo "==> [MicroWARP] ❌ [Tier 2/3] 优选脚本未产出可用候选，进入 Tier 3 冷却..."
    fi

    # ===== Tier 3/3: 冷却 24h 后自动重试完整优选链 =====
    echo ""
    echo "==> [ERROR] =========================================="
    echo "==> [ERROR] Tier 1/2 全部失败：官方 Endpoint 与优选 Endpoint 均不可达"
    echo "==> [ERROR] 可能原因: 本机出口 IP 被 Cloudflare 限速/风控，或 UDP 出网受限"
    egress_ip=$(curl -4 -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
    echo "==> [ERROR] 当前出口 IP: ${egress_ip:-未知}"
    echo "==> [ERROR] =========================================="
    COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-86400}
    echo "==> [MicroWARP] [Tier 3/3] 进入冷却期 ${COOLDOWN_SECONDS}s (24h)，期间不向 Cloudflare 发起请求，避免限速恶化"
    echo "==> [MicroWARP] 冷却结束后将自动重试完整优选链 (Tier 1 -> Tier 2 -> Tier 3)"
    sleep "$COOLDOWN_SECONDS"
    echo "==> [MicroWARP] 冷却结束，重新执行完整启动流程..."
    exec /app/entrypoint.sh
}

# 在 WARP 改写默认路由前记录原始回程路径、主网卡 IP 和网关
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

ORIG_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n 1)
ORIG_DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1)
if [ -n "$ORIG_DEV" ]; then
    ORIG_IP=$(ip -4 addr show dev "$ORIG_DEV" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
fi

if [ "$ENABLE_IPV6" = "1" ]; then
    ORIG_GW6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -n 1)
    ORIG_DEV6=$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -n 1)
    if [ -n "$ORIG_DEV6" ]; then
        ORIG_IP6=$(ip -6 addr show dev "$ORIG_DEV6" scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n 1)
    fi
fi

# 执行 Endpoint 选择并启动 wg0
select_and_start_warp_endpoint

# ==========================================
# 4. 修复非对称路由
# ==========================================

# 注入源地址策略路由修复非对称路由
if [ -n "$ORIG_IP" ] && [ -n "$ORIG_GW" ] && [ -n "$ORIG_DEV" ]; then
    echo "==> [MicroWARP] 正在注入 IPv4 策略路由修复非对称路由 (源IP: $ORIG_IP)..."
    ip rule add from "$ORIG_IP" table 128 priority 100 2>/dev/null || true
    ip route add table 128 default via "$ORIG_GW" dev "$ORIG_DEV" 2>/dev/null || true
fi

if [ "$ENABLE_IPV6" = "1" ] && [ -n "$ORIG_IP6" ] && [ -n "$ORIG_GW6" ] && [ -n "$ORIG_DEV6" ]; then
    echo "==> [MicroWARP] 正在注入 IPv6 策略路由修复非对称路由 (源IP: $ORIG_IP6)..."
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.forwarding=1 > /dev/null 2>&1 || true
    ip -6 rule add from "$ORIG_IP6" table 129 priority 110 2>/dev/null || true
    ip -6 route add table 129 default via "$ORIG_GW6" dev "$ORIG_DEV6" 2>/dev/null || true
fi

# 恢复 Tailscale 等内网网段的回程路由
TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
    fi
fi

print_exit_ip_with_retry() {
    local family="$1"
    local url="$2"
    local attempt=0
    local output=""

    while [ "$attempt" -lt "$ENDPOINT_READY_RETRIES" ]; do
        attempt=$((attempt + 1))
        output=$(curl "$family" -s -m 5 "$url" 2>/dev/null || true)
        if printf '%s\n' "$output" | grep -q '^ip='; then
            printf '%s\n' "$output" | grep '^ip='
            return 0
        fi
        echo "==> [MicroWARP] 出口 IP 获取暂不可用，等待 ${ENDPOINT_READY_INTERVAL}s 后重试 (${attempt}/${ENDPOINT_READY_RETRIES})..."
        sleep "$ENDPOINT_READY_INTERVAL"
    done

    return 1
}

echo "==> [MicroWARP] 当前 IPv4 出口 IP 已成功变更为："
print_exit_ip_with_retry -4 https://1.1.1.1/cdn-cgi/trace || echo "⚠️ IPv4 获取超时 (可能是节点数据面尚未就绪或节点被强阻断)"
if [ "$ENABLE_IPV6" = "1" ]; then
    echo "==> [MicroWARP] 当前 IPv6 出口 IP 已成功变更为："
    print_exit_ip_with_retry -6 'https://[2606:4700:4700::1111]/cdn-cgi/trace' || echo "⚠️ IPv6 获取超时 (可能是宿主机/Docker 未启用 IPv6、节点握手延迟或 IPv6 数据面暂不可用)"
fi

# ==========================================
# 5. 启动代理服务 (vproxy)
# ==========================================
LISTEN_ADDR=${BIND_ADDR:-"::"}
LISTEN_PORT=${BIND_PORT:-"1080"}

# 规范化监听地址：vproxy 使用 [::] 表示 IPv6 双栈，microsocks 使用 ::
case "$LISTEN_ADDR" in
    ::) BIND_SOCKET="[::]:${LISTEN_PORT}" ;;
    *)  BIND_SOCKET="${LISTEN_ADDR}:${LISTEN_PORT}" ;;
esac

# vproxy 日志级别通过 VPROXY_LOG 环境变量控制（默认 error，减少 docker logs 噪音）
# 可用值: trace / debug / info / warn / error
export VPROXY_LOG="${VPROXY_LOG:-${LOG_LEVEL:-error}}"

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==> [MicroWARP] 身份认证已开启 (User: $SOCKS_USER)"
    echo "==> [MicroWARP] vproxy 引擎已启动，正在监听 ${BIND_SOCKET} (log: ${VPROXY_LOG})"
    exec vproxy run --bind "$BIND_SOCKET" auto -u "$SOCKS_USER" -p "$SOCKS_PASS"
else
    echo "==> [MicroWARP] 未设置密码，当前为公开访问模式"
    echo "==> [MicroWARP] vproxy 引擎已启动，正在监听 ${BIND_SOCKET} (log: ${VPROXY_LOG})"
    exec vproxy run --bind "$BIND_SOCKET" auto
fi
