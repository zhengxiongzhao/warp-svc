# CHANGELOG

## [v3.4.0] - 2026-09-15

### Changed
- Endpoint 自动优选重构为三级链：Tier 1 官方 `engage.cloudflareclient.com:2408` → Tier 2 Misaka `warp-yxip` 优选前 10 个 IP:Port（`wget warp-yxip.sh && bash warp-yxip.sh`）→ Tier 3 冷却重试
- 移除旧固定 IP×端口笛卡尔积候选列表（11 IP × 7 端口 = 77 次盲握手，重启循环下放大 CF 限速）
- 全链失败后不再退出容器，进入可配置冷却期（`COOLDOWN_SECONDS`，默认 24h）后自动重试完整链
- Dockerfile 新增 Tier 2 运行依赖：`bash gcompat libstdc++`（优选工具为 glibc 二进制，gcompat 提供 musl 兼容层）

## [v3.3.0] - 2026-09-15

### Changed
- Dockerfile 改用 vproxy 官方 Release 预编译二进制（musl 静态），替代原 Rust 源码编译阶段
- 构建时间从 10-15 分钟降至秒级，消除对 rustc 1.97 MSRV 的脆弱依赖
- 下载后强制 sha256sum 校验，构建期自动执行 `vproxy --version` 自检
- 新增构建参数：`VPROXY_TAG`（缺省自动跟随最新 release，可固定版本如 `--build-arg VPROXY_TAG=v2.5.5-fix.2`）、`GH_PROXY`（GitHub 下载加速前缀）
- 按 Docker `TARGETARCH` 自动选择 amd64/arm64 资产

### Removed
- 删除阶段 1 Rust 编译层（`rust:alpine3.20` + git clone + cargo build）

---

## [v3.2.0] - 此前版本

见 git log。
