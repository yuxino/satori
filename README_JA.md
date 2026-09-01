<div align="center">
  <img src="src-tauri/icons/128x128@2x.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>PDF の教科書を読み、分からないときだけ質問する。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` は日本語の「悟り」——理解し、物事の本質を見通す瞬間——に由来します。

macOS と Windows 11 向けのローカルファーストな PDF 学習アプリです。ページを表示したまま、必要なときだけ現在のページや選択範囲について質問できます。

## 機能

- 現在のページについて尋ねるか、段落・図・コードを選択して画像に基づく説明を求められます。テキスト、スキャン、混在 PDF に対応します。
- 単ページ・見開き表示、目次移動、ズームを利用でき、本を開くと前回の位置に戻ります。
- 読書活動と質問・回答を本ごとに保存し、回答から元のページを開き直せます。
- Model Studio、OpenAI、カスタムの OpenAI 互換画像モデルを明示的に選択できます。
- AI を設定しなくても読書と本棚の管理ができます。

## ダウンロード

Satori は Windows 11 x64・ARM64 と、Apple シリコン搭載 Mac の macOS 14+ に対応します。Satori 3.4.2 は [GitHub Releases](https://github.com/yuxino/satori/releases/latest) からダウンロードできます。

- **Windows**：アーキテクチャに合う NSIS インストーラーを使用してください。現在のユーザーだけにインストールされます。Authenticode 署名がないため、発行元不明の警告が表示されます。ネイティブ操作の検証はアーキテクチャごとに扱い、x64-on-x64 の手動検証完了はまだ主張しません。
- **macOS**：ZIP を展開して Satori を「アプリケーション」に移動してください。ローカル署名はありますが公証されていないため、初回は Control キーを押しながら Satori をクリックし、「開く」を選びます。

更新は手動でダウンロードしてインストールします。表示言語は現在、簡体字中国語のみです。AI なしでも読書でき、質問とスキャン目次の認識には画像入力対応の OpenAI 互換モデルが必要です。

## 開発

Node.js 22.13+、安定版 Rust、各プラットフォームの [Tauri 前提環境](https://v2.tauri.app/start/prerequisites/) が必要です。macOS での開発には安定したコード署名 ID も必要です。

```bash
npm install
# macOS
npm run app
# Windows
npm run tauri -- dev
```

## プライバシー

PDF は元のローカル保存場所に残ります。本棚データと質問・回答は macOS では Application Support、Windows ではアプリの LocalAppData に保存され、API Key は macOS Keychain または Windows 資格情報マネージャーにのみ保存されます。明示的な質問、説明要求、目次認識の確定後に限り、関連ページの画像が選択中の AI サービスへ送られます。本を開くだけでは AI に接続しません。起動時の更新確認が GitHub Releases へ送るのはアプリのバージョンだけで、書籍、履歴、AI 設定、Key は含まれません。

[MIT](LICENSE) © 2026 yuxino
