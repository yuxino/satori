<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>PDF の教科書を読み、分からないときだけ質問する。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_ZH.md">简体中文</a>
  </p>
</div>

`Satori` は日本語の「悟り」——理解し、物事の本質を見通す瞬間——に由来します。

PDF の教科書を読むための macOS アプリです。主役は常にページ。分からない段落・図・コードを選んで質問することも、ページ脇の質問パネルを開くこともできます。

## 機能

- **ページを中心に質問**：段落・図・コードを選ぶことも、自分で質問を入力することも可能。文字 PDF とスキャン PDF の両方に対応。
- **読書を優先**：単ページ・見開き表示、目次移動、ズームはページの邪魔をせず、本を開くと前回の位置に戻ります。
- **AI サービスを選択**：Alibaba Cloud Model Studio、OpenAI、OpenAI-compatible のクラウド・ローカル接続を複数保存し、使用する接続とモデルをいつでも切り替えられます。
- **ローカル保存**：本棚、読書位置、過去の質疑は Mac 内に保存。API Key は macOS Keychain にのみ保存されます。

## ダウンロード

macOS 14+ と Apple シリコン搭載 Mac が必要です。[GitHub Releases](https://github.com/yuxino/satori/releases/latest) から最新版をダウンロードしてください。

現在のビルドは Apple の公証を受けていません。初回起動時は Control キーを押しながら Satori をクリックし、**開く**を選んでもう一度確認してください。ソースから実行することもできます。

```bash
npm install
npm run app
```

質問する前に、設定で AI サービスの接続を追加してください。

## プライバシー

本と履歴はすべてローカルに保存されます。関連するページ画像が使用中の AI サービスへ送信されるのは、質問を送信するか、ページ全体の説明を明示的に求めたときだけです。質問パネルを開くだけではリクエストは発生しません。

[MIT](LICENSE) © 2026 yuxino
