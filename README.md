<div align="center">
  <img src="src-tauri/icons/128x128@2x.png" width="128" height="128" alt="Satori cat-ear-hood character">
  <h1>Satori</h1>
  <p><a href="https://satori.yuxino.cn">Website · satori.yuxino.cn</a></p>
  <p>Read a PDF. Select a passage, figure, or code block and ask about it.</p>
  <p>
    <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` means “enlightenment” in Japanese.

A local-first PDF learning app for macOS and Windows 11. Ask AI about the current page or a selected region, then compare the explanation with the source. Your reading progress and Q&A are saved locally for each book.

<!-- project-demo-v1 -->
## Demo

<p align="center">
  <a href="docs/demos/demo.mp4"><img src="docs/demos/preview.gif" alt="Satori"></a>
</p>
<p align="center">Read a PDF, ask a question, follow up, and revisit the conversation.</p>
<p align="center"><a href="docs/demos/demo.mp4">Watch video</a></p>
<!-- /project-demo-v1 -->

## Features

- Ask about the current page or drag over a paragraph, figure, or code block for a visual explanation. Text, scanned, and mixed PDFs are supported.
- Read in single- or two-page view with outline navigation and zoom; each book reopens where you left it.
- Keep reading activity and Q&A organized per book, with links back to the source page.
- Choose among Alibaba Cloud Model Studio, OpenAI, and custom OpenAI-compatible visual models.
- Check for a signed update in Settings, review its notes, then explicitly download, verify, and install it.
- Read and manage the library without configuring AI.

## Download

Satori supports Windows 11 on x64 and ARM64, and macOS 14+ on Apple silicon. Download Satori 3.4.6 from [GitHub Releases](https://github.com/yuxino/satori/releases/latest).

- **Windows:** choose the NSIS installer matching your architecture. It installs for the current user. The installers are not Authenticode-signed, so Windows shows an unknown publisher warning. Interactive validation is architecture-specific; x64-on-x64 manual acceptance is not yet claimed.
- **macOS:** unzip the download and move Satori to Applications. The build has a local signature but is not notarized; on first launch, Control-click Satori and choose **Open**.

Version 3.4.4 introduced the updater: anyone using 3.4.3 or earlier must manually install the current release once from GitHub Releases. From 3.4.4 onward, Settings can download and verify later signed releases before an explicit install. Satori never downloads or installs an update in the background. On macOS, the learner clicks **Restart and finish** after installation; on Windows, starting installation closes Satori, shows update progress, and reopens the app when finished.

The interface is currently available in Simplified Chinese only. Reading works without AI; questions and scanned-outline recognition require an image-capable OpenAI-compatible model. Satori is free and open source; your chosen AI service may charge separately.

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

PDFs remain at their original paths. Library data and Q&A stay in Application Support on macOS or application LocalAppData on Windows; API keys stay in macOS Keychain or Windows Credential Manager. Page images are sent to the selected AI service only after an explicit question, explanation request, or confirmed outline scan. Opening a book does not contact an AI service. The launch-time update check fetches only the static updater manifest from GitHub Releases; it never sends book content, history, AI profiles, or keys.

[MIT](LICENSE) © 2026 yuxino
