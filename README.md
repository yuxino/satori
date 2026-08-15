<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>Local-first PDF reader with AI explanations for macOS</p>
  <p>
    <a href="README_ZH.md">简体中文</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` comes from the Japanese word 悟り (satori, "enlightenment").

Satori is a macOS app for reading PDF textbooks. You read the page full-screen; when something doesn't make sense, select it and Satori explains that part based on the page you're looking at.

## Features

- **PDF reading** — continuous scrolling; works with text-native and scanned PDFs.
- **Explain anything on the page** — select a paragraph, figure, or code block and get an explanation based on that page.
- **Reading history** — reading position and past Q&A are saved on your Mac.

## Getting started

Requires macOS 14+.

```bash
npm install
npx tauri dev
```

Build the app:

```bash
npx tauri build
```

## Privacy

Books, reading position, and Q&A history stay on your Mac. Explanations are generated on demand by Alibaba Cloud Model Studio (Qwen) using the current page image; responses are not stored by the provider.

[MIT](LICENSE) © 2026 yuxino
