# satori expanded interface demonstration

This replaces the earlier three-to-four-scene, 2x demo with **11 recorded scenes** from the actual production frontend at `f31740ce5f7f722f1adffc52ce12d08c3e05b7f6`.

**Pacing:** every source action interval is played at **10x**, followed by a **0.8-second result hold**. The final clip lasts 19.20 seconds; it is not a uniformly accelerated full video. The GIF and MP4 share the same timing. The fast-forward and sample-data labels remain visible.

**Scope:** PDF reading UI · original local sample · no AI answers. The browser harness substitutes native API boundaries with original local examples; this is not native macOS/Windows end-to-end validation. No user credentials, personal files, live provider output or upstream comic content are included. Satori question composition is shown without submitting an AI request; no answer is fabricated.

## Scenes

1. 01 / Open the original sample PDF / 打开 PDF，直接开始阅读
2. 02 / Page navigation / 下一页，阅读位置自然跟随
3. 03 / Zoom in / 放大页面，看清图文细节
4. 04 / Zoom out and fit to window / 一键恢复适合窗口
5. 05 / Two-page spread / 双页并排，像翻开一本书
6. 06 / Open the embedded outline / 打开目录，查看章节结构
7. 07 / Jump to a chapter / 从目录直接跳到目标页
8. 08 / Open the question composer / 问书面板：先组织自己的问题
9. 09 / Compose a question, without a fabricated answer / 输入问题；这段演示不伪造 AI 回答
10. 10 / Inspect the question-history view / 问过的内容，会集中在回看里
11. 11 / Return to reading / 收起面板，继续读这一本

## Files

`preview.gif` is the inline README preview; `demo.mp4` is the complete silent H.264 video. `poster.png` is an actual recorded result frame. `provenance.json` records source, pacing, scene boundaries and media hashes.

The reproducible documentation-only recorder is `yuxino/kiri/docs/demos/capture/expanded.py`. It is not loaded by the applications. The shipped application code, versions, signing and update workflows remain unchanged.
