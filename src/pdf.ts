// PDF.js 封装：加载文档、渲染页面、导出页面为 JPEG。
import * as pdfjsLib from "pdfjs-dist";
import type { PDFDocumentProxy } from "pdfjs-dist";

// 现代 pdfjs-dist 的 worker 通过同源 URL 加载；在 Vite 下直接 import。
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;

export interface RenderedPage {
  page: number;
  scale: number;
}

export class PDFDocument {
  private doc: PDFDocumentProxy;

  private constructor(doc: PDFDocumentProxy) {
    this.doc = doc;
  }

  static async load(url: string): Promise<PDFDocument> {
    const loadingTask = pdfjsLib.getDocument({
      url,
      useSystemFonts: true,
    });
    const doc = await loadingTask.promise;
    return new PDFDocument(doc);
  }

  get pageCount(): number {
    return this.doc.numPages;
  }

  /// 页面在 scale=1 下的逻辑尺寸（PDF 点）。用于自适应缩放计算。
  async pageSize(pageNumber: number): Promise<{ width: number; height: number }> {
    const page = await this.doc.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 1 });
    return { width: viewport.width, height: viewport.height };
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

  /// 导出某页为 JPEG base64（不含 data: 前缀），作为视觉证据。
  async exportPageAsJPEG(pageNumber: number, scale = 1.5): Promise<string> {
    const canvas = await this.renderPageToCanvas(pageNumber, scale);
    // 长边限制，避免超大图浪费 token。
    const maxSide = 1800;
    if (canvas.width > maxSide || canvas.height > maxSide) {
      const ratio = Math.min(maxSide / canvas.width, maxSide / canvas.height);
      const resized = document.createElement("canvas");
      resized.width = Math.floor(canvas.width * ratio);
      resized.height = Math.floor(canvas.height * ratio);
      resized.getContext("2d")!.drawImage(canvas, 0, 0, resized.width, resized.height);
      return resized.toDataURL("image/jpeg", 0.82).split(",")[1];
    }
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
    return canvas.toDataURL("image/jpeg", 0.82).split(",")[1];
  }

  destroy() {
    void this.doc.destroy();
  }
}
