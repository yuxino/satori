<div align="center">
  <img src="src-tauri/icons/128x128@2x.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>读 PDF 教材，卡住时再问一句。</p>
  <p>
    <a href="README.md">English</a>
    · <a href="README_JA.md">日本語</a>
  </p>
</div>

`Satori` 来自日语「悟り」——理解、看清事物本质的瞬间。

一个面向 macOS 和 Windows 11 的本地优先 PDF 学习应用。书页始终留在视野中央，需要帮助时再问当前页或框选区域。

## 功能

- 询问当前页，或在段落、图和代码上框选区域，让模型结合画面解释；支持文字版、扫描版和混合 PDF。
- 使用单页或双页阅读、目录跳转和缩放，并自动回到每本书上次的位置。
- 按书保存阅读活动和问答，回答可以回到来源页重看。
- 使用百炼、OpenAI 或自定义 OpenAI 兼容视觉模型，并明确选择当前连接。
- 无需配置 AI 也能阅读和管理书架。

## 下载

Satori 支持 Windows 11 x64 与 ARM64，以及 Apple 芯片上的 macOS 14+。Windows 3.4.1 请从 [GitHub Releases](https://github.com/yuxino/satori/releases/latest) 下载；当前 macOS 版本为 [3.4.0](https://github.com/yuxino/satori/releases/tag/v3.4.0)。

- **Windows**：下载与处理器架构匹配的 NSIS 安装包。安装包按当前用户安装且未做 Authenticode 签名，因此 Windows 会提示发布者未知。原生交互验收按架构分别记录，尚不宣称已完成 x64-on-x64 手动验收。
- **macOS**：解压后把 Satori 移入「应用程序」。当前包有本地签名但未经公证；首次启动时按住 Control 点击 Satori，再选择「打开」。

更新需要手动下载和安装。应用界面目前只有简体中文。无需配置 AI 也能阅读；提问和扫描目录识别需要支持图片输入的 OpenAI 兼容模型。

## 开发

需要 Node.js 22.13+、稳定版 Rust 和对应平台的 [Tauri 前置环境](https://v2.tauri.app/start/prerequisites/)。macOS 开发还需要稳定的代码签名身份。

```bash
npm install
# macOS
npm run app
# Windows
npm run tauri -- dev
```

## 隐私

PDF 保留在本机原位置。书架数据和问答在 macOS 保存到 Application Support，在 Windows 保存到应用 LocalAppData；API Key 只存入 macOS 钥匙串或 Windows 凭据管理器。只有明确提问、请求解释或确认目录识别后，相关书页图像才会发送给当前 AI 服务；打开书不会联系 AI。启动时的版本检查只向 GitHub Releases 发送应用版本，不包含书页、历史、AI 配置或密钥。

[MIT](LICENSE) © 2026 yuxino
