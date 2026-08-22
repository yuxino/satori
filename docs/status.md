# Current status

## Project state

**2026-08-16 起：方向变更，Tauri 重写（Satori 3.0）。** 旧 Swift 实现已从工作区移除，完整存档在 git tag `legacy-swift`，不再维护。当前主分支是 Tauri 2 + PDF.js 的全新实现。产品定位：选中 PDF 里看不懂的部分，获得基于当前页的解释；本地优先，不强迫记笔记。

## Confirmed decisions（3.0）

- Name: `satori`；平台：macOS only
- 产品形态：全屏书页 + 被召唤才出现的讲解（详见 `docs/plans/2026-08-16-book-teacher-design.md`）
- 核心范式：**页面即证据**——视觉模型直接读页面图像，不建 OCR 管线
- 工具链：Tauri 2 + Vite + TS + PDF.js（决策见 `docs/decisions/0010-tauri-rewrite.md`）
- 存储：本地 JSON（Application Support）；API Key 只进 macOS Keychain
- AI 服务：多个命名 profile；内置百炼与 OpenAI，也可配置 OpenAI-compatible 云端/本地服务。百炼 `qwen3-vl-plus` 仍是旧用户默认；远程请求 `store: false`
- 版本：`v3.2.0`（黑白视觉身份、Kiri 风格角色图标与代码清理）；旧 Swift 版 tag `legacy-swift`

## Completed so far

- **黑白视觉与角色身份（2026-08-23）**：移除首页“悟”字方框和设置页单字头像，品牌只保留 `satori` 字标，服务类型使用明确文字标签。全局画布、阅读器、问书与设置统一为黑、白、灰，暖金只用于书签和当前日期。新图标保留银发、书本发夹与金色眼睛的 Satori 角色，采用 Kiri 式圆形 Q 版徽章构图；外圈使用粗细交替的断开双弧、沿圆周分布的闪点和压住边线的小型纸花装饰，并让头发、肩部和书本自然穿出边界。已删除 48 个 macOS 构建未引用的 Windows / Android / iOS 图标资产
- **整体 UI / UX 重设计（2026-08-23）**：主页从统计看板改为“今日书桌”——最近阅读的书、排版封面、页码与继续阅读成为首屏主线；用户喜欢的 52 周学习格子完整保留，四张统计卡移除。书架改为纵向书脊列表，最近问答改为带回答摘要、可直接回到原页的“最近弄懂的”
- **封面与配色修正（2026-08-23）**：首页和阅读工作台从常见 AI 产品的米灰＋淡紫改为黑、白、石墨与纯灰阶。首页不再读取低清 PDF 首屏缩略图；主书与书架按书 ID 从六级灰度稳定生成文字排版封面，书名与页数在任意分辨率下保持锐利，不依赖网络或生成式图片
- **阅读与问书统一视觉语言**：全宽底栏收为居中的浮动阅读轨，按书/目录、翻页、章节和视图分组；目录抽屉补齐书名、关闭入口与原生键盘按钮。问书面板增加当前页/章节上下文，初始态提供三个具体学习起点，多行输入支持 Shift+Enter，问题、回答、理解历史与追问动作使用同一套编辑式排版，不再像外挂聊天窗口
- **问书回看体验修复**：从主页或理解历史打开旧回答时保留回答发生的页码/章节，并恢复快捷追问和底部输入区。打开问书初始态仍然不读取 Keychain、不渲染页面、不调用模型；本轮实机检查主页、阅读器、初始问书、理解历史和已保存回答均未触发系统授权窗口
- **多 AI 服务配置（2026-08-22）**：设置页从“单个百炼 Key + 模型”升级为 master-detail 多连接管理。可同时保存多份百炼、OpenAI 或自定义 OpenAI-compatible 连接；配置名称、服务地址、模型、鉴权开关分别持久化，并明确“保存”和“设为当前”是两个动作。内置服务固定官方地址，自定义远端必须 HTTPS，本机 loopback 可用 HTTP；支持无需鉴权的本地/远程兼容服务
- **设置 UI 重做**：780×560 macOS 偏好设置式界面，左侧连接列表、右侧编辑器、固定底部操作栏；支持添加/删除、Key 替换/移除、图片能力连接测试、字段错误、加载/成功/失败状态、未保存更改确认。已实机检查主窗口尺寸、内容滚动、底栏可见性、键盘焦点、Esc 和确认卡片；背景 inert、焦点环、深色变量、窄窗与减少动态样式齐全
- **多 provider 安全边界**：AI 命令只接收 profile ID，Rust 从 Store 读取唯一档案；Keychain secret 绑定 provider + 规范化 endpoint + auth scope，关闭鉴权时完全不读取 Key；禁止重定向、限制响应大小并脱敏服务端错误。删除默认 Key 会清理旧 Qwen 条目并写 Keychain tombstone；损坏/未来版本 Store 不再静默回退百炼
- **开发模式授权治理**：启动、设置页和状态刷新改为 Keychain existence-only 查询，不再解密 Key；自动目录恢复禁止弹系统授权，用户主动提问/测试后按 profile + scope + generation 缓存在 Rust 进程内。generation 同时绑定 Keychain envelope 与非敏感 sidecar，多实例通过本地锁串行保存/删除，旧缓存不会跨连接变更复用。`npm run app` 只自动选择唯一的 Apple Development 身份并校验结果；开发专用 `tauri://` 处理器从 `dist/` 读取前端，脚本只在原生输入或签名变化时重建 `.app`。已实测纯前端重启前后最终 CDHash 均为 `98ba24c…`；前一轮同机制的新进程实际读取 Key 并请求服务时无 SecurityAgent 或新 XARA 日志
- **旧配置无感迁移**：旧 `settings.model_id` 迁入确定性百炼 profile；旧 v3/v2 Keychain 或开发 Key 只允许绑定官方百炼 scope。Store 写入串行且原子化，保存前固定快照，profile ID/active ID/版本均验证。Rust 现有 26 项迁移、URL、请求体、SSE、错误、缓存、安全与开发资源路径单测全部通过

- **首页 / 总览数据**：启动落在首页（不再直接跳进上次的书）。52 周学习格子按当天阅读页数+提问量分级，配合当前书、书架和“最近弄懂的”；活动日志 `Store.activity`（日期 → pages/questions），翻页计数由阅读位置持久化防抖落盘、提问计数随保存问答落盘
- **问书入口去副作用（2026-08-22）**：泛 AI 的星光悬浮球改为安静的书页图标。点击只展开「这页哪里卡住了？」提问面板并聚焦输入框，不读取 Keychain、不渲染页面图、不调用模型；只有用户发送问题或明确点「讲讲这一页」后才开始请求。已实机确认打开面板无 SecurityAgent/XARA 日志，Esc 可收起
- **AI 回答交互**：讲解卡片改为紧凑的页边批注（420px、14px 无衬线正文、短行距、低权重操作与输入区），不再像放大的书页正文；保留流式回答前「正在讲…」三点动画、发送反馈和框选选区圆角柔边
- **流式回答自动滚动**：首问/框选回答随内容增长自动滚到底（追问原本就有）
- **清理**：删除未用 import/参数；移除旧全局 `settings.zoom`（缩放已按书记录，没记过的书打开即适合宽度，不再继承旧的 0.5）

- 旧 Swift 代码迁入 tag `legacy-swift` 存档，工作区移除（2026-08-18 清出，仓库不再跟踪 Swift 源码）
- Tauri 2 骨架：窗口、图标、capabilities、asset protocol
- Rust 后端：`keychain.rs`（按 profile 隔离凭据 + 旧条目迁移）、`provider.rs`（服务地址、scope 与请求策略）、`store.rs`（书库/位置/Q&A/profile JSON 持久化 + 损坏备份）、`qwen.rs`（OpenAI-compatible 视觉客户端：流式问答 + 扫描目录恢复）、`thumbs.rs`（缩略图磁盘缓存）
- Keychain 迁移已实际完成：旧条目 key 已用 `mimi Local Development` 证书读出并写入新条目 `com.yuxino.satori.qwen.v3`，验证一致（117 字符）。**用户无需再粘贴 API Key。**
- 前端阅读器（连续滚动式）：PDF.js 渲染、懒渲染视口附近页面、捏合/⌘+/- 缩放、框选理解（扫描版可用）、跨页证据、Preview 风格底部工具栏（缩略图条 + 翻页 + 缩放）、中性工作台主题、错误捕获白屏提示
- **目录清洗统一**：内置大纲与扫描恢复的目录都走同一套 `cleanOutline`——丢掉第一个「第X章」之前的条目（封面/前言/目录/考试大纲/考核目标/题型举例/参考答案/后记 等）+ 关键字过滤，过滤后为空则原样保留。system.pdf 93 条原生大纲 → 78 条干净目录
- **框选证据带红框**：整页图按选中区域画红色高亮框（裁剪图加红边），模型不再说「图片里没有框选区域」而靠猜；问题文案提示模型读红框内容
- **底部栏当前章节指示**：按当前页显示最近的章级目录条目（大书翻页知道自己在哪一章），滚动/翻页实时更新
- **双页下框选页码修复**：同一行左右页纵坐标相同，原来按纵坐标会把左页框选归到右页（坐标错误、问错页）；现按选区中心点落在哪个页面矩形来定位，书缝等空白处选最近页（偏左页，页码显示与主流阅读器一致）
- **翻页式阅读（替代连续下拉滚动）**：页面/展开按「适合视口」整页放进屏幕并垂直居中（不再需要下拉），←/→ 和底部 ‹ › 翻页（双页按行翻），滚轮/拖动滚动停稳后吸附回最近的整页（跨页才吸附，页内滚动不打扰），隐藏滚动条；缩放语义保持 1 = 整页适合视口
- **双页（书本展开）视图**：底部栏「双页/单页」切换，每本书记住偏好（`BookRecord.spread`）。双页时第 1 页（封面）单独在右，之后 (2,3)、(4,5)… 偶数页在左、奇数页在右，行高取两页较大者；切换布局后回到「适合宽度」并把缩放一并记到该书。缩放/滚动/框选在双页下同样工作
- **目录与「问过的」分开**：左侧抽屉（⌘T / 底部「目录」按钮）只放章节导航；问答历史收进老师面板——面板头部左侧「问过的」按钮在「当前问答 ⇄ 这本书问过的问题列表」间切换，点条目回到该页并重看（返回问答 可回到刚才看的问答）
- **每本书记住自己的缩放**：`BookRecord.zoom`（缺省用全局默认）；打开书时直接把恢复的缩放应用给 reader（此前先按 100% 渲染、等 ResizeObserver 触发才跳变，大书会闪一下并白渲染一遍）
- **扫描书目录自动恢复（已闭环验证）**：开书后延迟触发 → 渲染书前部 4 页（scale 1.3）→ `extract_outline`（Qwen 提取印刷页码目录）→ 过滤前置内容（考试大纲/考核目标/题型举例/参考答案/罗马数字前缀等）→ `find_page_by_title` 在正文候选页定位第一章 → 偏移 = 实际页 − 印刷页 → 映射全部条目为 PDF 页码 → 持久化到 store；失败原因显示在目录抽屉
- 扫描书目录恢复期间**暂停缩略图预热**（`preheatPaused`），避免整书预热排队挤占 PDF.js worker（此前渲染目录页要 100s+，修复后 1s）
- 应用菜单：打开调试工具（⌥⌘I）、设置、退出
- `scripts/dev-app.sh`：release + `custom-protocol` 打包真实 .app，Dock 图标圆角；前端始终重建，签名原生壳按 native fingerprint 复用

## Known facts / pitfalls（避免重踩）

- **Tauri dev 模式 Dock 图标是方形**：必须走 release + `custom-protocol`（详见 `docs/plans/2026-08-16-tauri-dock-icon-design.md`）
- **设置确认不要用 `window.confirm`**：当前 Tauri capability 不允许 `plugin:dialog|confirm`，会触发致命错误；设置页使用自己的可访问确认卡片
- **AI 命令不能信任 WebView 传来的完整 profile**：命令只收 ID，Rust 从 Store 解析；否则已保存 Key 可能被借给另一个自定义地址
- **自签证书不能让 Keychain 授权跨原生重建稳定**：没有 Apple Team ID 时，macOS partition 按精确 CDHash 授权；普通本地证书的 designated requirement 稳定也不够。开发脚本已让前端改动复用同一签名壳；Rust、原生配置或签名变化后仍可能授权一次。完整跨原生重建免弹需 Apple Development 身份（或显式选择带 Team ID 的其他 Apple 身份）
- **前端构建与 Rust 测试不要并行**：Vite 会清理并重建 `dist/`，同时运行会让 Tauri `generate_context!` 短暂找不到嵌入资源；先 `npm run build`，再跑 Cargo
- **白屏**：发布构建的 `custom-protocol` 使用内嵌资源；开发构建额外启用 `dev-live`，用受限 `tauri://` 处理器读取 `dist/`。两条路径都必须在构建后实机打开，不能只看 TypeScript 编译
- **滚动容器**：绝对定位页面不撑起滚动高度，必须加普通流式 spacer 撑高
- **初次布局**：WebView 未完成布局时 clientWidth 为 0；需等一帧再量宽度 + ResizeObserver 兜底
- **渲染模糊**：canvas scale 按每页逻辑宽度算（显示宽度×2），硬编码 /72 会超 canvas 上限被降级
- **PDF.js worker 争用**：整书缩略图预热（每页 `setTimeout(0)`）会排队挤占渲染；目录识别等关键渲染前必须暂停预热
- **扫描件解码**：JBIG2/JPEG2000/ICC 页需要 wasm 解码器。**wasm 不能走 Vite 的 `?url` 导入**——`?url` 会加内容哈希（`jbig2-xxx.wasm`），而 pdf.js 按固定名请求 `{wasmUrl}jbig2.wasm`，哈希名 404 → JBIG2 解码静默失败 → 整页渲染空白（system.pdf 292/294 页全白，模型答「这页是空白的」）。已把解码器放 `public/`（原样拷到 dist 根、固定文件名），`wasmUrl = "/"`。JBig2Error 修复后 software.pdf 正常是因为它全是 DCTDecode（JPEG），浏览器原生解码、不依赖 wasm
- **serde 字段名**：`OutlineResult.printed_page` 用 `#[serde(rename="page", alias="printed_page")]`，前端按 `page` 读，否则全是 NaN
- **Tauri 命令宏名冲突**：`outline_trace` 之类命令定义在 lib.rs 顶层会与同名宏冲突，需放模块里（qwen.rs）再 `qwen::xxx` 注册
- 旧钥匙串条目首次切换到新的 Apple Team 签名时可能需要一次“始终允许”或重新保存；不要通过放宽 ACL、明文文件或 `/usr/bin/security` 代读绕过
- Rust 侧调试日志：`debug_log()` 写 `~/Library/Application Support/com.yuxino.satori/debug.log`（release 下 stdout 不可见）；保留错误路径日志，成功路径不写

## Next milestone

1. 用真实教材（`software.pdf` 扫描版 + `system.pdf` 文字版）按验收标准跑一遍：打开书 → 翻到不懂页 → 框选/问整页 → 得到解释 → 关掉重开回原页 → 回看找到问答。
2. 分别用真实百炼、OpenAI 和一个本地 OpenAI-compatible 视觉模型跑连接测试与一轮书页提问；当前实现没有在验收时主动调用用户服务。
3. 观察流式首 token 延迟，必要时调 token 上限 / 图像压缩参数。
4. UI 细节继续打磨（底部工具栏、目录抽屉、老师面板的观感已多轮迭代）。
