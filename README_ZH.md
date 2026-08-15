<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>本地优先的 macOS PDF 阅读器，带 AI 解释</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` 来自日语「悟り」——理解、看清事物本质的瞬间。

Satori 是一个 macOS 应用，用来读 PDF 教材。打开书就是全屏阅读；遇到看不懂的地方，选中它，Satori 会基于当前这一页给出解释。

## 功能

- **PDF 阅读**：连续滚动阅读，文字版和扫描版都能用。
- **解释页面内容**：选中一段话、一张图或一段代码，得到基于这一页的解释。
- **阅读历史**：阅读位置和过往问答都保存在本机。

## 开始使用

需要 macOS 14+。

```bash
npm install
npx tauri dev
```

构建应用：

```bash
npx tauri build
```

## 隐私

书、阅读位置和问答记录都保存在本机。解释由阿里云百炼（Qwen）按需生成，只使用当前页图像，服务端不保存对话内容。

[MIT](LICENSE) © 2026 yuxino
