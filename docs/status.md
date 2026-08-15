# Current status

## Project state

**2026-08-16 起：方向变更，Tauri 重写（Satori 3.0）。** 旧 Swift 实现完整保留在 `legacy-swift/`（git tag `legacy-swift`），不再维护。当前主分支是 Tauri 2 + PDF.js 的全新实现，目标形态是「一本书，旁边坐着一个老师」。

## Confirmed decisions（3.0）

- Name: `satori`；平台：macOS only
- 产品形态：全屏书页 + 被召唤才出现的老师（详见 `docs/plans/2026-08-16-book-teacher-design.md`）
- 核心范式：**页面即证据**——视觉模型直接读页面图像，不建 OCR 管线
- 工具链：Tauri 2 + Vite + TS + PDF.js（决策见 `docs/decisions/0010-tauri-rewrite.md`）
- 存储：本地 JSON（Application Support）；API Key 只进 macOS Keychain
- 模型：百炼 `qwen3-vl-plus` 默认（可切 `qwen3-vl-flash` / `qwen-vl-max`），北京共享地址，`store: false`

## Completed so far

- 旧 Swift 代码迁入 `legacy-swift/` 并打 tag，工作区换新结构
- Tauri 2 骨架：窗口、图标（从 satori-icon.png 生成全套）、capabilities、asset protocol
- Rust 后端：`keychain.rs`（旧条目迁移 + 新 service 写入，已开 `apple-native` feature）、`store.rs`（书库/位置/Q&A JSON 持久化 + 损坏备份）、`qwen.rs`（百炼视觉流式客户端，老师讲法提示词）
- **Keychain 迁移已实际完成**：旧条目 `com.yuxino.satori.qwen.v2` 的 key 已用 `mimi Local Development` 证书（指纹匹配旧 ACL）读出并写入新条目 `com.yuxino.satori.qwen.v3`，验证一致（117 字符）。**用户无需再粘贴 API Key。** 关键修复：`keyring` 需 `apple-native` feature，否则永远读不到。
- 前端阅读器（连续滚动式）：
  - PDF.js 渲染，页面宽度铺满窗口、连续滚动、懒渲染视口附近页面
  - 触控板捏合缩放（gesturechange）+ Ctrl+滚轮 + ⌘+/-，放大后横向滚动
  - 框选任意区域 → 「框选理解」（扫描版也可用），证据=区域截图+整页
  - 自然语言触发跨页证据（"接上文/下一页/还是不懂"自动带相邻页）
  - Preview 风格底部工具栏：缩略图条（一次性渲染+缓存，滚动只移动高亮框）+ 翻页 + 缩放
  - 中性工作台主题（浅灰+白纸），跟随系统深浅模式
  - 错误捕获：白屏时显示具体错误而非空白
- 应用菜单：打开调试工具（⌥⌘I，手动触发不自动开）、设置、退出
- `scripts/dev-app.sh`：release 构建 + `custom-protocol`（已在 Cargo.toml 写死）打包真实 .app，Dock 图标圆角

## Known facts / pitfalls（避免重踩）

- **Tauri dev 模式 Dock 图标是方形**：debug 构建运行时覆盖图标且 macOS 不套蒙版；必须走 release + `custom-protocol`（详见 `docs/plans/2026-08-16-tauri-dock-icon-design.md`）
- **白屏**：`custom-protocol` 决定前端资源是否嵌入二进制；dev-app.sh 用 `--features` 传可能不生效，已直接写进 Cargo.toml
- **滚动容器**：绝对定位页面不撑起滚动高度，必须加普通流式 spacer 撑高，否则页面看不见也滚不动
- **初次布局**：WebView 未完成布局时 clientWidth 为 0，页面按错误比例建立；需等一帧再量宽度 + ResizeObserver 兜底
- **渲染模糊**：canvas scale 要按每页逻辑宽度算（显示宽度×2），硬编码 /72 会超 canvas 上限被降级
- 旧钥匙串条目 ACL 只信任旧签名；新 App 用同证书同 bundle id 签名即可读

## Next milestone

1. 用真实教材（`lang.pdf` / `software.pdf` 扫描版 + `system.pdf` 文字版）按 MVP 验收标准跑一遍：打开书 → 翻到不懂页 → 框选/问整页 → 得到 3–6 句解释 → 举个例子 → 关掉重开回原页 → 回看找到问答。
2. 验证「页面即证据」对扫描版的实际质量：页图直接送 `qwen3-vl-plus`，确认双栏/公式/图表可读。
3. 观察流式首 token 延迟，必要时调 max_tokens / 图像压缩参数。
4. 产品形态与 UI 细节继续琢磨（用户反馈阅读器观感、底部栏体验已多轮迭代，方向未定稿）。

## Open questions

- 需要确认 `qwen3-vl-plus` / `qwen3-vl-flash` 在百炼当前版本是否可用（模型 ID 依据 DashScope 文档，首次真实调用验证）。
- 扫描版书的章节导航（大纲）MVP 阶段不做，先验证理解闭环；如需要再加。
