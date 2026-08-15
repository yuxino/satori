<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>理解を中心にした macOS 用 PDF 読書スペース</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` は日本語の「悟り」——理解し、物事の本質を見通す瞬間——に由来します。

Satori は PDF の教科書を本当に理解するための、ローカルファーストな macOS アプリです。本を開けば全画面で読書。分からない箇所を枠で囲むと、気の利いた先生がやさしい言葉で説明し、話し終えたらあなたの読書に戻ります。

## できること

- **そのまま読める**：連続スクロールの PDF リーダー。文字 PDF・スキャン PDF の両方に対応（OCR 設定は不要）。
- **囲んで質問**：段落・図・コードを枠で囲むと、そのページに基づいた平易な説明が返ります。
- **人が話すような先生**：短く、要点から、専門用語はわかりやすい言葉に。続けて「もっと詳しく」「例を挙げて」「別の言い方で」と聞けます。
- **読書位置を記憶**：読書位置と質疑履歴はすべて Mac 内に保存。再開すれば続きから。

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

本・読書位置・質疑履歴はすべてローカルに保存されます。説明は Alibaba Cloud Model Studio（Qwen）に現在のページ画像だけを送ってオンデマンドで生成され、プロバイダ側に会話内容は保存されません。

[MIT](LICENSE) © 2026 yuxino
