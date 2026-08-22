# 0012 · 开发构建不主动解密 Keychain 凭据

日期：2026-08-22 · 状态：已采纳

## 背景

ADR 0005 认为同一个本地签名身份足以让钥匙串授权跨重建保留。实测表明这只覆盖传统 designated requirement：本地自签证书没有 Apple Team ID，macOS Keychain 的额外 partition 会退化为每次构建的精确 CDHash。重建后在启动路径解密 Key，仍会重新弹出授权。

## 决策

1. 启动、设置页和连接状态刷新只检查 Keychain 条目是否存在，不返回属性、引用或明文数据。
2. 只有用户主动提问、测试连接、保存或删除凭据时允许系统授权。自动目录恢复等后台调用禁止 Keychain 交互。
3. 成功读取的 Key 在 Rust 进程内按 profile、credential scope 与 generation 缓存；generation 同时写入 Keychain envelope 与非敏感 sidecar，多实例通过 Application Support 锁串行更新。跨进程保存、scope 变化和删除立即失效，退出进程自然清空。
4. 开发启动脚本只自动选择唯一的 Apple Development 身份，并验证签名结果；多个开发身份时要求显式选择，Developer ID 发布身份也只能显式选择。本地自签和 ad-hoc 构建必须明确提示其限制，不得声称授权可跨重建稳定。
5. 不使用明文开发 Key、环境变量 Key、allow-all ACL、宽松 partition 或 `/usr/bin/security` 代读。

## 影响

- 日常启动、视觉调试、打开设置和后台扫描不再弹钥匙串授权。
- 仅有本地自签证书时，任何改变 CDHash 的前端或 Rust 重建后，每个已保存 profile 在首次主动使用 AI 时仍可能需要一次授权；同一运行期后续请求从安全的进程缓存读取。
- 带 Team ID 的 Apple 签名可以让授权跨重建稳定。切换签名身份后，旧条目可能需要最后一次“始终允许”或重新保存。
- 本决策修正 ADR 0005 关于普通本地签名可跨重建保留授权的结论，但继续保留“API Key 只存 macOS Keychain”的要求。
