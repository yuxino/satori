# 0017 · Windows 支持边界

日期：2026-08-30 · 状态：已采纳

## 背景

Satori 原先只面向 macOS：本地状态写入 Application Support，API Key 存入 macOS Keychain，基础 Tauri 配置也只生成 `.app`。Windows 支持不能以明文凭据、漫游凭据、覆盖 macOS 打包设置，或把 CI 编译当成原生验收为代价。

本决策只扩展 ADR 0010 与 ADR 0012 的 macOS-only 平台范围；两份决策中的 macOS 路径、Keychain 和授权边界继续有效。

## 决策

1. macOS 继续使用原有 Application Support 路径和 Keychain 实现。Windows 的书架、阅读进度、问答历史、缩略图、凭据作用域标记和日志写入 Tauri 的应用级 LocalAppData 目录，不把这些数据放进可漫游目录。
2. Windows API Key 以 Generic Credential 写入当前用户的 Windows Credential Manager，并使用 `CRED_PERSIST_LOCAL_MACHINE`，避免随企业账户漫游。渲染层仍只能取得“是否已保存”状态；凭据内容不写入 JSON、环境变量、日志、截图或 WebView 状态，也没有明文降级路径。
3. `tauri.conf.json` 继续保留 macOS 的 `app` target。Windows 构建只合并 `tauri.windows.conf.json`，使用单独的多尺寸 ICO，生成 current-user NSIS 安装器；默认安装位置与卸载信息分别位于当前用户的 LocalAppData 和 HKCU，不要求管理员权限。
4. Windows 工作流只允许手动触发。它在 GitHub 托管的 `windows-2025` x64 与 `windows-11-arm` ARM64 runner 上分别执行前端测试/构建、锁文件约束下的 Rust 测试/检查/Clippy，以及 unsigned NSIS 打包。所有外部 Actions 使用完整提交 SHA；工作流只上传短期构建 artifact，不创建或修改 GitHub Release。
5. 工作流必须验证 runner 架构、唯一且名称精确（包括大小写）的安装器，并解包 NSIS，分别验证 release `satori.exe` 与安装器 payload 的 PE Machine。x64 的 PE Machine 必须为 `0x8664`，ARM64 必须为 `0xAA64`。工作流分别记录 release executable、NSIS payload 与 installer 的 SHA-256；bundle 过程可能改写可执行文件，因此不要求 bundle 前后的全文件哈希相同。NSIS 的 ARM64 安装器外壳本身仍是通过 Windows 模拟层运行的 x86 程序；原生架构承诺只针对安装器内的 Satori 应用。
6. 更新检查按当前平台匹配 Release asset。没有匹配的 Windows 安装器时，Windows 端不能声称有可下载更新，但仍可打开固定的官方 Releases 页面。当前已发布的 Release 仍只有 macOS 下载；Windows 工作流 artifact 不等同于公开发布。
7. Windows 上本地 JSON 与凭据作用域标记的原子更新必须使用能覆盖已有目标的原生替换语义。不能直接依赖 `std::fs::rename(temp, target)`，因为它在 Windows 上不会覆盖已有文件；普通阅读进度保存和同一配置的第二次 Key 保存都必须可重复成功。
8. 打开 PDF 前只读取头尾小范围来拒绝非 PDF、未复制完成和读取失败的文件，不按总文件大小拒绝有效 PDF。PDF.js 加载、页面尺寸读取和首屏渲染必须提供阶段与进度，支持取消和停滞超时，并限制页面尺寸并发、邻页画布数量与单画布像素预算。进程若在打开过程中退出，下次启动只显示可重试错误，不自动恢复该文件。
9. 桌面拖放使用 Tauri 原生文件拖放事件，不从浏览器 `File` 对象复制或持久化 PDF。一次只接收一个扩展名为 `.pdf` 的本地路径，并与文件选择器共用同一导入、预检、恢复和持久化流程。
10. Windows 的窗口、安装项、卸载项、开始菜单和桌面快捷方式统一显示 `Satori`。安装器与卸载器使用带透明背景的多尺寸 ICO；CI 在当前用户范围静默安装后检查这些名称和快捷方式目标，静默卸载后还必须确认程序文件、安装目录、HKCU 卸载项、开始菜单和桌面快捷方式全部移除，再上传未签名 artifact。

## 影响

- Windows x64/ARM64 源码与打包支持可以独立演进，不改变 macOS Keychain、签名身份、开发壳或 `.app` 发布路径。
- Windows 构建目前没有 Authenticode 签名。SmartScreen 或来源提示属于已知分发边界，不能通过关闭系统保护来规避。
- GitHub Actions 通过、NSIS 生成和 payload 架构检查只证明构建产物。安装、启动、打开本地 PDF、翻页/缩放/框选、问答入口、持久化、任务栏、退出和卸载仍必须在指定 Windows 11 ARM64 实机环境逐项验收，并在不使用真实 API Key 的情况下保留安全证据。
