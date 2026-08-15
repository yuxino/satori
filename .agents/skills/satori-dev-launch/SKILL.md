---
name: satori-dev-launch
description: 启动 satori Tauri 应用进行开发/查看时使用。当用户说"启动看看"、"跑一下"、"打开应用"、验证 UI 改动等场景时使用。
---

# satori 开发启动

## 核心规则

启动 satori 应用用于开发或查看时，**必须**用 `./scripts/dev-app.sh`，**不要**用 `npm run tauri dev`。

## 为什么

- `npm run tauri dev`（debug 构建，`!custom-protocol`）会触发 Tauri 运行时 Dock 图标覆盖，把 Dock 图标替换成**未蒙版的方形图标**（macOS 不套圆角蒙版）。这是已知坑，详见 `docs/plans/2026-08-16-tauri-dock-icon-design.md`。
- `./scripts/dev-app.sh` 用与 `tauri build` 完全相同的构建路径（release + `custom-protocol`，该 feature 已写死在 `src-tauri/Cargo.toml`），Dock 图标走 bundle icns + 系统蒙版，圆角正确；并打包成 `satori-dev.app` 用 `mimi Local Development` 证书签名（与旧版钥匙串 ACL 匹配，Key 迁移可读）。

## 使用步骤

```bash
./scripts/dev-app.sh
```

- 会自动 pkill 旧 dev 实例、`npm run build` 前端、release 构建（Rust）、组装并启动 `src-tauri/target/release/satori-dev.app`。
- 首次或改动 Rust 时构建较慢（约 1 分钟），建议后台运行并等待输出。
- 改前端后**必须重跑 `./scripts/dev-app.sh`**——release 构建加载的是打包进二进制的 `dist/`，没有热更新。

## 打包 release（仅当用户明确要求）

默认**不要**打包 release。只有当用户明确说"打包"、"做个安装包"、"发布"之类才运行：

```bash
npx tauri build
```

## 常用验证命令

- 前端类型检查：`npx tsc --noEmit`
- 前端构建：`npx vite build`
- Rust 检查：`cd src-tauri && cargo check`
- 全量构建入口：`./scripts/dev-app.sh`（内部先 `npm run build` 再 cargo）

## 注意

- API Key 开发兜底：`~/Library/Application Support/com.yuxino.satori/satori/dev-api-key`（纯文本），存在时 App 完全不碰钥匙串。测试阶段往里写一次即可，避免每次启动弹钥匙串。
- 窗口标题不带 "(dev)" 标记（与 mimi 不同），Dock 图标即唯一区分。
