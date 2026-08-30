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
5. 工作流必须验证 runner 架构、唯一且名称精确的安装器，并解包 NSIS，确认其中的 `satori.exe` 与已检查的构建二进制 SHA-256 相同。x64 payload 的 PE Machine 必须为 `0x8664`，ARM64 payload 必须为 `0xAA64`。NSIS 的 ARM64 安装器外壳本身仍是通过 Windows 模拟层运行的 x86 程序；原生架构承诺只针对安装器内的 Satori 应用。
6. 更新检查按当前平台匹配 Release asset。没有匹配的 Windows 安装器时，Windows 端不能声称有可下载更新，但仍可打开固定的官方 Releases 页面。当前已发布的 Release 仍只有 macOS 下载；Windows 工作流 artifact 不等同于公开发布。

## 影响

- Windows x64/ARM64 源码与打包支持可以独立演进，不改变 macOS Keychain、签名身份、开发壳或 `.app` 发布路径。
- Windows 构建目前没有 Authenticode 签名。SmartScreen 或来源提示属于已知分发边界，不能通过关闭系统保护来规避。
- GitHub Actions 通过、NSIS 生成和 payload 架构检查只证明构建产物。安装、启动、打开本地 PDF、翻页/缩放/框选、问答入口、持久化、任务栏、退出和卸载仍必须在指定 Windows 11 ARM64 实机环境逐项验收，并在不使用真实 API Key 的情况下保留安全证据。
