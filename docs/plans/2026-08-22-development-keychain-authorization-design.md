# 开发构建 Keychain 授权治理设计

日期：2026-08-22

## 问题

Satori 开发包使用本地自签证书。它的 bundle ID 与 designated requirement 可以保持稳定，但签名没有 Apple Team ID。现代 macOS 会在传统 file-based Keychain ACL 之外增加 `partition_id`；没有 Team ID 时，partition 只能记录当前二进制的 CDHash。前端或 Rust 代码重建后 CDHash 改变，启动时读取 API Key 就会再次弹出授权。

问题被现有调用链放大：应用启动会解密当前连接的 Key，打开设置又会并发解密所有连接，扫描目录的后台请求也可能触发系统界面。一次构建因此可能连续出现多个授权窗口。

## 方案比较

1. 使用明文开发 Key、允许所有应用访问，或让 `/usr/bin/security` 代读。实现简单，但同一用户下的其他进程也能取得凭据，不符合项目安全规则，不采用。
2. 只给 `.app` 使用稳定本地证书。它能稳定传统 ACL，却不能稳定没有 Team ID 的 Keychain partition；跨重建仍会弹，不足以解决。
3. 拆分“是否保存”和“读取明文”，把系统交互限制到用户主动动作；同时优先使用带 Team ID 的 Apple 签名。此方案不放宽凭据权限，在所有开发环境都能消除启动和设置页的连环弹窗，并在 Apple Team 构建中实现跨重建零弹窗，采用。

## 设计

- `credential_status` 只按 service/account 做 existence-only `SecItemCopyMatching`。查询不返回属性、引用或数据，因此不评估 decrypt ACL。
- API Key 只在用户主动提问、测试连接、保存或删除时允许 macOS 显示授权。扫描目录等后台工作关闭 Keychain user interaction；若 Key 尚未进入会话缓存，后台任务安全失败而不是弹窗。
- 第一次成功读取后，Key 只缓存在 Rust 进程内，并按 profile ID、provider/endpoint/auth scope 与凭据 generation 绑定。跨进程保存或删除、切换 scope、退出进程都会使缓存失效；Key 不进入 WebView、JSON、日志或环境变量。
- 用非敏感 scope/generation sidecar 记录最后一次成功读取或保存的范围与版本；generation 同时封装在 Keychain 凭据内，多实例通过本地锁串行更新。设置页可以在不解密 Key 的情况下识别已知 scope 变化；旧条目没有 sidecar 时仍按“已保存、使用时验证”展示。
- 开发入口统一为 `npm run app`。脚本只自动选择唯一的 `Apple Development` 身份；多个开发身份或发布用 `Developer ID Application` 都要求通过 `SATORI_CODESIGN_IDENTITY` 显式指定。签名后验证 bundle ID、签名有效性和 Team ID。
- 只有本地自签证书时继续允许开发，但明确提示：打开应用和查看连接状态保持静默；任何改变 CDHash 的前端或 Rust 重建后，每个已保存 profile 在首次主动使用 AI 时仍可能需要一次授权。安装带 Team ID 的 Apple 开发证书后，Keychain 可按稳定 `teamid` 授权。

## 验证

- 用临时非敏感 Keychain 条目证明：返回 attributes 的查询在新 CDHash 下仍触发 partition；不返回任何内容、只检查 OSStatus 的查询可在禁用交互时跨 CDHash 成功。
- 生成两个不同 CDHash 的正式 `satori-dev.app`。最终构建启动、打开设置均没有 `SecurityAgent`，对应时间范围的 securityd 日志没有 `ACL partition mismatch`、XARA 询问或 Keychain prompt。
- 不点击测试连接、不发起 AI 请求，验证过程没有读取、显示或发送真实 API Key。
- 前端构建、Rust 单测、Clippy、脚本语法与格式检查全部作为提交门禁。
