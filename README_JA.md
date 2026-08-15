<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>ローカルファーストな macOS 用 PDF リーダー（AI 解説付き）</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` は日本語の「悟り」——理解し、物事の本質を見通す瞬間——に由来します。

Satori は PDF の教科書を読むための macOS アプリです。本を開けば全画面で読書。分からない箇所を選ぶと、現在のページに基づいて説明を返します。

## 機能

- **PDF 読書**：連続スクロール。文字 PDF とスキャン PDF の両方に対応。
- **ページ内を説明**：段落・図・コードを選択すると、そのページに基づいた解説が返ります。
- **読書履歴**：読書位置と過去の質疑はすべて Mac 内に保存。

## はじめに

macOS 14+ が必要です。

```bash
npm install
npx tauri dev
```

アプリをビルドする場合：

```bash
npx tauri build
```

## プライバシー

本・読書位置・質疑履歴はすべてローカルに保存されます。解説は Alibaba Cloud Model Studio（Qwen）が現在のページ画像を使ってオンデマンドで生成し、プロバイダ側に会話内容は保存されません。

[MIT](LICENSE) © 2026 yuxino
