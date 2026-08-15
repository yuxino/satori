# satori Tauri dev 模式 Dock 图标设计记录

> 2026-08-16。沿袭 mimi-r 在 2026-08-14 排查同一问题后落定的结论，避免重蹈覆辙。
> 原始排查记录见 mimi-r `docs/plans/2026-08-14-tauri-dev-dock-icon-design.md`。

## 结论（一句话）

**Tauri 的 `cfg(dev)` 不是构建类型，而是 `!custom-protocol` 特性。** 只要没有 `custom-protocol` 特性，即使是 `cargo build --release`，Tauri 也会把应用当 dev 处理，在运行时把 Dock 图标替换成未蒙版的方形图标。

## 问题现象

- 用 `npx tauri dev`（debug 构建）启动：**启动瞬间图标正确（圆角），应用完全启动后变成方形**。
- 修改 bundle 里的 `icon.icns` 无效；改源图、清图标缓存均无效。

## 根因机制（源码链）

1. **`cfg(dev)` 的定义** — `tauri/build.rs`：`dev = !has_feature("custom-protocol")`。
2. **dev 时的运行时图标覆盖** — `tauri/src/app.rs` `RuntimeRunEvent::Ready` 分支：`#[cfg(all(dev, target_os = "macos"))]` 下调用 `NSApplication setApplicationIconImage(app_icon)`，其中 `app_icon` 是编译期嵌入的 `src-tauri/icons/icon.icns` 字节（改 bundle 里的 icns 无效）。
3. **macOS 不对运行时设置的图标套圆角蒙版** — `setApplicationIconImage` 设置的图标按原样渲染：全出血的 icns 显示为**方形且更大**。

## 为什么 `tauri build` 的产物是对的

`tauri build`（release）执行 `cargo build --bins --features tauri/custom-protocol --release`：开了 `custom-protocol` → `dev=false` → 运行时覆盖不执行 → Dock 从 bundle 读 icns → macOS 正常蒙版 → 圆角。

## 修复（satori）

`scripts/dev-app.sh` 与 `tauri build` 保持一致：

```
cargo build --release --features tauri/custom-protocol --manifest-path src-tauri/Cargo.toml
```

dev 包装应用与 release 走完全相同的图标路径（bundle icns + 系统蒙版），Dock 图标为圆角。

## 附带要点

- dev 包装是 release 构建，`tauri::is_dev()` 恒为 `false`；需要区分时按 bundle id `com.yuxino.satori.dev` 判断。
- 调试二进制（`npx tauri dev` 裸跑）仍会触发该覆盖，Dock 图标无法蒙版；如需图标正确的调试体验，用 `scripts/dev-app.sh`。
- 图标源图 `Resources/Assets/satori-icon.png` 为全出血方形（无透明区），圆角完全依赖 macOS 系统蒙版，因此必须走 release 路径。
