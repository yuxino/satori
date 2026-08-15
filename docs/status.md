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

## Completed in the Tauri skeleton

- 旧 Swift 代码迁入 `legacy-swift/` 并打 tag，工作区换新结构
- Tauri 2 骨架：窗口、图标（从 satori-icon.png 生成全套）、capabilities、asset protocol
- Rust 后端：`keychain.rs`（旧条目迁移 + 新 service 写入）、`store.rs`（书库/位置/Q&A JSON 持久化 + 损坏备份）、`qwen.rs`（百炼视觉流式客户端，老师讲法提示词）
- 前端：PDF.js 渲染整窗书页、翻页（←/→ 或 PageUp/Down）、阅读位置保存、悬停阅读栏（页码 + 问这一页 + 回看 + 设置）、选中划词胶囊、底部老师面板（流式回答 + 再讲细一点/举个例子/换个说法 + 自由追问）、回看抽屉（按页列出 Q&A 并可跳回）、重开提示「上次读到第 N 页」、设置弹窗（Key + 模型选择）
- `npx tauri dev` 可正常启动窗口；`cargo check` / `tsc` / `vite build` 全绿

## Known facts from verification

- 旧钥匙串条目（service `com.yuxino.satori.qwen.v2`）存在，但其 ACL 只信任旧签名 App，新 App 与 `security` 命令均读不到密码（exit 161）。**需要用户在新 App 设置里重新粘贴一次 API Key**（设计已预判此 fallback）。
- WebKit 开发模式下的缓存目录警告无害。

## Next milestone

1. 用户在新 App 设置粘贴 API Key，验证 keychain 写入 + 读取闭环。
2. 用真实教材（`lang.pdf` / `software.pdf` 扫描版 + `system.pdf` 文字版）按 MVP 验收标准跑一遍：打开书 → 翻到不懂页 → 划选/问整页 → 得到 3–6 句解释 → 举个例子 → 关掉重开回原页 → 回看找到问答。
3. 验证「页面即证据」对扫描版的实际质量：页图直接送 `qwen3-vl-plus`，确认双栏/公式/图表可读。
4. 观察流式首 token 延迟，必要时调 max_tokens / 图像压缩参数。

## Open questions

- 需要确认 `qwen3-vl-plus` / `qwen3-vl-flash` 在百炼当前版本是否可用（模型 ID 依据 DashScope 文档，首次真实调用验证）。
- 扫描版书的章节导航（大纲）MVP 阶段不做，先验证理解闭环；如需要再加。
