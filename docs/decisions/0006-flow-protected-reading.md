# 0006: Flow-protected reading mode

## Status

Superseded by [0010](0010-tauri-rewrite.md). The current reader preserves the flow-first principle, but none of the Swift types or layout state described here remain active.

## Context

Satori 的核心不是让用户在多个面板之间管理学习，而是让用户在 PDF 中持续阅读，遇到理解阻力时就地获得帮助。现有工作区已经有 PDF、目录和学习面板，但没有一个明确的状态可以暂时移除课程侧栏和理解面板，保护连续阅读。

另外，普通提问默认不带当前页上下文。用户需要先选择上下文范围，才容易得到与眼前内容相关的回答，这增加了不必要的操作成本。

## Decision

- 增加 session-scoped 的“沉浸阅读”状态，由 `ReaderSelectionRouter.isImmersiveReading` 管理。
- 通过阅读栏按钮和 `⌘⇧F` 切换；进入时隐藏课程侧栏和理解面板，但保留当前文档、页码、目录和阅读位置。
- 退出沉浸模式后恢复原来的导航布局和面板可见性。
- 提问上下文默认改为当前页；用户仍可以切换到章节、页码范围、整本书或无上下文。
- 不持久化沉浸模式，避免用户下次启动时找不到导航。

## Consequences

正面影响：阅读现场更干净，AI 与当前页的关系更强，用户不需要在提问前先做配置。

约束：沉浸模式需要始终保留明确的退出入口；窗口布局变化仍由现有的响应式分栏逻辑负责。
