# 0010 · Tauri 重写与「页面即证据」范式

日期：2026-08-16 · 状态：已采纳

## 决策

1. 用 **Tauri 2 + PDF.js** 重写 Satori 界面，废弃 SwiftUI 视图层；旧 Swift 代码打 tag 保留，不删除。
2. 理解路径改为**页面即证据**：视觉模型直接读页面图像，**不建立 OCR 管线**（不做扫描/文字分类、文字层修复、OCR 验真、OCR 目录恢复）。
3. 模型后端抽象：云端百炼 `qwen-vl-ocr` / Qwen3-VL 起步（有免费额度），本地 MLX Qwen3-VL 作为可选离线后端；切换不碰 UI。
4. API Key 仍只存 macOS Keychain；迁移旧条目（service `com.yuxino.satori.qwen.v2`，account `qwen-api-key`），读不到则设置页重新粘贴。

## 理由

- 旧 App 形态是「工作台」而非「书 + 老师」，用户无法用它真正学习，核心循环从未被验证（见 `docs/plans/2026-08-16-book-teacher-design.md`）。
- SwiftUI 迭代慢，无法解决用户最在意的排版与手感，导致靠堆功能补偿。
- VLM 直接读图消除了整条 OCR 复杂度源，从第一天就不存在 OCR 错误问题。

## 影响

- 放弃 macOS 原生 Swift 工具链（偏离 mimi/kiri 模式，用户明确要求）。
- 大幅删减本期功能：web 搜索、代码运行、验证、实验、复习调度全部移出 MVP。
- 需要 Rust / Node 工具链；Keychain 迁移只做一次。
