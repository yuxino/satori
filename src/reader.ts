// 连续滚动阅读器：页面从上到下排列、宽度铺满，懒渲染视口附近的页面，
// 支持缩放、框选区域、页码映射。这是「书桌」的核心渲染层。

import { PDFDocument } from "./pdf";

export interface RegionSelection {
  page: number;
  /// PDF 坐标（scale=1）下的矩形，供 exportRegionAsJPEG 使用。
  rect: { x: number; y: number; width: number; height: number };
}

export interface ReaderCallbacks {
  onPageChange?: (page: number) => void;
  onRegionSelected?: (region: RegionSelection) => void;
}

const PAGE_GAP = 14;
const SIDE_MARGIN = 28;
/// 视口上下各预渲染多少页。
const RENDER_RADIUS = 2;

interface PageLayout {
  /// 显示高度（px）。
  displayHeight: number;
  /// 顶部偏移（px，文档坐标）。
  top: number;
  /// PDF 逻辑尺寸（scale=1 的 PDF 点）。
  logicalWidth: number;
  logicalHeight: number;
}

export class ScrollReader {
  private surface: HTMLDivElement;
  private doc: PDFDocument;
  private cb: ReaderCallbacks;

  /// 当前缩放：1 = 页面宽度正好铺满可用宽度。
  private zoom = 1;
  /// 页面显示宽度（px）= 可用宽度 × zoom。
  private pageWidth = 800;
  private layouts: PageLayout[] = [];
  private mounted = new Map<number, { el: HTMLDivElement; canvas: HTMLCanvasElement | null }>();
  private rendering = false;
  private renderQueued = false;

  constructor(surface: HTMLDivElement, doc: PDFDocument, cb: ReaderCallbacks = {}) {
    this.surface = surface;
    this.doc = doc;
    this.cb = cb;
  }

  private get availableWidth(): number {
    return Math.max(this.surface.clientWidth - SIDE_MARGIN * 2, 200);
  }

  /// 打开：建立页面骨架，滚动到指定页。
  async open(targetPage: number): Promise<void> {
    this.pageWidth = this.availableWidth * this.zoom;
    await this.layout();
    await this.renderVisible(this.currentPage());
    this.scrollToPage(targetPage, true);
  }

  /// 缩放：改页面宽度，重建布局，保持视口中心对应的文档位置不动。
  async setZoom(factor: number): Promise<void> {
    // 记录缩放前视口中心所在的页和页内比例，缩放后恢复。
    const centerY = this.surface.scrollTop + this.surface.clientHeight / 2;
    const anchorPage = this.pageAtOffset(centerY);
    const anchorLayout = this.layouts[anchorPage - 1];
    const ratioInPage = anchorLayout
      ? (centerY - anchorLayout.top) / anchorLayout.displayHeight
      : 0.5;

    this.zoom = factor;
    this.pageWidth = this.availableWidth * this.zoom;
    await this.layout();

    const newLayout = this.layouts[anchorPage - 1];
    if (newLayout) {
      this.surface.scrollTop = newLayout.top + newLayout.displayHeight * ratioInPage - this.surface.clientHeight / 2;
    }
    await this.renderVisible(anchorPage);
    this.emitPage();
  }

  async layout(): Promise<void> {
    this.surface.innerHTML = "";
    this.mounted.clear();
    this.layouts = [];

    // 批量预热所有页尺寸，避免逐页串行等待。
    await this.doc.prefetchSizes(1, this.doc.pageCount);

    // 页面左侧位置：窄于窗口时居中，宽于窗口时从 0 开始以便横向滚动。
    const surfaceW = this.surface.clientWidth;
    const left = Math.max(0, (surfaceW - this.pageWidth) / 2);

    let top = 0;
    for (let p = 1; p <= this.doc.pageCount; p++) {
      const { width, height } = await this.doc.pageSize(p);
      const displayHeight = (height / width) * this.pageWidth;
      this.layouts.push({ displayHeight, top, logicalWidth: width, logicalHeight: height });
      top += displayHeight + PAGE_GAP;

      const el = document.createElement("div");
      el.className = "scroll-page";
      el.dataset.page = String(p);
      el.style.left = `${left}px`;
      el.style.width = `${this.pageWidth}px`;
      el.style.height = `${displayHeight}px`;
      el.style.top = `${this.layouts[p - 1].top}px`;
      this.surface.appendChild(el);
      this.mounted.set(p, { el, canvas: null });
    }
    // 关键：绝对定位的页面不撑起滚动容器的内容高度。
    // 必须用一个普通流式占位元素撑高容器，滚动条才会出现，
    // 否则容器自身高度会覆盖窗口高度，页面既看不见也滚不动。
    const spacer = document.createElement("div");
    spacer.className = "scroll-spacer";
    spacer.style.height = `${top}px`;
    this.surface.appendChild(spacer);
  }

  /// 渲染视口附近的页（惰性，已渲染的不重绘）。
  private async renderVisible(aroundPage?: number): Promise<void> {
    const center = aroundPage ?? this.currentPage();
    const start = Math.max(1, center - RENDER_RADIUS);
    const end = Math.min(this.doc.pageCount, center + RENDER_RADIUS);

    // 清理视口外过远的页面。
    for (const [p, mount] of this.mounted) {
      if (p < start - RENDER_RADIUS * 2 || p > end + RENDER_RADIUS * 2) {
        mount.el.remove();
        mount.canvas = null;
      }
    }

    const toRender: number[] = [];
    for (let p = start; p <= end; p++) {
      const mount = this.mounted.get(p);
      if (mount && !mount.canvas) toRender.push(p);
    }
    if (toRender.length === 0) return;

    if (this.rendering) {
      this.renderQueued = true;
      return;
    }
    this.rendering = true;
    try {
      for (const p of toRender) {
        const mount = this.mounted.get(p);
        if (!mount) continue;
        const canvas = await this.doc.renderPageToCanvas(p, this.canvasScale(p));
        canvas.style.width = "100%";
        canvas.style.height = "100%";
        mount.el.appendChild(canvas);
        mount.canvas = canvas;
      }
    } finally {
      this.rendering = false;
      if (this.renderQueued) {
        this.renderQueued = false;
        void this.renderVisible();
      }
    }
  }

  /// 每页的渲染分辨率：显示宽度 × 2（视网膜清晰度）。
  /// 用该页逻辑宽度换算 PDF.js 的 scale，避免硬编码导致超大 canvas
  /// 触发浏览器限制而模糊。
  private canvasScale(page: number): number {
    const layout = this.layouts[page - 1];
    if (!layout) return 2;
    return (this.pageWidth * 2) / layout.logicalWidth;
  }

  /// 当前视口中心的页码。
  currentPage(): number {
    const centerY = this.surface.scrollTop + this.surface.clientHeight / 2;
    return this.pageAtOffset(centerY);
  }

  private pageAtOffset(y: number): number {
    let lo = 0;
    let hi = this.layouts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if ((this.layouts[mid]?.top ?? 0) <= y) lo = mid;
      else hi = mid - 1;
    }
    return Math.max(1, Math.min(this.doc.pageCount, lo + 1));
  }

  scrollToPage(page: number, instant = false): void {
    const target = this.layouts[page - 1]?.top ?? 0;
    this.surface.scrollTo({ top: target, behavior: instant ? "auto" : "smooth" });
  }

  /// 滚动事件处理：更新页码、惰性渲染。
  async onScroll(): Promise<void> {
    this.emitPage();
    await this.renderVisible();
  }

  private emitPage() {
    this.cb.onPageChange?.(this.currentPage());
  }

  /// 由调用方在 surface 上监听 mousemove 并调用；overlay 用于显示选框。
  /// 完成时返回 PDF 坐标选区，供「框选理解」使用。
  finishRegionSelect(
    startX: number,
    startY: number,
    curX: number,
    curY: number,
    overlay: HTMLDivElement,
  ): RegionSelection | null {
    const x = Math.min(startX, curX);
    const y = Math.min(startY, curY);
    const w = Math.abs(curX - startX);
    const h = Math.abs(curY - startY);
    overlay.style.display = "none";
    if (w < 12 || h < 12) return null;

    // 屏幕坐标（含滚动）落在哪一页。
    const docY = y + this.surface.scrollTop;
    const page = this.pageAtOffset(docY + h / 2);
    const layout = this.layouts[page - 1];
    const mount = this.mounted.get(page);
    if (!layout || !mount) return null;

    // 用页面元素的实际屏幕位置换算，避免缩放假设。
    const pageRect = mount.el.getBoundingClientRect();
    const xInPage = x - pageRect.left;
    const yInPage = y - pageRect.top;
    const kx = layout.logicalWidth / pageRect.width;
    const ky = layout.logicalHeight / pageRect.height;

    return {
      page,
      rect: {
        x: Math.max(0, xInPage * kx),
        y: Math.max(0, yInPage * ky),
        width: w * kx,
        height: h * ky,
      },
    };
  }

  clear(): void {
    this.surface.innerHTML = "";
    this.mounted.clear();
    this.layouts = [];
  }
}
