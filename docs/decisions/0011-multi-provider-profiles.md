# 0011 · 多 AI 服务配置档案

日期：2026-08-22 · 状态：已采纳

## 背景

Satori 3.0 的设置、钥匙串和视觉请求最初全部绑定阿里云百炼：一个 Key、一个模型和一个内置地址。这适合验证第一条阅读闭环，但不符合开源桌面软件应有的可选择性，也无法同时保留云端、本地或代理服务配置。

本决策取代 ADR 0002 中“单一 Qwen 服务”和“不显示自定义地址”的产品限制；百炼仍保留为默认、兼容旧安装的预设。

## 决策

1. Satori 保存多个命名的 `AIProfile`，每个档案包含稳定 ID、服务类型、非敏感 API 根地址、模型 ID 和是否需要密钥；`active_profile_id` 明确指定当前连接，不做静默回退。
2. 首批协议统一为支持图片输入与流式输出的 OpenAI-compatible Chat Completions。内置阿里云百炼、OpenAI 两个预设，并提供自定义兼容服务。Anthropic、Gemini 等原生协议等真实需求出现后再增加适配器。
3. 所有 API Key 按稳定 profile ID 分开存入 macOS Keychain。Keychain 条目同时封装由 Rust 计算的 credential scope（provider、规范化最终 Chat Completions URL、鉴权模式）；scope 不匹配视为未连接，防止旧 Key 被转发到新地址。前端只读取“是否已保存”，已保存 Key 不返回 WebView、不进入本地 JSON、日志、截图或环境变量。
4. 默认百炼档案使用确定性 ID。首次读取时只允许把旧 Qwen v3/v2 钥匙串条目或旧开发文件绑定到官方百炼 scope；验证新条目后删除旧明文文件。用户显式移除默认 Key 时，同时清理旧条目并在 Keychain 写删除标记，避免 Application Support 重置或多实例竞态让旧 Key 复活。
5. 预设服务地址由 Rust 强制使用内置值。自定义地址只允许 HTTPS，或指向 localhost/loopback 的 HTTP；拒绝凭据内嵌、query、fragment 与非 HTTP(S) scheme。兼容服务可以明确关闭鉴权，此时后端完全不读取或发送 Key。
6. 远程请求显式发送 `store: false`。页面图像仍是仅在一次请求中使用的临时证据，不落盘；本地问答历史继续与 provider 解耦。
7. 页面讲解、扫描目录提取和章节页定位必须使用同一个当前 profile，不能保留 Qwen 专用旁路。
8. AI IPC 命令只接受 profile ID；Rust 必须从持久化 Store 读取唯一档案，再解析地址与 credential scope。请求客户端不跟随 HTTP 重定向。Store 损坏、版本过新、profile ID 非法/重复或 active profile 丢失时必须停止加载，不能静默回退百炼或覆盖原数据。
9. “测试连接”使用内置的 1×1 测试图，只验证地址、鉴权、模型与图片输入能力，不发送书页或学习历史。

## 影响

- 正常升级时，旧用户的模型选择与 Key 无需重新填写，Store 迁移幂等；不安全或无法证明目标地址的旧凭据要求重新保存。
- 用户可以同时保存多个同类或不同类连接，切换只影响后续请求。
- “OpenAI compatible”不等于支持所有兼容实现；服务仍必须接受图片消息、Chat Completions 和 Satori 的 no-store 约束。
- 自定义远程地址意味着用户主动选择把本次书页图像发送到该域名，设置页必须清楚展示目标地址。
- 新增原生协议时扩展 Rust adapter，不修改学习记录或设置页的信息架构。
