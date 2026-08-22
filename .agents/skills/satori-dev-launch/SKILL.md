---
name: satori-dev-launch
description: 启动 satori Tauri 应用进行开发/查看时使用。当用户说"启动看看"、"跑一下"、"打开应用"、验证 UI 改动等场景时使用。
---

# satori 开发启动

## 核心规则

启动 satori 应用用于开发或查看时，**必须**用 `npm run app`（内部调用 `./scripts/dev-app.sh`），**不要**用 `npm run tauri dev`。

## 为什么

- `npm run tauri dev`（debug 构建，`!custom-protocol`）会触发 Tauri 运行时 Dock 图标覆盖，把 Dock 图标替换成**未蒙版的方形图标**（macOS 不套圆角蒙版）。这是已知坑，详见 `docs/plans/2026-08-16-tauri-dock-icon-design.md`。
- `./scripts/dev-app.sh` 使用 release + `custom-protocol` 的稳定签名壳，Dock 图标走 bundle icns + 系统蒙版，圆角正确；开发专用协议从仓库 `dist/` 读取最新前端，发布包仍使用内嵌资源。脚本自动选择唯一的 `Apple Development` 身份并在签名后校验 bundle ID。发布用的 `Developer ID Application` 只允许通过环境变量显式选择。
- 普通 `tauri dev` 运行的是随重编译变化的 ad-hoc debug 二进制，会放大 macOS Keychain 授权问题。专用入口的启动与设置状态检查不解密 Key；真正测试或提问时才允许授权。

## 使用步骤

```bash
npm run app
```

- 会自动停止旧 dev 实例并构建前端；只有 Rust、Cargo/Tauri 配置、图标、启动脚本或签名身份变化时，才重建并签名 `src-tauri/target/release/satori-dev.app`。
- 首次或改动原生代码时构建较慢（约 1 分钟）；只有前端变化时会直接复用签名壳。
- 改前端后仍重跑 `npm run app`，让 Vite 更新 `dist/` 并重开页面；原生 CDHash 不变，不会因此重新触发 Keychain 授权。
- 可用 `SATORI_CODESIGN_IDENTITY` 明确指定带 Team ID 的 Apple 签名身份；发现多个 `Apple Development` 身份时脚本会要求显式选择。若机器只有本地自签证书，Rust/配置/签名变化后，每个已保存连接在首次主动使用 AI 时仍可能需要一次 macOS 授权；安装 Apple Development 身份后可跨原生重建稳定授权。

## 打包 release（仅当用户明确要求）

默认**不要**打包 release。只有当用户明确说"打包"、"做个安装包"、"发布"之类才运行：

```bash
npx tauri build
```

## 常用验证命令

- 前端类型检查：`npx tsc --noEmit`
- 前端构建：`npx vite build`
- Rust 检查：`cd src-tauri && cargo check`
- 全量构建入口：`npm run app`（内部先 `npm run build` 再 cargo）

## 注意

- 不允许使用明文文件或环境变量保存 API Key。开发构建与发布构建都只使用 macOS Keychain。
- 窗口标题不带 "(dev)" 标记（与 mimi 不同），Dock 图标即唯一区分。
