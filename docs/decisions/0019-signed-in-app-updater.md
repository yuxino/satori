# 0019 · 签名应用内更新与 bootstrap 发布

日期：2026-09-02 · 状态：已采纳

## 背景

3.4.3 及更早版本只检查 GitHub 最新 Release，再把用户带到浏览器手动下载。它们没有内置 updater 公钥，也不会读取 `latest.json`，因此不能安全地原位安装后续版本。仅替换按钮文案会绕过产物签名、架构匹配和平台安装限制。

## 决策

1. 3.4.4 起只使用官方 `tauri-plugin-updater` / `@tauri-apps/plugin-updater` 检查、下载、验证和安装，使用官方 process plugin 在 macOS 安装完成后重启。不保留自定义下载、签名验证或安装降级路径。
2. 原生配置只信任 `https://github.com/yuxino/satori/releases/latest/download/latest.json`，生产环境不允许明文传输。应用内置 updater 公钥；私钥绝不进入仓库、构建日志或普通配置，只存在仓库外的加密恢复副本和 GitHub Actions Secret，密码另存系统安全凭据存储与独立 Secret。
3. Capability 只允许 updater 的 check、download、install 和 process restart。应用不使用组合式 `downloadAndInstall`；检查、下载和安装是三个可观察阶段，其中下载与安装都必须由用户明确触发。
4. 启动时仍可进行一次不含学习内容的元数据检查，但不会后台下载、轮询或静默安装。设置页保留手动检查；发现更新后显示版本和 Release notes，再由用户点击下载。下载有 Content-Length 时显示真实字节与百分比，无总量时显示不定进度；框架返回下载成功前只显示“正在验证签名”，不能提前出现安装入口。
5. 官方 updater 当前不提供下载中的安全中止 API，因此下载进行中不显示虚假的取消能力。用户可以在开始下载前或签名验证完成后取消并释放本次 updater 资源；网络、签名和安装错误可重试。GitHub Releases 只在错误状态提供恢复入口。
6. macOS 下载、验签、安装后停在“重启并完成”，只有再次明确点击才调用 process relaunch。Windows 使用可见的 `basicUi` 安装器；点击“安装并退出”后，Tauri 按 Windows 安装器限制自动退出 Satori，并由系统安装器继续，界面不承诺返回应用内的重启完成态。
7. `bundle.createUpdaterArtifacts` 使用 Tauri 2 格式：macOS 发布 `Satori.app.tar.gz` 与 `.sig`，Windows x64 / ARM64 分别发布 NSIS `.exe` 与 `.sig`。静态 `latest.json` 必须包含且只包含 `darwin-aarch64`、`windows-x86_64` 和 `windows-aarch64`，每项内嵌签名内容并指向唯一、架构准确的 HTTPS Release asset。
8. 发布仍是显式操作：本机从精确最终源码用既有稳定 macOS 身份打包并把经过验证的 macOS 资产放入 draft Release；发布工作流复用 Windows 双架构托管验证，校验精确 main SHA、tag/版本一致性、唯一文件名、`.sig`、PE 架构、安装/完整卸载和 SHA-256，再生成 `latest.json` 并公开 Release。普通 main push 与单独 Windows workflow 都不发布。
9. 3.4.4 是 bootstrap Release。3.4.3 及更早的公开安装无法发现或安装 updater manifest，必须手动下载安装 3.4.4 一次；3.4.4 之后才可在应用内更新。README 和 3.4.4 Release notes 必须明确这条迁移边界。
10. updater 私钥丢失后，已安装版本将无法信任新的更新，不能通过关闭签名校验恢复。轮换必须先发布一个仍由旧私钥签名、同时内置新公钥的桥接版本，并保留旧私钥直至迁移完成。

## 影响

- “下载完成”现在表示官方框架已经完成传输和 updater 签名验证，不再等同于浏览器已打开或文件存在。
- updater 签名证明更新产物与应用内公钥匹配，不替代 Apple Developer ID / notarization 或 Windows Authenticode；公开下载仍需如实说明操作系统信任提示。
- CI 构建、产物签名、安装/卸载和真实原生交互仍是不同证据。未经对应机器操作，不能把工作流成功描述成 Windows 或 macOS 的完整原生更新验收。
