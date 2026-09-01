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

A local-first PDF learning app for macOS and Windows 11. Keep the page in view and ask about the current page or a selected region only when you need help.

## Features

- Ask about the current page or drag over a paragraph, figure, or code block for a visual explanation. Text, scanned, and mixed PDFs are supported.
- Read in single- or two-page view with outline navigation and zoom; each book reopens where you left it.
- Keep reading activity and Q&A organized per book, with links back to the source page.
- Choose among Model Studio, OpenAI, and custom OpenAI-compatible visual models.
- Read and manage the library without configuring AI.

## Download

Satori supports Windows 11 on x64 and ARM64, and macOS 14+ on Apple silicon. Download Windows 3.4.1 from [GitHub Releases](https://github.com/yuxino/satori/releases/latest), or the current macOS build from [version 3.4.0](https://github.com/yuxino/satori/releases/tag/v3.4.0).

- **Windows:** choose the NSIS installer matching your architecture. It installs for the current user. The installers are not Authenticode-signed, so Windows shows an unknown publisher warning. Interactive validation is architecture-specific; x64-on-x64 manual acceptance is not yet claimed.
- **macOS:** unzip the download and move Satori to Applications. The build has a local signature but is not notarized; on first launch, Control-click Satori and choose **Open**.

Updates are downloaded and installed manually. The interface is currently available in Simplified Chinese only. Reading works without AI; questions and scanned-outline recognition require an image-capable OpenAI-compatible model.

## Development

Install Node.js 22.13+, stable Rust, and the platform-specific [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/). macOS development also requires a stable code-signing identity.

```bash
npm install
# macOS
npm run app
# Windows
npm run tauri -- dev
```

## Privacy

PDFs remain at their original paths. Library data and Q&A stay in Application Support on macOS or application LocalAppData on Windows; API keys stay in macOS Keychain or Windows Credential Manager. Page images are sent to the selected AI service only after an explicit question, explanation request, or confirmed outline scan. Opening a book does not contact an AI service. The launch-time update check sends only the app version to GitHub Releases, never book content, history, AI profiles, or keys.

[MIT](LICENSE) © 2026 yuxino
