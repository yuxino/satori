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

A local-first app for understanding PDF textbooks. The current source targets macOS and Windows 11: open a local PDF, keep the page in view, and ask about the current page or a region when you get stuck. Native Windows acceptance is still pending.

## Features

- **Ask from the page** — type a question about the current page, or drag over a paragraph, figure, or code block for a visual explanation; text, scanned, and mixed PDFs are supported.
- **Reading first** — single-page and two-page views, outline navigation, and zoom stay focused on the page; each book reopens where you left it.
- **Keep each book's context** — reading activity and per-book Q&A stay together, and saved answers reopen their source page.
- **Use your own visual AI** — save multiple Model Studio, OpenAI, or custom OpenAI-compatible connections and choose the active model.
- **Stored locally** — source PDFs remain in place; library data, reading state, and past Q&A stay on this computer, while API keys are stored only in macOS Keychain or Windows Credential Manager.

## Download

The current published download is macOS-only. It requires macOS 14+ and an Apple silicon Mac. Download the ZIP from [GitHub Releases](https://github.com/yuxino/satori/releases/latest), unzip it, and drag Satori to Applications.

The current source targets macOS and Windows 11. Use Node.js 22.13+, Rust, and the platform build tools; macOS development also requires a stable code-signing identity (Apple Development or a long-lived self-signed identity). After installing dependencies, run `npm run app` on macOS or `npm run tauri -- dev` on Windows:

```bash
npm install
# macOS
npm run app
# Windows
npm run tauri -- dev
```

The current public macOS download has a local code signature but no Apple Team ID, and it is not notarized. On first launch, Control-click Satori, choose **Open**, then confirm once. Updates are downloaded and replaced manually from the official Releases page.

The manual Windows workflow builds unsigned x64 and ARM64 NSIS development packages. They are not currently published in GitHub Releases and are not signed Windows downloads.

The interface is currently Simplified Chinese. Reading works without AI; to ask questions or recognize a missing scanned outline, open Settings and add a model that accepts image input through OpenAI-compatible Chat Completions.

## Privacy

Source PDFs stay at their original local paths; library metadata, reading state, and per-book Q&A are stored in Application Support on macOS or application LocalAppData on Windows, and API keys only in macOS Keychain or Windows Credential Manager. Relevant page images are sent to the active AI service only when you submit a question, request a page or region explanation, or confirm outline recognition after its page ranges and image counts are shown; follow-ups may include up to six recent text-only turns. Opening a book or the question panel does not send page content to an AI service. After launch, Satori checks GitHub Releases once for a package matching the current platform, using its current version without including PDF content, reading history, AI profiles, or keys.

[MIT](LICENSE) © 2026 yuxino
