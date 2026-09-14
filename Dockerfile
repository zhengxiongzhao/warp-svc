# ==========================================
# 阶段 1：编译 vproxy (Rust) 静态二进制
# ==========================================
# vproxy 2.5.5 源码地址: https://github.com/zhengxiongzhao/vproxy/tree/master
# (fork 自 0x676e67/vproxy, master 分支, Rust edition 2024, rust-version 1.97)
FROM rust:alpine3.20 AS builder

# Rust 工具链 (alpine 的 rust 镜像已带 rustc/cargo) + musl 静态链接依赖
RUN apk add --no-cache musl-dev git

# 确保 Rust 版本满足 vproxy 的 MSRV (rust-version = "1.97")
RUN rustup toolchain install 1.97.0 --profile minimal && rustup default 1.97.0

# 从 fork 仓库 master 分支克隆源码并编译 (musl 静态二进制)
RUN git clone --depth 1 --branch master https://github.com/zhengxiongzhao/vproxy.git /src && \
    cd /src && cargo build --release

# ==========================================
# 阶段 2：极净运行环境
# ==========================================
FROM alpine:latest

# 仅安装必要的内核级 WireGuard、网络控制工具和 vproxy 运行时依赖
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl python3

# 打包 vproxy
COPY --from=builder /src/target/release/vproxy /usr/local/bin/vproxy

WORKDIR /app
COPY entrypoint.sh .
COPY warp_register.sh .
COPY warp_register.py /app/warp_register.py
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
