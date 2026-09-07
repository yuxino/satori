# Current status

Updated: 2026-09-07

## Product

Satori is a local-first macOS and Windows PDF learning workspace. Reading stays central: the learner opens or drags in a local book, returns to the previous page, and explicitly asks for help with the current page or a selected region. It is not a general chat or note-taking product. Version 3.4.5 fixes selected-region evidence, bounds PDF canvas allocation, releases replaced canvases, and keeps asynchronous zoom and thumbnail work tied to the correct state. It retains the signed updater introduced in 3.4.4 and does not change local learning data formats.

## Current implementation

- Stack: Tauri 2, Vite, TypeScript, PDF.js, Rust, and local JSON persistence. The removed Swift app is available only at tag `legacy-swift`.
- Platforms: the base Tauri configuration keeps the macOS `.app` target. A Windows-only overlay adds current-user NSIS packaging for x64 and ARM64, with local state under application LocalAppData and a multi-resolution ICO shared by the app, installer, and uninstaller. CI installs each candidate, checks exact `Satori` identity in executable metadata, HKCU uninstall data, Start menu, and Desktop shortcuts, then requires the application, install directory, uninstall entry, and shortcuts to be absent after uninstall.
- Process integrity: Satori allows one process to own its data directory. A secondary launch restores, shows, and focuses the existing window, while a process-lifetime lock is acquired before the renderer can load so two writers cannot race the shared Store.
- Reader: single/spread layouts, per-book page and zoom restoration, outline navigation, text and scanned-page rendering, and explicitly triggered VLM outline recovery for scanned books. Initial opening now preflights PDF completeness, shows byte/page/render progress, supports cancellation and stall recovery, batches page metadata, bounds canvas memory, and records interrupted opens as retryable bookshelf errors. Ctrl+wheel is reserved for zoom, same-page render/layout callbacks do not inflate reading activity, and normal window/menu exits flush the latest debounced page and zoom snapshot before terminating.
- Home: a restrained monochrome editorial layout containing the current book, 52-week activity grid, bookshelf, and recent Q&A. Each bookshelf row has a visible removal action whose confirmation states that the disk PDF is preserved. Removing a non-current book now refreshes every open bookshelf surface, while removing the current book opens the first remaining book or returns to the empty home view. Book covers are sharp typographic covers rather than PDF thumbnails; labels describe questions and answers without claiming the learner understood them.
- Brand treatment: in-page product-name decoration has been removed so the reading content stays primary. The app name appears as `Satori` only where system context requires it; the home settings entry now uses a quieter, clearer labeled icon.
- Brand assets: the selected F cat-ear-hood character remains the Satori identity. The English and Chinese READMEs retain the existing opaque square `src-tauri/icons/128x128@2x.png`, displayed at 128px with its original ivory background. The transparent circular avatar is unfinished and awaits user authorization for the local alpha-processing method. This session updates documentation only; source images, platform icons and the existing 3.4.5 release packages are unchanged. Asset details remain documented in [Brand assets](brand-assets.md).
- Updates: the official Tauri updater checks one fixed HTTPS `latest.json` after launch and offers a manual recheck in settings. It displays the version and Release notes before any download, shows real byte progress or an indeterminate state, exposes installation only after framework signature verification, and never downloads or installs in the background. Installation first flushes the latest reading position and fails closed if persistence fails. macOS waits for an explicit “重启并完成”; Windows exits after the explicit install action and hands control to a visible `basicUi` installer. GitHub Releases appears only as error recovery.
- Import: the native window accepts one dropped PDF at a time and shares the same import, preflight, progress, cancellation, recovery, and persistence path as the file picker.
- Teacher: startup, importing, reading, and library management have no AI or secure-credential-store side effects. Credential checking begins only after an explicit question, page explanation, region action, or outline-recognition action whose page range is disclosed first; missing configuration opens settings, request failures have actionable Windows/provider guidance and explicit retry, and page images are ephemeral.
- History: completed Q&A is stored locally per book, can reopen the source page, and sends only bounded recent text for follow-ups.
- AI services: multiple named Model Studio, OpenAI, or custom OpenAI-compatible visual profiles. The active profile is explicit and never silently replaced.
- Credentials: API keys live only in macOS Keychain or the current Windows user's Credential Manager with non-roaming `CRED_PERSIST_LOCAL_MACHINE` persistence. They remain bound to profile, normalized endpoint, and auth scope; the renderer receives existence status, never secret data. Windows Store and credential-scope sidecars now use native overwrite-capable atomic replacement, so repeated saves do not fail after the first file exists.
- Safety: Rust resolves persisted profiles for AI commands, rejects insecure or overridden endpoints again before every save, disables redirects, sends `store: false` remotely, and does not read a key when auth is disabled. Normal questions send only the current page; adjacent pages require an explicit previous/next-page request. PDF.js is pinned to the patched 6.2.108 release; reopening a missing book fails closed instead of guessing a same-named path, and Tauri capabilities are least privilege.

## Version and installation

- Current source version: `3.4.5`. This patch provides macOS 14+ Apple silicon and Windows 11 x64 and ARM64 downloads plus a Tauri updater artifact/signature for each architecture and one static `latest.json`. Installations on 3.4.3 or earlier must install a current version manually once.
- The downloadable bundle has a stable local signature and hardened-runtime flag, but no Apple Team ID or notarization; Gatekeeper assessment rejects it, so the documented Control-click opening step remains required.
- The macOS bundle declares macOS 14 as its minimum system version. Release packaging verifies the bundle signature, hardened runtime, version, archive integrity, and SHA-256 before publication.
- The Windows workflow remains non-publishing when run alone, but the explicit updater release workflow can reuse it. Native x64 and ARM64 runners build unsigned current-user NSIS packages plus updater signatures, extract each installer, verify a unique payload and expected PE architecture, install it, check application and shortcut identity, uninstall it completely, and record separate SHA-256 manifests before publication. The publishing workflow independently verifies all three updater signatures against the embedded public key before making the Release public.

## Verification baseline

- Frontend: 72 Node tests cover updater success/failure, known and unknown totals, repeated actions, cancellation/retry, persistence-checkpoint failure, release metadata/checksum validation, and platform installation semantics; strict TypeScript checking and the Vite production build pass, and `npm audit` reports no known vulnerabilities. PDF.js remains a separate reader-only chunk.
- Rust: all 43 remaining native tests pass after removing the obsolete custom GitHub release checker; `cargo fmt --check`, release and `dev-live` checks, and Clippy with warnings denied pass. The official updater/process plugins compile with the least-privilege capability set.
- Real app: the stable signed development shell rebuilt, passed its designated-requirement check, and launched the native `Satori` window. It immediately entered existing reading state, so QA stopped without opening settings, books, AI actions, or credentials; updater UI interaction is not claimed from that launch.
- Windows historical baseline: hosted run `33309980178` passed frontend and Rust checks, exact installer naming, unique NSIS payload extraction, PE architecture checks, current-user install identity, shortcuts, uninstall, and artifact upload for x64 and ARM64 at `b4bc922555f138eed45e4a23e667d1bd755949e8`. Windows 11 25H2 ARM64 UTM run `307e21ee-ce24-4a2e-96db-8a7da4d872c8` installed and launched that exact ARM64 candidate, opened the synthetic three-page PDF, navigated pages, zoomed, selected a region, persisted page and Q&A state across two restarts, and passed taskbar, maximize, normal-close, and Alt+F4 interaction checks. Those bytes predate 3.4.3 and are comparison evidence only. Each 3.4.4 Windows asset must still come from the exact final main SHA and pass independent installer, payload, architecture, identity, full-uninstall, updater-signature, and SHA-256 checks; x64-on-x64 manual interaction is not inferred from ARM64 or hosted CI.

## Repository hygiene

- `docs/plans/` is reserved for unfinished implementation work and is currently empty. Implemented plans remain recoverable from Git history.
- `docs/decisions/` contains current constraints plus superseded records that explain public-version migration. ADR 0019 governs signed in-app updates and marks the older manual update/promotion boundaries as historical.
- Operational details for the stable development shell now live in ADR 0014 instead of an implemented task plan.
- Legacy Swift `Info.plist` / `.icns`, the copied public asset README, and the unused browser-preview script were removed. The current Tauri icon source and required macOS bundle sizes remain tracked.
- Tauri capability schemas generated for desktop, macOS, and Windows are tracked. Their JSON content currently matches, so a Windows build no longer dirties the source tree by introducing `windows-schema.json`.
- The 3.4.2 cleanup removed an unreachable pre-home empty-state stylesheet, consolidated release-version display logic, and merged the update-copy checks into the existing platform test surface without reducing behavioral coverage.
- The 3.4.3 audit removed a superseded PDF-loading wrapper and its dead export, deleted an unreferenced 1,443,308-byte Windows icon source, and stopped embedding 2,074,834 bytes of production source maps. The existing loading behavior tests now exercise the live monitor directly; all 47 frontend behavior tests remain. Release builds also use one codegen unit because the measured binary reduction is material and does not weaken runtime or diagnostic coverage.

## Durable constraints and pitfalls

- Run frontend builds before Rust checks; Vite rebuilds assets embedded by Tauri.
- On macOS, use `npm run app` for development viewing. Plain `tauri dev` changes the app identity and Dock icon behavior there; Windows development uses the Tauri source workflow instead.
- The real development app fails closed when no stable code-signing identity exists; ad-hoc signing is not a supported fallback because it changes macOS authorization identity after native rebuilds.
- A self-signed identity has no Apple Team ID. Native rebuilds may require one authorization per saved profile on its first explicit AI use; startup and status inspection must remain interaction-free.
- AI IPC accepts profile IDs only. Rust loads the trusted profile and verifies the credential scope before sending a request.
- Fixed-name PDF.js WASM decoders belong in `public/`; Vite-hashed imports break JBIG2/JPEG2000/ICC decoding.
- Opening a PDF must never trigger scanned-outline recovery. The directory action must disclose both bounded stages—including the exact page ranges and image counts for directory extraction and chapter-location sampling—and wait for an explicit click.
- Switching books invalidates any in-flight explanation. Late chunks and completed answers must never appear in, or be saved against, a different book.
- Removing a book must use separate accessible controls and an explicit destructive confirmation that names the local reading data and Q&A being removed.
- Update checks use only the fixed HTTPS updater manifest and embedded public key. Never enable insecure transport, accept an unsigned artifact, expose installation before the official plugin resolves signature verification, rotate the key without an old-key bridge release, or use Releases as the normal download path.
- Windows local state belongs in application LocalAppData, while credentials belong only in Windows Credential Manager with local-machine persistence. Do not add plaintext, environment-variable, roaming, renderer-visible, or cross-platform credential fallbacks.
- Windows file replacement must preserve overwrite semantics for both Store JSON and credential-scope markers; do not restore direct `std::fs::rename` over an existing destination.
- Windows packaging is current-user NSIS and remains manual/non-publishing when run alone. Keep x64 and ARM64 installers, updater signatures, and SHA-256 manifests separate. Publishing requires the explicit updater release workflow, exact filename/count checks, extraction, a unique application payload, matching PE architecture, product identity, hosted install/full-uninstall verification, complete `latest.json`, and explicit disclosure of Authenticode and native-acceptance boundaries.
- Store corruption or a newer schema must surface an error, never reset to a default provider or overwrite data.
- Normal window, taskbar, Alt+F4, and app-menu exits must checkpoint the latest page and zoom, cancel pending debounce timers, and await the final atomic Store save before process termination.
- Do not restore plaintext API-key files, allow-all Keychain ACLs, renderer secrets, automatic AI requests, or legacy Swift packaging resources.

## Next work

1. Exercise the complete updater flow from an isolated older updater-capable build to the exact 3.4.4 bytes on macOS and both Windows architectures without touching a real bookshelf or credentials; separately complete x64 manual interaction acceptance on x64 Windows 11.
2. Add an explicit “relink moved PDF” flow that preserves the existing book ID and learning history; missing stored paths currently fail closed and require the learner to choose the file again.
3. Extend AI acceptance beyond the one configured provider and synthetic PDF used here to Model Studio, OpenAI, and a local OpenAI-compatible visual service with representative learning material, then address extreme-page thumbnail and initial page-sizing memory costs.


### 2026-09-06 · README 界面演示

新增真实前端操作录屏、GIF 预览和来源记录，使用原创三页 PDF 展示翻页、缩放、双页与目录。录制环境替代了原生 API 边界，不调用 AI，也不代表原生系统端到端验收。应用代码、模型配置与发布版本均未改变。


### 2026-09-06 · 扩展示范与 10× 节奏

演示扩展到阅读、目录跳转、问题输入和回看界面，操作段 10×、结果短暂停留。未提交真实 AI 请求；未使用或保存用户密钥。仅更新文档与媒体，应用行为和发布不变。


### 2026-09-06 · 真实 AI 回答演示

在原有阅读快放后加入真实视觉问答、追问和回看录屏。两次受限请求成功，使用原创示例书页；原生集成由录制适配层替代，不代表原生端到端验收。密钥不进入仓库、日志或录屏，应用逻辑和版本均未改变。


### 2026-09-06 · 精简演示说明

README 演示区仅保留功能介绍与视频入口，移除制作说明。应用行为未改变。


### 2026-09-07 · PDF 渲染资源与并发修复

- 框选证据只在 PDF.js viewport 中缩放一次，再平移到选区原点；修复默认 3× 导出截到空白/错误位置的问题。
- 阅读、缩略图和证据统一在创建画布前检查尺寸并限制像素/长边。整页与框选 JPEG 最长 1800 像素，直接按目标分辨率渲染；不再先分配完整超大画布后另建缩小画布。导出临时画布及失败/取消的画布立即释放。
- 缩放重绘替换并释放旧画布；渲染期间再次缩放时保留实际请求的分辨率，让后续重绘补齐最新清晰度。移出视口的迟到画布同样释放。
- 缩略图任务绑定原文档、路径和缩略图容器，在异步返回后检查身份；旧书任务不能清除新书的忙碌状态或将新书图像写入旧书缓存。后台预热等待缓存保存、处理失败并释放临时画布。
- 前端 71 项测试（新增 7 项实际渲染入口回归）、TypeScript/Vite build、完整 npm audit（0 项）和 Rust 格式检查通过。ego 中以原创色块 PDF 验证实际 PDF.js：框选中心由旧版白色变为目标红色；连续 5 次缩放的每页画布数由 2/3/4/5/6 变为始终 1，旧画布均归零。受控延迟渲染还验证了连续缩放后的正确补绘。这些是隔离浏览器渲染证据，不代表原生或真实 AI 请求验收。
- 三语 README 演示区保持原资源、alt 与文案，调整为居中的预览、描述、观看链接。演示资源及来源说明未删除。
- 原生：43 项 Rust 测试、`dev-live` check、release Clippy（warnings denied）和真实 Tauri release `.app` 构建全部通过。使用 CommandLineTools 与既有 `/Users/gavin/.cargo` 缓存，构建串行且最多 2 个 Cargo jobs。验证包为 arm64 / macOS 14+ / 3.4.4，包内文件合计 10,979,554 字节，主程序 8,927,856 字节。此次命令级 `--no-sign` 并关闭 updater artifacts，只保留链接器 ad-hoc 签名，不改变仓库发布配置，未进行安装、原生 UI、Windows 或 updater 升级验收。
- 同锁文件同 Vite 参数下，前端总资源由 2,380,610 变为 2,381,300 字节（+690）；PDF 主 chunk 减少 772 字节，其余保护逻辑略增。没有同源原生重建前值，不声称整个安装包缩小。本次不升级依赖，不更改版本、发布流程、凭据或数据格式。


### 2026-09-07 · 常规质量 CI

新增独立 `Quality checks` 工作流，在 main push、指向 main 的 PR，以及手动触发时运行。路径覆盖源码、测试、前端资源、Rust/Tauri、脚本、依赖锁文件、工具链和构建配置；先执行 `npm ci`、前端测试与 build，再执行 macOS Rust fmt、locked test、release check/Clippy 和 dev-live check。沿用 Node 22.13.0、stable Rust 与现有 Actions 提交锁定方式，使用 macOS 15 arm64 runner、2 个 Cargo jobs、40 分钟上限及按工具链/锁文件区分的缓存。工作流只读仓库，无签名私钥、打包、发布或部署步骤；现有 Windows 安装器和手动发布工作流保持不变。新增工作流已通过 YAML 与 actionlint 检查，实际运行结果记录在本次外部交付报告。


### 2026-09-07 · 3.4.5 发布准备

版本源与锁文件已同步为 3.4.5，三语下载说明保留官网和演示区，澄清旧版可直接手动安装当前版本。macOS native app 继续使用既有稳定本地签名；macOS updater archive 的签名改由显式发布工作流复用已有 GitHub Secrets 生成，仍必须通过三平台公钥验签、精确资产和 checksum 门禁后才公开 draft。更新清单使用该版实际 Release notes，macOS checksum 同时覆盖 ZIP 与 updater archive。新增 archive 篡改回归，最终公开 Release/CI/资产证据记录在外部交付报告；本轮不操作正式安装应用或用户学习数据。

### 2026-09-07 · F 猫耳兜帽角色与图标源

- 用户选定 F「猫耳兜帽」并要求更换项目 logo；本轮按已说明的默认方式直接导出原画方形图标，保留象牙色背景，未抠图、重绘或调整五官。
- `src-tauri/icons/source.png` 与选定 F 原图逐字节一致，保留 1254×1254 原始文件供重建。三个 PNG 派生、ICNS 和九尺寸 ICO 继续使用既有配置路径；中英文 README 自动引用新的 256px PNG。来源、重建命令与透明度说明见 [Brand assets](brand-assets.md)。
- 独立资源核验覆盖 6 个文件、23 个图像帧：PNG 尺寸正确，ICO 九帧与 ICNS 十图像帧全部解码，所有帧的 alpha 均为 255。普通结构检查通过，要求透明四角的检查明确失败，与当前不透明方形方案一致；保存的 JSON 与重新解码结果一致。
- 图标更新后，前端 72/72 项测试、TypeScript/Vite build 和 `cargo check --locked --manifest-path src-tauri/Cargo.toml --release` 均通过。九尺寸 ICO 已在浅色、深色背景下目视检查，保留象牙方形背景；16px 可辨帽子和脸的大致形状，细节有限。
- 原生版本仍为 3.4.5，本次未安装或启动原生应用，也未创建或替换 Release。上述资源和编译检查不代表 macOS Dock、Windows 任务栏、快捷方式、安装器或卸载器的实际显示验收；配套官网部署证据在官网任务中记录。

### 2026-09-07 · README 双语文案与头像待办

- 原应用保留英文默认的 `README.md` 与中文版 `README_ZH.md`，两版互相链接；简介改为具体的 PDF 阅读、框选提问与本地进度保存说明，补齐 AI 服务可能单独收费的边界。
- 两版 README 继续引用现有的 `src-tauri/icons/128x128@2x.png`，显示为 128×128；头像仍是带原始象牙色背景的不透明方图。没有新增底色，也没有用 CSS 圆角冒充透明 PNG。
- 透明圆形头像是本轮品牌调整唯一尚未完成的待办，等待用户授权本地 alpha 处理方法后再制作和验证。本轮仅更新文档，不修改源图、平台图标或 [Brand assets](brand-assets.md) 中记录的现有资源。
- 下载版本、平台要求、更新迁移、安装提示和隐私说明保持原有边界；文档修改不代表新的原生构建、系统图标验收或 Release。
