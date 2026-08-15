<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>PDF を読んでいて分からないところを選ぶと、AI が説明してくれます。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` は日本語の「悟り」——理解し、物事の本質を見通す瞬間——に由来します。

PDF の教科書を読むための macOS アプリです。本を開けば全画面で読書。分からない段落・図・コードを選ぶと、その部分の説明が返ります。

- 文字 PDF とスキャン PDF の両方に対応。
- 読書位置と過去の質疑はすべて Mac 内に保存。

macOS 14+ が必要です。

```bash
npm install
npx tauri dev
```

本と履歴はすべてローカルに保存されます。説明は Alibaba Cloud Model Studio（Qwen）が現在のページ画像からオンデマンドで生成します。

[MIT](LICENSE) © 2026 yuxino
