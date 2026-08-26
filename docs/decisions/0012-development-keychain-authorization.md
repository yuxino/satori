# 0012 · 开发构建不主动解密 Keychain 凭据

日期：2026-08-22 · 状态：已采纳

## 背景

早期本地签名方案认为同一个自签身份足以让钥匙串授权跨重建保留。实测表明这只覆盖传统 designated requirement：本地自签证书没有 Apple Team ID，macOS Keychain 的额外 partition 会退化为每次构建的精确 CDHash。重建后在启动路径解密 Key，仍会重新弹出授权。

## 决策

1. 启动、设置页和连接状态刷新只检查 Keychain 条目是否存在，不返回属性、引用或明文数据。
2. 只有用户主动提问、测试连接、保存或删除凭据时允许系统授权。自动目录恢复等后台调用禁止 Keychain 交互。
3. 成功读取的 Key 在 Rust 进程内按 profile、credential scope 与 generation 缓存；generation 同时写入 Keychain envelope 与非敏感 sidecar，多实例通过 Application Support 锁串行更新。跨进程保存、scope 变化和删除立即失效，退出进程自然清空。
4. 开发启动脚本只自动选择唯一的 Apple Development 身份或长期保留的 `mimi Local Development` 本机身份，并验证签名结果；多个开发身份时要求显式选择，Developer ID 发布身份也只能显式选择。真实开发 App 禁止退回 ad-hoc 签名。本机自签身份必须明确提示 Keychain partition 的限制，不得声称钥匙串授权可跨原生重建完全稳定。
5. 不使用明文开发 Key、环境变量 Key、allow-all ACL、宽松 partition 或 `/usr/bin/security` 代读。
6. 开发 `.app` 使用 feature-gated 的磁盘资源处理器读取仓库 `dist/`。启动脚本对原生输入和签名身份做指纹，仅在它们变化时重建签名壳；前端变化不再改变 CDHash。发布构建不包含这一处理器，继续使用内嵌资源。

## 影响

- 日常启动、视觉调试、打开设置和后台扫描不再弹钥匙串授权。
- 仅有本地自签证书时，前端改动复用稳定签名壳，不再触发授权；Rust、原生配置或签名变化后，每个已保存 profile 在首次主动使用 AI 时仍可能需要一次授权。同一运行期后续请求从安全的进程缓存读取。
- 带 Team ID 的 Apple 签名可以让授权跨重建稳定。切换签名身份后，旧条目可能需要最后一次“始终允许”或重新保存。
- 缺少稳定身份时开发启动直接失败，不再用 ad-hoc 包触发钥匙串或其他 macOS 授权；这项规则与其他本机 macOS App 共用。
- 本决策修正普通本地自签身份可跨重建保留授权的旧结论，但继续保留“API Key 只存 macOS Keychain”的要求。
