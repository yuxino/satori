# Satori 3.0

以理解为中心的 macOS PDF 学习空间。**一本书，旁边坐着一个老师。**

`Satori` 来自日语「悟り」：理解、领悟、看清事物本质的瞬间。

## 它是什么

一本教材不只有 PDF。Satori 让你打开书就直接读——全屏书页，没有侧栏、没有面板、没有常驻按钮。卡住时划选一段文字，或者点「问这一页」，一个讲人话的老师就从底部安静出现，用 3–6 句话把这一页讲懂，讲完你回到书。

- 页面即证据：直接读页面图像，不做 OCR，扫描版教材同样能读
- 老师讲法固定：先主线、再大白话、对上术语、一句「所以」；不懂就换角度，不写小作文
- 三个快捷追问：再讲细一点 / 举个例子 / 换个说法
- 位置与问答自动保存在本机；重开书回到上次那页，回看能找到昨天的问答
- 没有徽章、没有连击、没有进度百分比

## 运行

需要 macOS 14+，Rust 与 Node 工具链。

```bash
npm install
npx tauri dev
```

构建 App：

```bash
npx tauri build
```

## 连接百炼

在阿里云百炼创建 API Key。Satori 首次启动会尝试从旧版钥匙串条目迁移；读不到时在设置里粘贴一次即可。Key 只存 macOS 钥匙串，模型走北京共享地址，请求 `store: false`。

默认模型 `qwen3-vl-plus`（视觉理解），可在设置切换 `qwen3-vl-flash` / `qwen-vl-max`。

## 文档

- 产品设计：[`docs/plans/2026-08-16-book-teacher-design.md`](docs/plans/2026-08-16-book-teacher-design.md)
- 架构决策：[`docs/decisions/0010-tauri-rewrite.md`](docs/decisions/0010-tauri-rewrite.md)
- 旧版 Swift 实现保留在 [`legacy-swift/`](legacy-swift/)（tag `legacy-swift`）

[MIT](LICENSE) © 2026 yuxino
