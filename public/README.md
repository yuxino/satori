# public/ 静态资源

这里放 Vite 原样拷贝到 dist 根目录的文件（文件名固定、不参与内容哈希）。

## wasm 解码器（pdf.js 用）

- `jbig2.wasm` — JBIG2 扫描页解码（pdf.js 按 `{wasmUrl}jbig2.wasm` 固定名 fetch）
- `openjpeg.wasm` — JPEG2000 页面解码（JPXDecode）
- `qcms_bg.wasm` — ICC 色彩管理（ICCBased）

来源：`node_modules/pdfjs-dist/wasm/`（Apache-2.0，详见
`node_modules/pdfjs-dist/wasm/LICENSE_*`）。

**为什么不能走 Vite 的 `?url` 导入**：`?url` 会给文件名加内容哈希
（如 `jbig2-xxxx.wasm`），而 pdf.js 按固定名请求 `{wasmUrl}jbig2.wasm`，
哈希名会让请求 404，JBIG2 解码静默失败 → 扫描页整页渲染空白。
所以必须放在 public/ 保持固定文件名，`src/pdf.ts` 里 `wasmUrl = "/"`。
