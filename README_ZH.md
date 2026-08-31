<div align="center">
  <img src="src-tauri/icons/128x128@2x.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>读 PDF 教材，卡住时再问一句。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` 来自日语「悟り」——理解、看清事物本质的瞬间。

一个在 macOS 和 Windows 11 上理解 PDF 教材的本地优先应用。打开本地 PDF，书页始终留在视野中央；卡住时，再问当前页或框选区域。

## 功能

- **围着书页提问**：询问当前页，或在段落、图和代码上拖出一个区域，让模型结合画面解释；文字版、扫描版和混合 PDF 都能用。
- **阅读优先**：单页或双页、目录跳转和缩放都围绕书页展开，打开一本书会回到上次的位置。
- **保留每本书的上下文**：阅读活动和逐书问答放在一起，保存的回答可以回到来源页重看。
- **使用自己的视觉 AI**：保存多份百炼、OpenAI 或自定义 OpenAI 兼容连接，并明确选择当前模型。
- **本地保存**：源 PDF 留在原位置；书架数据、阅读状态和过往问答保存在这台电脑上，API Key 只存入 macOS 钥匙串或 Windows 凭据管理器。

## 下载

3.4.1 版在 [GitHub Releases](https://github.com/yuxino/satori/releases/latest) 提供 Windows 11 x64 与 ARM64 安装包；Apple 芯片 Mac 上的 macOS 14+ 公开下载仍为 [3.4.0 版](https://github.com/yuxino/satori/releases/tag/v3.4.0)。macOS 请从该 Release 下载 ZIP，解压后把 Satori 拖入「应用程序」；Windows 请下载与处理器架构匹配的 NSIS 安装包。

当前源码面向 macOS 和 Windows 11。请准备 Node.js 22.13+、Rust 和对应平台的构建工具；macOS 开发还需要稳定的代码签名身份（Apple Development 或长期自签身份）。安装依赖后，在 macOS 运行 `npm run app`，在 Windows 运行 `npm run tauri -- dev`：

```bash
npm install
# macOS
npm run app
# Windows
npm run tauri -- dev
```

当前公开的 macOS 下载包使用本地代码签名，但没有 Apple Team ID，也未经过 Apple 公证。首次启动时，请按住 Control 点击 Satori，选择「打开」，再确认一次。更新需要从官方 Releases 页面手动下载并替换。

Windows x64 和 ARM64 NSIS 安装包均未签名，并按当前用户安装，因此 Windows 会把发布者显示为未知。3.4.1 只会从最终源码精确提交的产物提升，并先通过托管构建、打包、当前用户安装/卸载和哈希校验。原生交互证据仍按架构分别记录，不宣称已经完成 x64-on-x64 手动验收。

应用界面目前只有简体中文。无需配置 AI 也能阅读；如需提问或识别扫描 PDF 缺失的目录，请在设置中添加一个兼容 OpenAI Chat Completions 且能接收图片的模型。

## 隐私

源 PDF 保留在本机原位置；书架元数据、阅读状态和逐书问答在 macOS 保存到 Application Support，在 Windows 保存到应用 LocalAppData，API Key 只存入 macOS 钥匙串或 Windows 凭据管理器。只有发送问题、请求解释书页或选区，或在看到页码范围和图片张数后确认目录识别时，相关书页图像才会发送给当前 AI 服务；追问可能附带最多 6 个近期纯文本轮次。打开书或「问书」面板不会把书页内容发送给 AI 服务。启动后，Satori 会使用当前版本向 GitHub Releases 检查一次与当前平台匹配的安装包；请求不包含 PDF 内容、阅读历史、AI 配置或密钥。

[MIT](LICENSE) © 2026 yuxino
