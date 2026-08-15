---
name: satori-code-cleanup
description: 清理 Satori 的死代码、无效代码、未使用 import/变量/导出/图标/文案键等。当用户说"清理垃圾代码"、"删死代码"、"清理无效代码"、"remove dead code" 或完成功能改动后希望保持代码整洁时使用。
---

# Satori 死代码清理

## 适用时机

- 用户明确要求清理死代码/垃圾代码/无效代码。
- 完成功能改动后，顺手清理由该改动遗留的死代码（例如删除某个交互后，它专属的 DOM 元素、样式、工具函数不再被引用）。
- 重构或删除功能时，检查并移除连带失效的代码。

## Satori 代码结构（清理前先了解）

- 前端 `src/`：`main.ts`（全部 UI 逻辑，单文件较大）、`reader.ts`（滚动阅读器）、`pdf.ts`（PDF.js 封装）、`markdown.ts`（回答渲染）、`api.ts`（Tauri IPC 封装）。
- Rust `src-tauri/src/`：`lib.rs`（命令注册/菜单）、`qwen.rs`（百炼流式客户端）、`keychain.rs`、`store.rs`。
- 样式 `src/styles.css`：组件样式按注释分区。

## 清理对象（按常见度排序）

1. **未使用的 import**——删除后 TypeScript 编译会报，也可用 `npx tsc --noEmit` 检测。
2. **未使用的变量/常量/函数**——特别是模块级导出的常量，先全局搜索确认无引用。
3. **未使用的参数**——如 `askQuestion` 的 `selectionText`（文本选择被框选取代后变死参）。
4. **无引用的 DOM 元素/样式类**——删除某交互后，`index.html` 里的元素、`styles.css` 里的类可能无人使用（如 `selection-capsule`：删 HTML 后 JS 还在 `getElementById` 会 null 崩溃，必须连带清）。
5. **无引用的 Tauri 命令导出**——`api.ts` 里封装了但前端从未 `invoke` 的（如 `clearApiKey`），删前端导出；Rust 端命令若属合理后端能力可保留。
6. **无引用的类型/接口/枚举成员**。
7. **被注释掉的整段代码**。
8. **无效分支**——如恒 false 的条件、永远 return 的代码。

## 工作流

1. **先搜索再删**：对每个疑似死代码，用 `grep` 全局搜索引用（`.ts`、`.rs`、`.css`、`index.html`、配置文件），确认无引用才删。注意区分"定义处"和"使用处"。
2. **连带清理**：删除一个功能时，把它专属的辅助函数、常量、类型、DOM 元素、样式一起删，不要只删调用点。特别是 HTML 元素删除后，JS 里对它的引用必须同步删（否则运行时 null 崩溃）。
3. **检查交叉文件**：`main.ts` 引用的函数可能定义在 `reader.ts`/`pdf.ts`；Rust 命令在 `lib.rs` 注册、前端在 `api.ts` 封装——删任一端要看另一端。
4. **删完必验**：`npx tsc --noEmit` + `npx vite build`（前端）；`cargo check`（Rust）。改动样式后再确认相关类无人引用。
5. **注意导出的公共 API**：`api.ts` 的导出可能被 `main.ts` 引用，删之前全局搜。

## 反例（不要删）

- 测试里引用的符号。
- 配置/构建脚本里引用的路径或脚本（`scripts/dev-app.sh`、`tauri.conf.json` 里的字段）。
- 对外部有约定意义的字符串（如 wire protocol 的 JSON 键、`store.json` 的字段名）。
- 语义上是"未来扩展点"但注释明确说明用途的代码——拿不准时问用户。

## 完成标准

- `git diff --stat` 只包含预期删除 + 必要的连带修改。
- `npx tsc --noEmit`、`npx vite build`、`cargo check` 全绿。
- 不留半删状态（例如只删了调用点、没删定义）。
