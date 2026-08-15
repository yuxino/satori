<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>以理解为中心的 macOS PDF 阅读空间</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` 来自日语「悟り」——理解、看清事物本质的瞬间。

Satori 是一款本地优先的 macOS 应用，帮你真正读懂 PDF 教材。打开书就是全屏阅读；遇到看不懂的地方，框选它，一位耐心的老师用大白话讲给你听，讲完退开，你继续读。

## 它能做什么

- **打开就读**：连续滚动阅读，文字版、扫描版都能读，无需任何 OCR 设置。
- **框选即问**：框选一段话、一张图或一段代码，得到基于这一页的大白话解释。
- **讲人话的老师**：回答简短，先讲主线，再把术语对上；可以追问「再讲细一点」「举个例子」「换个说法」。
- **记住读到哪**：阅读位置和问答记录都保存在本机，重开书接着读。

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

书、阅读位置和问答记录都保存在本机。解释由阿里云百炼（Qwen）按需调用，只发送当前页图像，服务端不保存对话内容。

[MIT](LICENSE) © 2026 yuxino
