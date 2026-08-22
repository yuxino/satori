<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
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
- **自选 AI 服务**：可以同时配置多份阿里云百炼、OpenAI 或 OpenAI-compatible 云端与本地服务，并随时切换当前连接和模型。
- **本地保存**：书库、阅读位置和过往问答保存在 Mac 上；API Key 只存入 macOS 钥匙串。

## 开始使用

需要 macOS 14+。

```bash
npm install
npm run app
```

打开设置，添加一个 AI 服务连接后即可提问。

## 隐私

书和阅读历史都存在本机。只有在你发送问题或明确选择「讲讲这一页」后，相关书页图像才会发送给当前使用的 AI 服务；仅仅打开「问书」面板不会发起请求。

[MIT](LICENSE) © 2026 yuxino
