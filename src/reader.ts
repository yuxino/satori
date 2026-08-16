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
  /// 左偏移（px，文档坐标）。单页模式全部一样；双页模式左右页各半。
  left: number;
  /// 显示宽度（px）。单页 = 页宽；双页 = 展开宽度的一半。
  width: number;
  /// PDF 逻辑尺寸（scale=1 的 PDF 点）。
  logicalWidth: number;
  logicalHeight: number;
}

export class ScrollReader {
  private surface: HTMLDivElement;
  /// 内容层：页面与 spacer 都挂在这里。缩放预览用 transform 作用于该层，
  /// 避免手势期间重建 DOM / 重渲染高清 canvas 造成卡顿。
  private content: HTMLDivElement;
  private doc: PDFDocument;
  private cb: ReaderCallbacks;

  /// 当前缩放：1 = 页面宽度正好铺满可用宽度。
  private zoom = 1;
  /// 双页模式（书本展开）：两页并排，1 = 展开宽度铺满可用宽度。
  private spread = false;
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
    this.content = document.createElement("div");
    this.content.className = "reader-content";
    this.surface.appendChild(this.content);
  }

  private get availableWidth(): number {
    return Math.max(this.surface.clientWidth - SIDE_MARGIN * 2, 200);
  }

  /// 打开：建立页面骨架，滚动到指定页。
  /// initialZoom 是打开时就要用的缩放（1 = 适合宽度），
  /// spread 为 true 时按双页（书本展开）布局。
  async open(targetPage: number, initialZoom = 1, spread = false): Promise<void> {
    await this.waitForWidth();
    this.zoom = initialZoom;
    this.spread = spread;
    this.pageWidth = this.availableWidth * this.zoom;
    await this.layout();
    // 直接渲染目标页附近（跳到上次读的页，不等 scroll 事件异步触发）。
    await this.renderVisible(targetPage);
    this.scrollToPage(targetPage, true);
    this.emitPage();
  }

  /// 切换单页/双页布局，保持视口中心对应的文档位置不动。
  /// 双页：1 = 展开宽度铺满；单页：1 = 单页宽度铺满。
  async setSpread(enabled: boolean): Promise<void> {
    if (this.spread === enabled) return;
    this.spread = enabled;
    await this.commitZoom(this.zoom);
  }

  /// 等待滚动容器获得真实宽度（WebView 初次布局可能晚于脚本执行）。
  /// 轮询 requestAnimationFrame，最多等 2 秒；超时也继续，避免永久挂起。
  private waitForWidth(): Promise<void> {
    return new Promise((resolve) => {
      const deadline = performance.now() + 2000;
      const poll = () => {
        if (this.surface.clientWidth > 0 || performance.now() > deadline) {
          resolve();
          return;
        }
        requestAnimationFrame(poll);
      };
      poll();
    });
  }

  /// 缩放：改页面宽度，重建布局，保持视口中心对应的文档位置不动。
  /// （离散操作：⌘+/-、按钮、窗口 resize 走这里）
  async setZoom(factor: number): Promise<void> {
    await this.commitZoom(factor);
  }

  async layout(): Promise<void> {
    // 防御：等宽度就绪（WebView 初次布局晚于脚本执行时，
    // clientWidth 为 0，页面会按错误比例建立、需要手动缩放才正常）。
    await this.waitForWidth();

    // 清空内容层（保留 content 本身，避免重复嵌套）。
    this.content.innerHTML = "";
    this.mounted.clear();
    this.layouts = [];

    // 批量预热所有页尺寸，避免逐页串行等待。
    await this.doc.prefetchSizes(1, this.doc.pageCount);

    // 页面左侧位置：窄于窗口时居中，宽于窗口时从 0 开始以便横向滚动。
    const surfaceW = this.surface.clientWidth;
    const left = Math.max(0, (surfaceW - this.pageWidth) / 2);

    // 只计算尺寸/位置数据（供页码映射、滚动定位），不建 DOM——
    // 几百页的书逐页建元素会卡，元素由 renderVisible 按需创建。
    const sizes: { width: number; height: number }[] = [];
    for (let p = 1; p <= this.doc.pageCount; p++) {
      sizes.push(await this.doc.pageSize(p));
    }

    if (!this.spread) {
      // ---- 单页：从上到下排列 ----
      let top = 0;
      for (let p = 1; p <= this.doc.pageCount; p++) {
        const { width, height } = sizes[p - 1];
        const displayHeight = (height / width) * this.pageWidth;
        this.layouts.push({
          displayHeight,
          top,
          left,
          width: this.pageWidth,
          logicalWidth: width,
          logicalHeight: height,
        });
        top += displayHeight + PAGE_GAP;
      }
      return;
    }

    // ---- 双页（书本展开）：两页并排成一行 ----
    // 第 1 页（封面）单独在右；之后 (2,3)、(4,5)… 偶数页在左、奇数页在右，
    // 像翻开的书。行高取该行两页的较大者，两页顶端对齐。
    const pageW = Math.max((this.pageWidth - PAGE_GAP) / 2, 40);
    const leftX = left;
    const rightX = left + this.pageWidth / 2 + PAGE_GAP / 2;
    // 行号：p=1 → 0；(p>=2) → floor((p-2)/2)+1
    const rowOf = (p: number) => (p <= 1 ? 0 : Math.floor((p - 2) / 2) + 1);

    let rowTop = 0;
    let curRow = -1;
    let rowMaxH = 0;
    for (let p = 1; p <= this.doc.pageCount; p++) {
      const row = rowOf(p);
      if (row !== curRow) {
        // 新行开始：把上一行的高度加进 top。
        if (curRow >= 0) rowTop += rowMaxH + PAGE_GAP;
        curRow = row;
        rowMaxH = 0;
      }
      const { width, height } = sizes[p - 1];
      const displayHeight = (height / width) * pageW;
      const isRight = p % 2 === 1; // 奇数页在右（含第 1 页封面）
      rowMaxH = Math.max(rowMaxH, displayHeight);
      this.layouts.push({
        displayHeight,
        top: rowTop,
        left: isRight ? rightX : leftX,
        width: pageW,
        logicalWidth: width,
        logicalHeight: height,
      });
    }
    const totalHeight = rowTop + rowMaxH;

    // 关键：绝对定位的页面不撑起滚动容器的内容高度。
    // 必须用一个普通流式占位元素撑高容器，滚动条才会出现，
    // 否则容器自身高度会覆盖窗口高度，页面既看不见也滚不动。
    const spacer = document.createElement("div");
    spacer.className = "scroll-spacer";
    spacer.style.height = `${totalHeight}px`;
    this.content.appendChild(spacer);
  }

  /// 缩放手势期间的即时预览：只对内容层做 transform，不重建 DOM。
  /// 视觉上以视口中心为锚缩放（transform-origin 设在中心对应的文档坐标）。
  previewZoom(factor: number): void {
    const clamped = Math.min(3, Math.max(0.5, factor));
    const centerX = this.surface.scrollLeft + this.surface.clientWidth / 2;
    const centerY = this.surface.scrollTop + this.surface.clientHeight / 2;
    this.content.style.transformOrigin = `${centerX}px ${centerY}px`;
    this.content.style.transform = `scale(${clamped / this.zoom})`;
  }

  /// 是否处于缩放手势预览中（此时页面坐标被 transform 扭曲，禁用框选）。
  isZoomPreviewing(): boolean {
    return this.content.style.transform !== "";
  }

  /// 缩放手势结束：提交真实缩放（重布局 + 重渲染高清），移除 transform。
  async commitZoom(factor: number): Promise<void> {
    // 记录缩放前视口中心所在的页和页内比例，缩放后恢复。
    const centerY = this.surface.scrollTop + this.surface.clientHeight / 2;
    const anchorPage = this.pageAtOffset(centerY);
    const anchorLayout = this.layouts[anchorPage - 1];
    const ratioInPage = anchorLayout
      ? (centerY - anchorLayout.top) / anchorLayout.displayHeight
      : 0.5;

    this.content.style.transform = "";
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
        this.mounted.delete(p);
      }
    }

    // 按需创建视口附近的页面元素（惰性骨架），再渲染 canvas。
    const toRender: number[] = [];
    for (let p = start; p <= end; p++) {
      let mount = this.mounted.get(p);
      if (!mount) {
        const layout = this.layouts[p - 1];
        if (!layout) continue;
        const el = document.createElement("div");
        el.className = "scroll-page";
        el.dataset.page = String(p);
        el.style.left = `${layout.left}px`;
        el.style.width = `${layout.width}px`;
        el.style.height = `${layout.displayHeight}px`;
        el.style.top = `${layout.top}px`;
        this.content.appendChild(el);
        mount = { el, canvas: null };
        this.mounted.set(p, mount);
      }
      if (!mount.canvas) toRender.push(p);
    }
    if (toRender.length === 0) return;

    if (this.rendering) {
      this.renderQueued = true;
      return;
    }
    this.rendering = true;
    try {
      for (const p of toRender) {
        // 渲染前再次检查：如果这一页已滚出视口附近（用户滚走了），
        // 跳过它，优先渲染当前视口的页，避免"加载不出来"。
        const now = this.currentPage();
        if (p < now - RENDER_RADIUS || p > now + RENDER_RADIUS) continue;
        const mount = this.mounted.get(p);
        if (!mount || !mount.el.isConnected) continue;
        const canvas = await this.doc.renderPageToCanvas(p, this.canvasScale(p));
        // 渲染耗时较长，期间视口可能又变了；只有页还在时才挂载。
        if (!mount.el.isConnected) continue;
        canvas.style.width = "100%";
        canvas.style.height = "100%";
        mount.el.appendChild(canvas);
        mount.canvas = canvas;
        // 让出事件循环，滚动/交互不被长渲染阻塞。
        await new Promise((r) => setTimeout(r, 0));
      }
    } finally {
      this.rendering = false;
      if (this.renderQueued) {
        this.renderQueued = false;
        // 延迟一拍再渲染，避免同步递归；滚动中会合并多次触发。
        setTimeout(() => void this.renderVisible(), 16);
      }
    }
  }

  /// 每页的渲染分辨率：显示宽度 × 2（视网膜清晰度）。
  /// 用该页逻辑宽度换算 PDF.js 的 scale，避免硬编码导致超大 canvas
  /// 触发浏览器限制而模糊。双页模式下每页只有展开宽度的一半。
  private canvasScale(page: number): number {
    const layout = this.layouts[page - 1];
    if (!layout) return 2;
    return (layout.width * 2) / layout.logicalWidth;
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
    // 页面可能已被懒渲染卸载（元素不在 DOM 里），此时拿不到准确坐标。
    if (!layout || !mount || !mount.el.isConnected) return null;

    // 用页面元素的实际屏幕位置换算，避免缩放假设。
    const pageRect = mount.el.getBoundingClientRect();
    if (pageRect.width === 0 || pageRect.height === 0) return null;
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
    this.content.innerHTML = "";
    this.content.style.transform = "";
    this.mounted.clear();
    this.layouts = [];
  }
}
