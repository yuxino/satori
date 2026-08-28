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

一个用来读 PDF 教材的 macOS 应用。书页始终是主角；遇到看不懂的段落、图或代码，可以直接选中提问，也可以打开页边的「问书」面板。

## 功能

- **围着书页提问**：选中一段话、一张图或一段代码，也可以自己输入问题；文字版和扫描版都能用。
- **阅读优先**：单页或双页翻阅、目录跳转和缩放都围绕书页展开，打开一本书会回到上次的位置。
- **克制的黑白首页**：用安静的编辑式排版把当前书、年度学习格子、书架和最近问答放在一起；清晰的文字封面替代了模糊 PDF 缩略图。
- **自选 AI 服务**：可以同时配置多份阿里云百炼、OpenAI 或 OpenAI-compatible 云端与本地服务，并随时切换当前连接和模型。
- **本地保存**：书库、阅读位置和过往问答保存在 Mac 上；API Key 只存入 macOS 钥匙串。

## 下载

需要 macOS 14+ 和 Apple 芯片 Mac。请从 [GitHub Releases](https://github.com/yuxino/satori/releases/latest) 下载最新版本。

3.3.2 已包含下文所述的显式书页发送控制、服务地址校验、已修补的 PDF.js 和最小权限边界。如需自行运行当前源码，请使用 Node.js 22.13+、Rust 和稳定的 macOS 代码签名身份（Apple Development 或长期自签身份）：

```bash
npm install
npm run app
```

下载包使用项目稳定的本地身份签名，但尚未经过 Apple 公证。首次启动时，请按住 Control 点击 Satori，选择「打开」，再确认一次。

打开设置，添加一个 AI 服务连接后即可提问。

## 隐私

在当前源码中，书和阅读历史都存在本机。相关书页图像只会在你发送问题、完成明确的框选操作，或在看到发送页数后主动选择「识别目录」时发送给当前 AI 服务；仅仅打开「问书」面板不会发起请求。

[MIT](LICENSE) © 2026 yuxino
