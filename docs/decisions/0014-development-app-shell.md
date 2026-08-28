# 0014 · 使用稳定的开发应用壳

日期：2026-08-23 · 状态：已采纳

## 背景

普通 `tauri dev` 运行随构建变化的调试二进制，并启用 Tauri 的开发期运行时图标覆盖。macOS 不会替运行时设置的全出血图标套系统蒙版，因此 Dock 会显示方形图标；变化的应用身份也会放大 Keychain 授权问题。

## 决策

1. 开发查看统一使用 `npm run app`，由 `scripts/dev-app.sh` 组装真实 `.app`；不把普通 `tauri dev` 作为受支持的应用启动入口。
2. 开发壳使用 release 构建并启用 `tauri/custom-protocol`，让 Dock 图标来自 bundle 的 `icon.icns` 并由 macOS 正常蒙版。
3. 仅开发构建启用 `dev-live`，通过受限磁盘资源处理器读取仓库 `dist/`，并提供开发者工具菜单。发布构建仍使用内嵌资源，不包含开发文件访问能力或 WebView 开发者工具。
4. 启动脚本按 Rust 源码、Cargo/Tauri 配置、图标、脚本和签名身份计算原生指纹。只有这些输入变化才重建并签名应用壳；普通前端变化只更新 `dist/`，保持 CDHash 不变。
5. 签名身份选择与 Keychain 授权边界遵循 ADR 0012。脚本自动选择唯一的 Apple Development 身份；发布用 Developer ID 只能显式指定。

## 影响

- 前端视觉迭代可以复用稳定的原生壳，Dock 图标与发布版本一致，也不会因为嵌入前端资源而反复改变签名。
- Rust、原生配置、图标或签名身份变化仍会触发重建；没有 Apple Team ID 时，首次主动使用每个已保存凭据仍可能要求系统授权。
- `scripts/dev-app.sh` 是这些机制的可执行实现；本 ADR 只保留长期约束，不复制易腐烂的排查过程。
