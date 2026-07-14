#!/usr/bin/env bash
#
# generate-warp-config.sh
# 自动下载 wgcf、注册 WARP 设备、生成 wg0.conf 配置文件
# 用法: curl -Lso- zxzhao.com/t/warp_register.sh | bash
#   或: bash generate-warp-config.sh
#
set -euo pipefail

# ==========================================
# 颜色输出
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ==========================================
# 检测操作系统
# ==========================================
detect_os() {
    local os
    os=$(uname -s)
    case "$os" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)
            error "不支持的操作系统: $os"
            exit 1
            ;;
    esac
}

# ==========================================
# 检测 CPU 架构
# ==========================================
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)
            error "不支持的 CPU 架构: $arch"
            exit 1
            ;;
    esac
}

# ==========================================
# 获取 wgcf 最新版本号
# ==========================================
get_latest_version() {
    local version
    local default_version="2.2.31"
    version=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    if [ -z "$version" ]; then
        warn "无法获取 wgcf 最新版本号，使用默认版本: v${default_version}"
        echo "$default_version"
    else
        echo "$version"
    fi
}

# ==========================================
# 构建下载 URL
# ==========================================
build_download_url() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local raw_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_${os}_${arch}"
    
    # 支持 GitHub 代理加速
    if [ -n "${GH_PROXY:-}" ]; then
        echo "${GH_PROXY%/}/${raw_url}"
    else
        echo "$raw_url"
    fi
}

# ==========================================
# 下载 wgcf（带重试和代理回退）
# ==========================================
download_wgcf() {
    local url="$1"
    local gh_proxy_fallback="https://gh-proxy.com/${url}"
    
    info "尝试直接下载..."
    if curl -LsSo wgcf --connect-timeout 15 --max-time 60 "$url"; then
        return 0
    fi
    
    warn "直接下载失败，尝试使用 gh-proxy.com 代理..."
    if curl -LsSo wgcf --connect-timeout 15 --max-time 120 "$gh_proxy_fallback"; then
        return 0
    fi
    
    return 1
}

# ==========================================
# 主流程
# ==========================================
main() {
    info "=========================================="
    info "Cloudflare WARP 配置生成工具"
    info "=========================================="
    echo ""
    
    # 检测环境
    local os arch
    os=$(detect_os)
    arch=$(detect_arch)
    info "检测到系统: ${os}/${arch}"
    
    # 获取最新版本
    info "正在获取 wgcf 最新版本..."
    local version
    version=$(get_latest_version)
    info "wgcf 最新版本: v${version}"
    
    # 构建下载 URL
    local download_url
    download_url=$(build_download_url "$version" "$os" "$arch")
    info "下载地址: ${download_url}"
    
    # 下载 wgcf（带重试和代理回退）
    info "正在下载 wgcf..."
    if ! download_wgcf "$download_url"; then
        error "下载失败（直连和代理均失败），请检查网络连接"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x wgcf
    info "wgcf 下载完成"
    
    # 注册设备
    info "正在向 Cloudflare 注册 WARP 设备..."
    if ! ./wgcf register --accept-tos; then
        error "注册失败，可能是 IP 被 Cloudflare 限流"
        error "请稍后重试，或在其他网络环境下执行此脚本"
        rm -f wgcf
        exit 1
    fi
    info "注册成功"
    
    # 生成配置
    info "正在生成 WireGuard 配置文件..."
    if ! ./wgcf generate; then
        error "配置生成失败"
        rm -f wgcf wgcf-account.toml
        exit 1
    fi
    
    # 检查生成文件
    if [ ! -f "wgcf-profile.conf" ]; then
        error "未找到 wgcf-profile.conf，生成可能失败"
        rm -f wgcf wgcf-account.toml
        exit 1
    fi
    
    # 重命名为 wg0.conf
    mv wgcf-profile.conf wg0.conf
    info "配置文件已生成: wg0.conf"
    
    # 清理临时文件
    rm -f wgcf wgcf-account.toml
    info "临时文件已清理"
    
    # 输出后续步骤
    echo ""
    info "=========================================="
    info "✅ 配置生成成功！"
    info "=========================================="
    echo ""
    echo "后续步骤："
    echo ""
    echo "  1. 将 wg0.conf 上传到 VPS 的 ./warp-data 目录："
    echo "     scp wg0.conf user@your-vps:/path/to/warp-data/wg0.conf"
    echo ""
    echo "  2. 确保 docker-compose.yml 中已启用 volume 挂载："
    echo "     volumes:"
    echo "       - ./warp-data:/etc/wireguard"
    echo ""
    echo "  3. 重启容器："
    echo "     docker-compose restart"
    echo ""
    echo "  4. 验证 WARP 是否正常工作："
    echo "     curl -x socks5h://127.0.0.1:1080 -sL https://cloudflare.com/cdn-cgi/trace | grep warp"
    echo ""
    info "当前目录已生成: $(pwd)/wg0.conf"
}

main "$@"
