# 0018 · Windows 发布提升边界

日期：2026-08-30 · 状态：已采纳

## 背景

ADR 0017 把 Windows 构建限定为手动触发、只上传短期 artifact 的验证工作流，避免普通 push 自动公开未检查的 unsigned 安装包。x64 与 ARM64 的托管构建、安装和卸载检查已经通过；ARM64 还完成了 Windows 11 25H2 的安装与核心交互验收，但原生卸载和 x64 手动交互仍未完成。

## 决策

1. Windows 工作流继续保持 `workflow_dispatch` 和 artifact-only；它不创建 tag、Release，也不修改已有 Release。
2. 只有收到明确发布授权后，主机才可把精确 main SHA 的成功工作流 artifact 提升到同版本 GitHub Release。提升前必须复核安装包数量与精确名称、唯一应用 payload、PE machine、产品身份、托管安装/卸载结果和 SHA-256。
3. Release 必须同时保留 `Satori_<version>_x64-setup.exe` 与 `Satori_<version>_arm64-setup.exe` 的官方文件名，并附带独立的 `SHA256SUMS`。架构不能合并或改名，否则应用无法按当前平台准确识别更新。
4. Windows 安装包保持 unsigned、current-user。Release 与 README 必须明确未知发布者、各架构原生验收范围及未完成项；不能把托管 CI 描述成手动交互证据，也不能建议关闭 Windows 安全保护。
5. Windows 公开下载不引入应用内安装。应用仍只提示匹配的正式 Release，并打开固定的 GitHub Releases 页面，由用户手动下载和替换。

## 影响

- 普通提交不会自动发布 Windows 二进制；验证和公开分发仍是两个独立、可审计的步骤。
- ARM64 的原生交互证据可以支持公开预览边界，但 3.4.0 的精确安装包、ARM64 原生卸载和 x64 手动交互必须继续单独记录，不能由版本号或托管检查推断。
- 未来加入 Authenticode、自动更新或更广泛的设备支持时，需要新的发布决策和对应原生证据。
