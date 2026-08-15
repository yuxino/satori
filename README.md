<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>Understanding-first PDF reading space for macOS</p>
  <p>
    <a href="README_ZH.md">简体中文</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` comes from the Japanese word 悟り (satori, "enlightenment") — the moment of understanding.

Satori is a local-first macOS app for actually understanding PDF textbooks. Open a book and read the page full-screen; when a passage doesn't click, frame it and a patient teacher explains it in plain language, then steps away so you can keep reading.

## What it does

- **Open and read** — continuous scrolling PDF reader; text-native and scanned books both work (no OCR setup needed).
- **Ask about anything on the page** — frame a paragraph, a diagram, or a code block and get a plain-language explanation grounded in that page.
- **A teacher that talks like a person** — short answers, main point first, jargon mapped to plain terms; follow up with "explain more", "give an example", or "say it differently".
- **Remembers your place** — reading position and Q&A history stay on your Mac; reopen and pick up where you left off.

## Get started

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

Books, reading position, and Q&A history stay local. To get explanations, Satori calls Alibaba Cloud Model Studio (Qwen) on demand with the page image; responses are not stored by the provider.

[MIT](LICENSE) © 2026 yuxino
