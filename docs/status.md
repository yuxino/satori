# Current status

## Project state

**2026-08-16 起：方向变更，Tauri 重写（Satori 3.0）。** 旧 Swift 实现完整保留在 `legacy-swift/`（git tag `legacy-swift`），不再维护。当前主分支是 Tauri 2 + PDF.js 的全新实现。产品定位：选中 PDF 里看不懂的部分，获得基于当前页的解释；本地优先，不强迫记笔记。

## Confirmed decisions（3.0）

- Name: `satori`；平台：macOS only
- 产品形态：全屏书页 + 被召唤才出现的讲解（详见 `docs/plans/2026-08-16-book-teacher-design.md`）
- 核心范式：**页面即证据**——视觉模型直接读页面图像，不建 OCR 管线
- 工具链：Tauri 2 + Vite + TS + PDF.js（决策见 `docs/decisions/0010-tauri-rewrite.md`）
- 存储：本地 JSON（Application Support）；API Key 只进 macOS Keychain
- 模型：百炼 `qwen3-vl-plus` 默认（可切 `qwen3-vl-flash` / `qwen-vl-max`），北京共享地址，`store: false`

## Completed so far

- 旧 Swift 代码迁入 `legacy-swift/` 并打 tag，工作区换新结构
- Tauri 2 骨架：窗口、图标、capabilities、asset protocol
- Rust 后端：`keychain.rs`（旧条目迁移 + 新 service 写入，`apple-native` feature）、`store.rs`（书库/位置/Q&A JSON 持久化 + 损坏备份）、`qwen.rs`（百炼视觉客户端：流式问答 + 扫描目录恢复）、`thumbs.rs`（缩略图磁盘缓存）
- Keychain 迁移已实际完成：旧条目 key 已用 `mimi Local Development` 证书读出并写入新条目 `com.yuxino.satori.qwen.v3`，验证一致（117 字符）。**用户无需再粘贴 API Key。**
- 前端阅读器（连续滚动式）：PDF.js 渲染、懒渲染视口附近页面、捏合/⌘+/- 缩放、框选理解（扫描版可用）、跨页证据、Preview 风格底部工具栏（缩略图条 + 翻页 + 缩放）、中性工作台主题、错误捕获白屏提示
- **目录清洗统一**：内置大纲与扫描恢复的目录都走同一套 `cleanOutline`——丢掉第一个「第X章」之前的条目（封面/前言/目录/考试大纲/考核目标/题型举例/参考答案/后记 等）+ 关键字过滤，过滤后为空则原样保留。system.pdf 93 条原生大纲 → 78 条干净目录
- **每本书记住自己的缩放**：`BookRecord.zoom`（缺省用全局默认）；打开书时直接把恢复的缩放应用给 reader（此前先按 100% 渲染、等 ResizeObserver 触发才跳变，大书会闪一下并白渲染一遍）
- **扫描书目录自动恢复（已闭环验证）**：开书后延迟触发 → 渲染书前部 4 页（scale 1.3）→ `extract_outline`（Qwen 提取印刷页码目录）→ 过滤前置内容（考试大纲/考核目标/题型举例/参考答案/罗马数字前缀等）→ `find_page_by_title` 在正文候选页定位第一章 → 偏移 = 实际页 − 印刷页 → 映射全部条目为 PDF 页码 → 持久化到 store；失败原因显示在目录抽屉
- 扫描书目录恢复期间**暂停缩略图预热**（`preheatPaused`），避免整书预热排队挤占 PDF.js worker（此前渲染目录页要 100s+，修复后 1s）
- 应用菜单：打开调试工具（⌥⌘I）、设置、退出
- `scripts/dev-app.sh`：release 构建 + `custom-protocol` 打包真实 .app，Dock 图标圆角

## Known facts / pitfalls（避免重踩）

- **Tauri dev 模式 Dock 图标是方形**：必须走 release + `custom-protocol`（详见 `docs/plans/2026-08-16-tauri-dock-icon-design.md`）
- **白屏**：`custom-protocol` 决定前端资源是否嵌入二进制；dev-app.sh 用 `--features` 传可能不生效，已直接写进 Cargo.toml
- **滚动容器**：绝对定位页面不撑起滚动高度，必须加普通流式 spacer 撑高
- **初次布局**：WebView 未完成布局时 clientWidth 为 0；需等一帧再量宽度 + ResizeObserver 兜底
- **渲染模糊**：canvas scale 按每页逻辑宽度算（显示宽度×2），硬编码 /72 会超 canvas 上限被降级
- **PDF.js worker 争用**：整书缩略图预热（每页 `setTimeout(0)`）会排队挤占渲染；目录识别等关键渲染前必须暂停预热
- **扫描件解码**：JBIG2/CCITT 页需要 wasm 解码器，`wasmUrl` 必须指向以 `/` 结尾的目录；`lastIndexOf("/")` 取目录
- **serde 字段名**：`OutlineResult.printed_page` 用 `#[serde(rename="page", alias="printed_page")]`，前端按 `page` 读，否则全是 NaN
- **Tauri 命令宏名冲突**：`outline_trace` 之类命令定义在 lib.rs 顶层会与同名宏冲突，需放模块里（qwen.rs）再 `qwen::xxx` 注册
- 旧钥匙串条目 ACL 只信任旧签名；新 App 用同证书同 bundle id 签名即可读
- Rust 侧调试日志：`debug_log()` 写 `~/Library/Application Support/com.yuxino.satori/debug.log`（release 下 stdout 不可见）；保留错误路径日志，成功路径不写

## Next milestone

1. 用真实教材（`software.pdf` 扫描版 + `system.pdf` 文字版）按验收标准跑一遍：打开书 → 翻到不懂页 → 框选/问整页 → 得到解释 → 关掉重开回原页 → 回看找到问答。
2. 观察流式首 token 延迟，必要时调 max_tokens / 图像压缩参数。
3. UI 细节继续打磨（底部工具栏、目录抽屉、老师面板的观感已多轮迭代）。
