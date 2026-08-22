# 0007: Selection-first understanding

## Status

Implementation superseded by [0010](0010-tauri-rewrite.md). Selection-first page evidence remains a product principle; the Swift actions and models described below are historical.

## Context

Satori 的价值不是让用户把书整理成一套学习管理数据，而是在阅读过程中遇到阻力时，尽快把一段原文理解清楚。此前 PDF 选区只有一个“问 AI”入口，选中文字会被拼进普通问题里；“运行”也和理解动作处在同一层，容易把阅读现场带向工具切换。

## Decision

- 把选区视为一次带意图的理解请求，而不是普通输入框文本。
- 首屏动作固定为“理解”“接上文”“举例”“试试看”和“复制”；代码运行保留在次级运行空间。
- 选区动作在没有草稿、没有正在回答时直接发送，减少一次确认点击；用户已有草稿或请求进行中时，只追加为可编辑内容，不覆盖用户输入。
- 每次选区请求默认使用选区所在页作为 PDF 依据，并在理解面板显示原文锚点、页码和“回到原文”入口。
- AI 默认先给短结论，再给必要的原文依据和解释；只有用户追问时才展开背景，避免把快速阅读变成长教程。
- 当前锚点先作为 UI 会话状态保存；下一阶段再把 `SelectionAnchor` 纳入 Core 的请求和问答模型，保证布局切换、历史记录和证据展示都能精确关联到原文。

## Consequences

正面影响：选择、理解、返回原文形成一个连续动作，减少面板配置和功能分叉，更符合心流阅读。

约束：这轮“试试看”只负责让 AI 设计一个小实验，还不是可交互的实验运行时；真正的实验必须使用受控模型，不能让模型直接执行任意代码。
