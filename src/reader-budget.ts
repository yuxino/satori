import type { PDFPageProxy } from "pdfjs-dist";

const DEFAULT_MAX_CANVAS_PIXELS = 12_000_000;
const DEFAULT_MAX_CANVAS_SIDE = 8192;

/** Clamp a requested PDF.js scale before allocating a canvas. */
export function scaleWithinCanvasBudget(
  logicalWidth: number,
  logicalHeight: number,
  requestedScale: number,
  maxPixels = DEFAULT_MAX_CANVAS_PIXELS,
  maxSide = DEFAULT_MAX_CANVAS_SIDE,
): number {
  if (![logicalWidth, logicalHeight, requestedScale, maxPixels, maxSide].every(
    (value) => Number.isFinite(value) && value > 0,
  )) throw new Error("PDF 页面尺寸或缩放无效。");
  const requestedWidth = logicalWidth * requestedScale;
  const requestedHeight = logicalHeight * requestedScale;
  const pixelRatio = Math.sqrt(maxPixels / (requestedWidth * requestedHeight));
  const sideRatio = Math.min(maxSide / requestedWidth, maxSide / requestedHeight);
  return requestedScale * Math.min(1, pixelRatio, sideRatio);
}

export interface PageRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function releaseCanvas(canvas: HTMLCanvasElement): void {
  canvas.width = 0;
  canvas.height = 0;
}

function checkCancelled(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  const error = new Error("已取消打开 PDF。");
  error.name = "PDFLoadCancelledError";
  throw error;
}

/** Bound every PDF canvas before allocation, including thumbnails and evidence. */
export async function renderPDFPage(
  page: PDFPageProxy,
  requestedScale: number,
  options: { signal?: AbortSignal; region?: PageRegion; maxSide?: number } = {},
): Promise<{ canvas: HTMLCanvasElement; scale: number }> {
  checkCancelled(options.signal);
  const logical = page.getViewport({ scale: 1 });
  const region = options.region;
  if (region && (!Number.isFinite(region.x) || !Number.isFinite(region.y))) {
    throw new Error("PDF 框选位置无效。");
  }
  const scale = scaleWithinCanvasBudget(
    region?.width ?? logical.width,
    region?.height ?? logical.height,
    requestedScale,
    DEFAULT_MAX_CANVAS_PIXELS,
    options.maxSide ?? DEFAULT_MAX_CANVAS_SIDE,
  );
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.floor((region?.width ?? logical.width) * scale));
  canvas.height = Math.max(1, Math.floor((region?.height ?? logical.height) * scale));
  try {
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("无法创建 PDF 画布。");
    const renderTask = page.render({
      canvas,
      canvasContext: ctx,
      viewport,
      // PDF.js already applies viewport.scale. Only translate the crop origin.
      transform: region ? [1, 0, 0, 1, -region.x * scale, -region.y * scale] : undefined,
    });
    const onAbort = () => renderTask.cancel();
    options.signal?.addEventListener("abort", onAbort, { once: true });
    if (options.signal?.aborted) onAbort();
    try {
      await renderTask.promise;
      checkCancelled(options.signal);
    } catch (error) {
      checkCancelled(options.signal);
      throw error;
    } finally {
      options.signal?.removeEventListener("abort", onAbort);
    }
    return { canvas, scale };
  } catch (error) {
    releaseCanvas(canvas);
    throw error;
  }
}
