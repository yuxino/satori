# 章节导览设计

## Problem

用户的核心诉求是「知道书在讲什么」：读 PDF 时始终清楚整本书的脉络、
自己正处在哪一章，并且能随时跳到任意章节。当前应用只有页码跳转，
目录数据（PDF outline + 课程目录页码关联）已存在但没有任何界面露出。

## Design

在阅读栏（`DocumentWorkspace.readingBar`）增加一个**章节导览菜单**：

- 菜单按钮常驻阅读栏，标签显示**当前章节标题**（截断），旁边带目录图标；
  用户扫一眼就知道自己在读哪一章。
- 点开菜单列出全书章节（标题 + 页码），当前章节带勾选标记；
  点击任意章节直接跳转到对应页（复用现有的 `currentPageIndex` 绑定驱动跳转）。
- 章节来源优先用 PDF 自身的 outline（最准确）；没有 outline 时回退到
  这门课学习目录里已关联页码的章节项；两者都没有则不显示菜单。
- outline 提取在打开文档时一次性完成并缓存到 `@State`，同时复用这份结果
  给「课程目录项 → 页码」关联（`linkDirectoryPages`），避免同一份 PDF
  重复解析两次。

## 不改动

- 不改变 PDF 阅读器、学习面板和侧边栏的现有结构。
- 不新增存储；目录关联沿用现有 `learningDirectory.pageIndex` 持久化。
- 不引入 AI 调用，章节导览是纯本地、零延迟的结构信息。

## Verification

- `swift build` 无警告；`swift test` 全绿。
- 打开带 outline 的 PDF：阅读栏显示当前章节，菜单可跳转；
  打开无 outline 的 PDF：回退到课程目录或隐藏菜单。
- `scripts/package-app.sh` 打包成功；截图确认菜单与当前章节标签渲染正常。

