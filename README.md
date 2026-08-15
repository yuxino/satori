<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>Select what you don't understand in a PDF and get an explanation based on that page.</p>
  <p>
    <a href="README_ZH.md">简体中文</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` comes from the Japanese word 悟り (satori, "enlightenment").

A macOS app for reading PDF textbooks. Open a book, read full-screen, and when a paragraph, figure, or code block doesn't make sense — select it and get an explanation of that part.

- Works with text-native and scanned PDFs.
- Reading position and past Q&A are saved on your Mac.

Requires macOS 14+.

```bash
npm install
npx tauri dev
```

Books and history stay on your Mac. Explanations are generated on demand by Alibaba Cloud Model Studio (Qwen) from the current page image.

[MIT](LICENSE) © 2026 yuxino
