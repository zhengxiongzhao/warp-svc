# CHANGELOG

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
