<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>选中 PDF 里看不懂的部分，获得基于当前页的解释。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` 来自日语「悟り」——理解、看清事物本质的瞬间。

一个 macOS 应用，用来读 PDF 教材。打开书就是全屏阅读；遇到看不懂的段落、图或代码，选中它，就会得到针对这一部分的解释。

- 文字版和扫描版 PDF 都能读。
- 阅读位置和过往问答都保存在本机。

需要 macOS 14+。

```bash
npm install
npx tauri dev
```

书和阅读历史都存在本机。解释由阿里云百炼（Qwen）基于当前页图像按需生成。

[MIT](LICENSE) © 2026 yuxino
