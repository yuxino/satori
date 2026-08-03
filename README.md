<div align="center">
  <img src="Resources/Assets/satori-icon.png" width="112" alt="satori">
  <h1>satori</h1>
  <p>以理解为中心的 macOS PDF 学习空间</p>
  <p><strong>早期原型</strong></p>
</div>

`satori` 来自日语「悟り」，指理解、领悟与看清事物本质的瞬间。

它是一款本地优先的 macOS 学习工具。一本教材不只有 PDF：它还可以有学习目录、相关资料、代码、搜索结果，以及围绕当前内容展开的 AI 解释。Satori 把这些内容放进同一个学习空间，并记住每份资料读到哪里。

## 想解决的问题

- 不强迫做笔记，先帮助你真正理解正在读的内容
- 文字版、扫描版和混合 PDF 都可以进入同一套阅读流程
- AI 回答尽量围绕当前页，并区分 PDF 证据、外部来源与模型推理
- 教材、阅读位置和学习上下文默认保存在本机
- 一本书可以继续关联网页、其他文档和代码，而不是变成孤立文件

## 当前原型

- 三个初始学习空间：高级语言程序设计、软件工程、操作系统
- PDF 导入、类型识别和原生 PDFKit 阅读
- 当前页 / 总页数、前后翻页和直接跳页
- 自动保存阅读位置
- 同一课程内切换、替换或移除 PDF；不会删除电脑上的原文件
- 当前页文字或扫描图像可通过阿里云百炼 Qwen 获得解释
- 提问支持 Enter 发送、Shift+Enter 换行，并可临时附加最多 4 张本地图片
- Qwen 回答会实时流式显示，可随时停止并保留已经生成的内容
- 每本 PDF 都有独立的本地学习记录，重开应用后仍可回看并继续追问
- AI 回答按标题、列表、引用和代码块排版；每轮可复制、重试、删除或回到对应原文页
- 可按单次问题主动启用网页搜索，并显示返回的网页来源
- 百炼 API Key 只保存在当前用户可访问的 Satori 本机配置目录；北京地域的连接地址由应用内置

目前的界面仍在重做中。接下来的重点不是继续堆功能，而是把“选一本书 → 阅读 → 遇到不懂的地方 → 获得带来源的解释 → 回到原文”做成一条真正顺手的学习路径。

## 连接 Qwen

在阿里云百炼的**华北 2（北京）**地域创建按量付费 API Key。创建成功后请立即保存完整的 **API Key**，再粘贴到 Satori 设置；API Host 无需填写，应用已使用阿里官方仍支持的北京共享地址。

默认使用当前高能力档的 `qwen3.8-max`；也可以在设置里改为更均衡的 `qwen3.7-plus` 或更节省的 `qwen3.7-flash`。模型选择保存在本机，API Key 写入权限为 `600` 的本机文件，其所在目录权限为 `700`。

获取方式见[百炼 API Key 官方文档](https://help.aliyun.com/zh/model-studio/get-api-key/)；内置地址依据[百炼 Base URL 总览](https://help.aliyun.com/zh/model-studio/base-url)。密钥不会写入仓库，也不要通过聊天、截图或提交记录分享。

提问始终会带上当前 PDF 页；继续追问时还会带上这本书最近六轮的文字问答。你选择的附图会先在本机缩放压缩，只在本次提问时发给 Qwen，不会进入项目资料库或写入 Git。完整学习记录保存在本机，百炼请求保持 `store: false`。

## 从源码运行

需要 macOS 14+ 和 Swift 6。

```bash
git clone https://github.com/yuxino/satori.git
cd satori
swift run satori-core-tests
./scripts/package-app.sh
open dist/Satori.app
```

更完整的产品背景与进度见 [`docs/brief.md`](docs/brief.md) 和 [`docs/status.md`](docs/status.md)。

[MIT](LICENSE) © 2026 yuxino
