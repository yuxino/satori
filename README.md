<div align="center">
  <img src="src-tauri/icons/128x128@2x.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>Read PDF textbooks. Ask only when something does not click.</p>
  <p>
    <a href="README_ZH.md">简体中文</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` comes from the Japanese word 悟り (satori, "enlightenment").

A macOS app for reading PDF textbooks. The page stays at the center; when a paragraph, figure, or code block does not make sense, select it and ask, or open the page-side question panel.

## Features

- **Ask around the page** — select a paragraph, figure, or code block, or type your own question; works with both text-native and scanned PDFs.
- **Reading first** — single-page and two-page layouts, outline navigation, and zoom all stay out of the page's way; each book reopens where you left it.
- **A refined monochrome home** — calm editorial spacing keeps your current book, yearly reading grid, library, and recent Q&A together; crisp typographic covers replace blurry PDF thumbnails.
- **Choose your AI service** — keep multiple Alibaba Cloud Model Studio, OpenAI, or OpenAI-compatible cloud and local connections, then switch the active connection and model at any time.
- **Stored locally** — your library, reading position, and past Q&A stay on your Mac; API keys are stored only in macOS Keychain.

## Download

Requires macOS 14+ and an Apple silicon Mac. Download the latest build from [GitHub Releases](https://github.com/yuxino/satori/releases/latest).

The published v3.3.1 build predates the explicit page-transmission controls in the current source. Do not use v3.3.1 with sensitive PDFs. Until a newer release is available, run the current source with Node.js 22.13+, Rust, and a stable macOS code-signing identity (Apple Development or a long-lived self-signed identity):

```bash
npm install
npm run app
```

The published build is not Apple-notarized. If you still test it, Control-click Satori, choose **Open**, then confirm once.

Open Settings and add an AI service connection before asking a question.

## Privacy

In the current source, books and history stay on your Mac. Relevant page images are sent to the active AI service only after you submit a question, complete an explicit region selection, or choose the outline-recognition action after its page range is disclosed; opening the question panel alone does not make a request.

[MIT](LICENSE) © 2026 yuxino
