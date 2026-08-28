---
name: satori-i18n
description: 处理 satori 的界面语言。当前 satori 为纯中文单语（无 i18n 结构）；当需要新增界面语言、把硬编码中文文案抽离、或排查某处文案不跟随时使用。
---

# satori 国际化（界面语言）

## 当前状态（如实说明）

satori **目前是纯中文单语**：用户可见文案分布在 `src/main.ts`、`settings.ts`、`reader.ts`、`pdf.ts` 等前端模块，以及 Rust 端返回给界面的错误消息；`qwen.rs` 还包含发给模型的中文指令。**没有 i18n 结构、没有语言切换**。

因此本 skill 在 satori 的用途分两档：

1. **现在**：改文案时，先用 `rg` 找到前端或 Rust 端的实际定义，再修改对应字符串；注意保持中文表达一致（参考产品用语：书、老师、回看、问这一页、框选理解）。
2. **将来加 i18n 时**：按下文路径抽离，避免临时堆砌。

## 加 i18n 时的路径（未来工作）

### 文案分布（先摸清）

- 前端 `src/main.ts`：主要工作区、提问流程和书菜单文案。
- 前端 `src/settings.ts` / `src/update.ts`：设置和版本更新文案。
- 前端 `src/reader.ts` / `src/pdf.ts`：阅读器状态、PDF 加载和错误文案。
- Rust `src-tauri/src/qwen.rs`：`TEACHER_SYSTEM` 提示词（中文，发给模型，**不是界面文案**，勿 i18n）。
- Rust `src-tauri/src/keychain.rs` / `store.rs` / `thumbs.rs` / `provider.rs` / `update.rs`：错误或状态消息（中文，可能返给前端展示）。
- `index.html`：标题。

### 建议结构（参照 mimi 的教训）

- 新建 `src/i18n.ts`，按组存放：`READER_ZH / READER_EN`（阅读器：翻页、缩放、回看、问这一页）、`TEACHER_ZH / TEACHER_EN`（老师面板）、`SETTINGS_ZH / SETTINGS_EN`（设置）、`BOOK_MENU_ZH / BOOK_MENU_EN`（书菜单）。
- 用模块级常量 `I18N.reader.xxx` 引用，窗口加载时按当前语言计算一次。
- **所有语言组必须同步加/删同一个键**——只加 zh 不加 en 会运行时 undefined。
- 语言判定：`"system" | "zh" | "en"`，`system` 跟随系统（`zh-*` → zh，其他 → en）。
- 切换语言：写存储 + 通知 + reload 窗口，让模块级常量重算。**跨窗口同步要对比"渲染时快照语言"而非存储值**（mimi 踩过的坑：所有窗口共享同一 localStorage origin，发起窗口已写入新值，比存储永远一致、永不 reload）。

### 新增界面语言时改的地方

1. `src/i18n.ts`：语言类型、系统检测、各文案组、`I18N` 选择表达式。
2. `src/main.ts`：语言切换入口（可放设置面板）、`effectiveLanguage()` 调用点。
3. 设置面板加语言下拉。
4. 验证：`npx tsc --noEmit` + `npx vite build`；切语言看所有窗口是否跟随。

## 注意

- `TEACHER_SYSTEM`（老师讲法提示词）**不要 i18n**——它是发给模型的指令，模型按中文讲人话是产品设计，不属于界面文案。
- 用户可见的 API Key 错误消息在 Rust 端，加 i18n 时需从 Rust 返回错误码/键，由前端翻译，而不是直接返回中文串。
- 文案改动不要动 wire protocol（`store.json` 字段名、IPC 命令名、百炼 API 参数），那些与存储/服务镜像。
