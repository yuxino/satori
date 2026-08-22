// PDF.js 封装：加载文档、渲染页面、导出页面为 JPEG。
import * as pdfjsLib from "pdfjs-dist";
import type { PDFDocumentProxy } from "pdfjs-dist";

// 现代 pdfjs-dist 的 worker 通过同源 URL 加载；在 Vite 下直接 import。
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;

// 扫描件常用 JBIG2/JPEG2000/ICC 压缩，需要 wasm 解码器。
// 注意：wasm 不能走 Vite 的 ?url 导入——那会带内容哈希（jbig2-xxx.wasm），
// 而 pdf.js 按固定文件名 fetch（{wasmUrl}jbig2.wasm），哈希名会 404，
// 导致 JBIG2 扫描页解码失败、整页渲染空白。所以把解码器放在 public/
// （Vite 原样拷到 dist 根，文件名固定），wasmUrl 用根路径 "/"。
const wasmUrl = "/";

/// PDF 大纲目录项（扁平化，含层级深度）。
interface OutlineItem {
  title: string;
  page: number;
  depth: number;
}

export class PDFDocument {
  private doc: PDFDocumentProxy;
  /// 页面尺寸缓存（scale=1），连续滚动时避免反复异步取尺寸。
  private sizeCache = new Map<number, { width: number; height: number }>();

  private constructor(doc: PDFDocumentProxy) {
    this.doc = doc;
  }

  static async load(url: string, onProgress?: (loaded: number, total: number) => void): Promise<PDFDocument> {
    const loadingTask = pdfjsLib.getDocument({
      url,
      useSystemFonts: true,
      // 提供 wasm 解码器（public/ 根路径下的固定名文件），
      // 否则 JBIG2/CCITT/JPEG2000 扫描页无法解码（空白页）。
      wasmUrl,
    });
    // onProgress 是 DocumentInitParameters 的加载进度回调。
    loadingTask.onProgress = (p: { loaded: number; total: number }) => {
      onProgress?.(p.loaded, p.total);
    };
    const doc = await loadingTask.promise;
    return new PDFDocument(doc);
  }

  get pageCount(): number {
    return this.doc.numPages;
  }

  /// 大纲缓存（PDF 大纲是文档级数据，解析一次即可）。
  private outlineCache: OutlineItem[] | null = null;

  /// 页面在 scale=1 下的逻辑尺寸（PDF 点）。带缓存。
  async pageSize(pageNumber: number): Promise<{ width: number; height: number }> {
    const cached = this.sizeCache.get(pageNumber);
    if (cached) return cached;
    const page = await this.doc.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 1 });
    const size = { width: viewport.width, height: viewport.height };
    this.sizeCache.set(pageNumber, size);
    return size;
  }

  /// 批量预热页面尺寸（连续滚动布局需要提前知道总高度）。
  async prefetchSizes(from: number, to: number): Promise<void> {
    const batch: Promise<void>[] = [];
    for (let p = Math.max(1, from); p <= Math.min(this.doc.numPages, to); p++) {
      if (!this.sizeCache.has(p)) {
        batch.push(this.pageSize(p).then(() => undefined));
      }
    }
    await Promise.all(batch);
  }

  /// 读取 PDF 大纲（目录），扁平化为带层级和页码的列表。
  /// 没有大纲时返回空数组（扫描书可能没有内置目录）。
  async getOutline(): Promise<OutlineItem[]> {
    if (this.outlineCache) return this.outlineCache;
    const outline = await this.doc.getOutline();
    if (!outline || outline.length === 0) {
      // 空目录也缓存（避免每次打开抽屉都重新查）。
      this.outlineCache = [];
      return [];
    }
    const result: OutlineItem[] = [];
    const walk = async (nodes: Array<Record<string, unknown>>, depth: number) => {
      for (const node of nodes) {
        const title = String(node.title ?? "");
        let page = 0;
        const dest = node.dest as string | Array<unknown> | null | undefined;
        if (typeof dest === "string") {
          const resolved = await this.doc.getDestination(dest);
          if (resolved) page = (await this.doc.getPageIndex(resolved[0] as { num: number; gen: number })) + 1;
        } else if (Array.isArray(dest) && dest.length > 0) {
          try {
            page = (await this.doc.getPageIndex(dest[0] as { num: number; gen: number })) + 1;
          } catch {
            page = 0;
          }
        }
        if (title && page > 0) result.push({ title, page, depth });
        const children = node.items as Array<Record<string, unknown>> | undefined;
        if (children && children.length > 0) await walk(children, depth + 1);
      }
    };
    await walk(outline as Array<Record<string, unknown>>, 0);
    this.outlineCache = result;
    return result;
  }

  async renderPageToCanvas(pageNumber: number, scale: number): Promise<HTMLCanvasElement> {
    const page = await this.doc.getPage(pageNumber);
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    const ctx = canvas.getContext("2d")!;
    await page.render({ canvas, canvasContext: ctx, viewport }).promise;
    return canvas;
  }

  /// 在 canvas 上按 PDF 坐标（scale=1）画一个选中框，让视觉模型
  /// 一眼看到用户框选的位置（否则模型可能不知道选的是哪块）。
  private drawHighlight(
    ctx: CanvasRenderingContext2D,
    rect: { x: number; y: number; width: number; height: number },
    pxPerPoint: number,
  ) {
    ctx.strokeStyle = "rgba(230, 60, 60, 0.95)";
    ctx.lineWidth = Math.max(3, Math.round(8 * pxPerPoint / 1.5));
    ctx.strokeRect(rect.x * pxPerPoint, rect.y * pxPerPoint, rect.width * pxPerPoint, rect.height * pxPerPoint);
    // 四角再加小标记，更醒目。
    ctx.fillStyle = "rgba(230, 60, 60, 0.95)";
    const l = Math.max(6, Math.round(14 * pxPerPoint / 1.5));
    const [x, y, w, h] = [
      rect.x * pxPerPoint,
      rect.y * pxPerPoint,
      rect.width * pxPerPoint,
      rect.height * pxPerPoint,
    ];
    ctx.fillRect(x, y, l, Math.max(2, ctx.lineWidth));
    ctx.fillRect(x, y + h, l, Math.max(2, ctx.lineWidth));
    ctx.fillRect(x + w - l, y, l, Math.max(2, ctx.lineWidth));
    ctx.fillRect(x + w - l, y + h, l, Math.max(2, ctx.lineWidth));
    ctx.fillRect(x, y, Math.max(2, ctx.lineWidth), l);
    ctx.fillRect(x + w, y, Math.max(2, ctx.lineWidth), l);
    ctx.fillRect(x, y + h - l, Math.max(2, ctx.lineWidth), l);
    ctx.fillRect(x + w, y + h - l, Math.max(2, ctx.lineWidth), l);
  }

  /// 导出某页为 JPEG base64（不含 data: 前缀），作为视觉证据。
  /// 可选 highlight：在 PDF 坐标（scale=1）矩形处画红色选中框，
  /// 供「框选理解」的整页上下文使用。
  async exportPageAsJPEG(
    pageNumber: number,
    scale = 1.5,
    highlight?: { x: number; y: number; width: number; height: number },
  ): Promise<string> {
    const canvas = await this.renderPageToCanvas(pageNumber, scale);
    // 长边限制，避免超大图浪费 token。
    const maxSide = 1800;
    let pxPerPoint = scale;
    if (canvas.width > maxSide || canvas.height > maxSide) {
      const ratio = Math.min(maxSide / canvas.width, maxSide / canvas.height);
      pxPerPoint *= ratio;
      const resized = document.createElement("canvas");
      resized.width = Math.floor(canvas.width * ratio);
      resized.height = Math.floor(canvas.height * ratio);
      resized.getContext("2d")!.drawImage(canvas, 0, 0, resized.width, resized.height);
      if (highlight) this.drawHighlight(resized.getContext("2d")!, highlight, pxPerPoint);
      return resized.toDataURL("image/jpeg", 0.82).split(",")[1];
    }
    if (highlight) this.drawHighlight(canvas.getContext("2d")!, highlight, pxPerPoint);
    return canvas.toDataURL("image/jpeg", 0.82).split(",")[1];
  }

  /// 导出选中区域（PDF 坐标矩形）为 JPEG，用于「框选理解」。
  async exportRegionAsJPEG(
    pageNumber: number,
    rect: { x: number; y: number; width: number; height: number },
    scale = 3,
  ): Promise<string> {
    const page = await this.doc.getPage(pageNumber);
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(rect.width * scale);
    canvas.height = Math.floor(rect.height * scale);
    const ctx = canvas.getContext("2d")!;
    await page.render({
      canvas,
      canvasContext: ctx,
      viewport,
      transform: [scale, 0, 0, scale, -rect.x * scale, -rect.y * scale],
    }).promise;
    // 给裁剪图加一圈红边，模型能认出这是被选中的片段。
    ctx.strokeStyle = "rgba(230, 60, 60, 0.95)";
    ctx.lineWidth = Math.max(3, Math.round(8 * scale / 3));
    ctx.strokeRect(1, 1, canvas.width - 2, canvas.height - 2);
    return canvas.toDataURL("image/jpeg", 0.82).split(",")[1];
  }

  destroy() {
    void this.doc.destroy();
  }
}
