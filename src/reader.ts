// 翻页阅读器：页面从上到下排列并按页导航，懒渲染视口附近的页面；
// 放大后允许页内滚动，并支持缩放、框选区域与页码映射。

import type { PDFDocument } from "./pdf";
import { scaleWithinCanvasBudget } from "./reader-budget";

export interface RegionSelection {
  page: number;
  /// PDF 坐标（scale=1）下的矩形，供 exportRegionAsJPEG 使用。
  rect: { x: number; y: number; width: number; height: number };
}

interface ReaderCallbacks {
  onPageChange?: (page: number) => void;
  onRegionSelected?: (region: RegionSelection) => void;
}

const PAGE_GAP = 14;
const SIDE_MARGIN = 28;
/// 视口上下各预渲染多少页。
const RENDER_RADIUS = 1;

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

  /// 当前缩放：1 = 页面（或展开）恰好放进视口（宽高都不超出）。
  private zoom = 1;
  /// 双页模式（书本展开）：两页并排，缩放按整个展开算。
  private spread = false;
  private layouts: PageLayout[] = [];
  /// mounted 的页面元素。renderScale 记录画布渲染时的缩放，拖动窗口时
  /// 只有缩放明显变化才重渲画布（其余情况用 CSS 缩放旧画布，保持流畅）。
  private mounted = new Map<number, { el: HTMLDivElement; canvas: HTMLCanvasElement | null; renderScale: number }>();
  private rendering = false;
  private renderQueued = false;
  /// layout 代次号：并发 layout 保护（旧代次中途放弃）。
  private layoutGen = 0;

  constructor(surface: HTMLDivElement, doc: PDFDocument, cb: ReaderCallbacks = {}) {
    this.surface = surface;
    this.doc = doc;
    this.cb = cb;
    this.content = document.createElement("div");
    this.content.className = "reader-content";
    this.surface.appendChild(this.content);
  }

  /// 打开：建立页面骨架，滚动到指定页。
  /// initialZoom 是打开时就要用的缩放（1 = 页面恰好放进视口），
  /// spread 为 true 时按双页（书本展开）布局。
  async open(
    targetPage: number,
    initialZoom = 1,
    spread = false,
    options: { signal?: AbortSignal; onStage?: (message: string) => void } = {},
  ): Promise<void> {
    await this.waitForWidth();
    this.zoom = initialZoom;
    this.spread = spread;
    options.onStage?.("正在读取页面信息…");
    await this.layout((completed, total) => {
      options.onStage?.(`正在准备页面… ${Math.round((completed / Math.max(total, 1)) * 100)}%`);
    }, options.signal);
    // 直接渲染目标页附近（跳到上次读的页，不等 scroll 事件异步触发）。
    options.onStage?.(`正在渲染第 ${targetPage} 页…`);
    await this.renderVisible(targetPage, options.signal);
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

  /// 等待滚动容器获得真实尺寸（WebView 初次布局可能晚于脚本执行）。
  /// 宽高都就绪才继续——翻页模式的「适合视口」依赖高度，高度未就绪时
  /// 算出的页面尺寸是错的，会连锁引发页码错乱。
  /// 轮询 requestAnimationFrame，最多等 2 秒；超时也继续，避免永久挂起。
  private waitForWidth(): Promise<void> {
    return new Promise((resolve) => {
      const deadline = performance.now() + 2000;
      const poll = () => {
        if (
          (this.surface.clientWidth > 0 && this.surface.clientHeight > 0) ||
          performance.now() > deadline
        ) {
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

  async layout(
    onProgress?: (completed: number, total: number) => void,
    signal?: AbortSignal,
  ): Promise<void> {
    // 防御：等尺寸就绪（WebView 初次布局晚于脚本执行时，
    // clientWidth/Height 为 0，页面会按错误比例建立、需要手动缩放才正常）。
    await this.waitForWidth();

    // 并发保护：ResizeObserver 可能在 open/commitZoom 的异步 layout 中途
    // 再触发一次 layout。用代次号让旧的 layout 中途放弃，避免两个 layout
    // 交错写坏 layouts（页面 top 不一致 → 页码错乱 → 吸附级联翻到最后一页）。
    const gen = ++this.layoutGen;

    // 重建内容层：移除旧 spacer，保留已挂载的页面元素与画布
    // （拖动窗口重排时只改位置尺寸，画布由 renderVisible 决定是否重渲，
    // 避免每步窗口拖动都重渲扫描页导致卡顿）。
    this.content.querySelector(".scroll-spacer")?.remove();
    this.layouts = [];

    // 分批读取所有页尺寸。PDF.js 仍能精确布局不同纸张，但不会一次
    // 创建整本书的解析任务；批次间会让出事件循环保持取消/重试可用。
    const sizes = await this.doc.pageSizes(1, this.doc.pageCount, { signal, onProgress });
    if (gen !== this.layoutGen) return;

    const surfaceW = this.surface.clientWidth;
    const surfaceH = this.surface.clientHeight;
    const availW = Math.max(surfaceW - SIDE_MARGIN * 2, 100);
    const availH = Math.max(surfaceH - 40, 200);

    // 只计算尺寸/位置数据（供页码映射、滚动定位），不建 DOM——
    // 几百页的书逐页建元素会卡，元素由 renderVisible 按需创建。
    /// 翻页模式的缩放：zoom=1 时页面/展开恰好放进视口（宽高都不超出）。
    const fitScale = (lw: number, lh: number) =>
      Math.min(availW / lw, availH / lh) * this.zoom;

    if (!this.spread) {
      // ---- 单页：每页适合视口，水平居中，从上到下排列 ----
      let top = 0;
      for (let p = 1; p <= this.doc.pageCount; p++) {
        const { width, height } = sizes[p - 1];
        const w = width * fitScale(width, height);
        const h = height * fitScale(width, height);
        this.layouts.push({
          displayHeight: h,
          top,
          left: Math.max(0, (surfaceW - w) / 2),
          width: w,
          logicalWidth: width,
          logicalHeight: height,
        });
        top += h + PAGE_GAP;
      }
      const spacer = document.createElement("div");
      spacer.className = "scroll-spacer";
      spacer.style.height = `${top}px`;
      this.content.appendChild(spacer);
      // 尺寸在计算期间变了（拖动窗口）：用最新尺寸重算，确保停在最终尺寸。
      if (gen === this.layoutGen && (this.surface.clientWidth !== surfaceW || this.surface.clientHeight !== surfaceH)) {
        return this.layout();
      }
      return;
    }

    // ---- 双页（书本展开）：两页并排成一行 ----
    // 第 1 页（封面）单独在右；之后 (2,3)、(4,5)… 偶数页在左、奇数页在右，
    // 像翻开的书。每行按「适合视口」缩放，行高取该行两页的较大者。
    const rowOf = (p: number) => (p <= 1 ? 0 : Math.floor((p - 2) / 2) + 1);
    const numRows = rowOf(this.doc.pageCount);

    let rowTop = 0;
    for (let row = 0; row <= numRows; row++) {
      // 本行的页
      const rowPages: number[] = [];
      for (let p = 1; p <= this.doc.pageCount; p++) {
        if (rowOf(p) === row) rowPages.push(p);
      }
      if (rowPages.length === 0) continue;
      // 行逻辑尺寸（scale=1）
      let rowLW = 0;
      let rowLH = 0;
      for (const p of rowPages) {
        const { width, height } = sizes[p - 1];
        rowLW += width;
        rowLH = Math.max(rowLH, height);
      }
      rowLW += (rowPages.length - 1) * PAGE_GAP; // 页间书缝
      const scale = fitScale(rowLW, rowLH);

      let x = Math.max(0, (surfaceW - rowLW * scale) / 2);
      let rowMaxH = 0;
      for (const p of rowPages) {
        const { width, height } = sizes[p - 1];
        const w = width * scale;
        const h = height * scale;
        rowMaxH = Math.max(rowMaxH, h);
        this.layouts.push({
          displayHeight: h,
          top: rowTop,
          left: x,
          width: w,
          logicalWidth: width,
          logicalHeight: height,
        });
        x += w + PAGE_GAP;
      }
      rowTop += rowMaxH + PAGE_GAP;
    }
    const totalHeight = Math.max(0, rowTop - PAGE_GAP);

    // 关键：绝对定位的页面不撑起滚动容器的内容高度。
    // 必须用一个普通流式占位元素撑高容器，滚动条才会出现，
    // 否则容器自身高度会覆盖窗口高度，页面既看不见也滚不动。
    const spacer = document.createElement("div");
    spacer.className = "scroll-spacer";
    spacer.style.height = `${totalHeight}px`;
    this.content.appendChild(spacer);
    // 尺寸在计算期间变了（拖动窗口）：用最新尺寸重算，确保停在最终尺寸。
    if (gen === this.layoutGen && (this.surface.clientWidth !== surfaceW || this.surface.clientHeight !== surfaceH)) {
      return this.layout();
    }
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
    await this.layout();

    const newLayout = this.layouts[anchorPage - 1];
    if (newLayout) {
      this.surface.scrollTop = newLayout.top + newLayout.displayHeight * ratioInPage - this.surface.clientHeight / 2;
    }
    await this.renderVisible(anchorPage);
    this.emitPage();
  }

  /// 渲染视口附近的页（惰性，已渲染的不重绘）。
  private async renderVisible(aroundPage?: number, signal?: AbortSignal): Promise<void> {
    const center = aroundPage ?? this.currentPage();
    const start = Math.max(1, center - RENDER_RADIUS);
    const end = Math.min(this.doc.pageCount, center + RENDER_RADIUS);

    // 清理视口外过远的页面。
    for (const [p, mount] of this.mounted) {
      if (p < start - RENDER_RADIUS * 2 || p > end + RENDER_RADIUS * 2) {
        mount.el.remove();
        if (mount.canvas) {
          mount.canvas.width = 0;
          mount.canvas.height = 0;
        }
        mount.canvas = null;
        this.mounted.delete(p);
      }
    }

    // 按需创建视口附近的页面元素（惰性骨架），再渲染 canvas。
    // 已挂载的元素只更新位置/尺寸（保留画布）；画布仅在缩放明显变化时重渲。
    const toRender: number[] = [];
    for (let p = start; p <= end; p++) {
      const layout = this.layouts[p - 1];
      if (!layout) continue;
      let mount = this.mounted.get(p);
      if (!mount) {
        const el = document.createElement("div");
        el.className = "scroll-page";
        el.dataset.page = String(p);
        this.content.appendChild(el);
        mount = { el, canvas: null, renderScale: 0 };
        this.mounted.set(p, mount);
      }
      mount.el.style.left = `${layout.left}px`;
      mount.el.style.width = `${layout.width}px`;
      mount.el.style.height = `${layout.displayHeight}px`;
      mount.el.style.top = `${layout.top}px`;
      // 画布分辨率取决于显示缩放（≈ 宽度/逻辑宽）。缩放变化 >8% 才重渲，
      // 其余情况（小范围拖动窗口）CSS 缩放旧画布即可，保持流畅。
      const scale = layout.width / layout.logicalWidth;
      if (!mount.canvas || Math.abs(scale - mount.renderScale) / Math.max(scale, mount.renderScale, 0.001) > 0.08) {
        toRender.push(p);
      }
    }
    if (toRender.length === 0) return;

    if (this.rendering) {
      this.renderQueued = true;
      return;
    }
    this.rendering = true;
    try {
      for (const p of toRender) {
        if (signal?.aborted) {
          const error = new Error("已取消打开 PDF。");
          error.name = "PDFLoadCancelledError";
          throw error;
        }
        // 渲染前再次检查：如果这一页已滚出视口附近（用户滚走了），
        // 跳过它，优先渲染当前视口的页，避免"加载不出来"。
        const now = this.currentPage();
        if (p < now - RENDER_RADIUS || p > now + RENDER_RADIUS) continue;
        const mount = this.mounted.get(p);
        if (!mount || !mount.el.isConnected) continue;
        const canvas = await this.doc.renderPageToCanvas(p, this.canvasScale(p), signal);
        // 渲染耗时较长，期间视口可能又变了；只有页还在时才挂载。
        if (!mount.el.isConnected) continue;
        canvas.style.width = "100%";
        canvas.style.height = "100%";
        mount.el.appendChild(canvas);
        mount.canvas = canvas;
        const layout = this.layouts[p - 1];
        mount.renderScale = layout ? layout.width / layout.logicalWidth : 0;
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
    const requested = (layout.width * 2) / layout.logicalWidth;
    return scaleWithinCanvasBudget(layout.logicalWidth, layout.logicalHeight, requested);
  }

  /// 当前视口中心所在页（双页时按中心点横坐标落在左/右页）。
  currentPage(): number {
    // pageAtPoint 的参数是「视口坐标」：它内部会加 scrollTop 换算文档位置，
    // 并把 clientX/Y 与页面元素的屏幕矩形比较。这里只传视口中心即可，
    // 不能传 scrollTop + 中心（会重复加 scrollTop → 页码约翻倍 → 吸附级联到最后一页）。
    return this.pageAtPoint(this.surface.clientWidth / 2, this.surface.clientHeight / 2);
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

  /// 屏幕坐标（clientX/Y）落在哪一页。单页模式按纵坐标即可；
  /// 双页模式同一行左右两页的纵坐标相同，必须用横坐标区分——
  /// 返回矩形包含该点的页面；书缝等空白处选横向上最近的一页
  /// （双页时书缝居中，会选左页，页码显示与主流阅读器一致）。
  private pageAtPoint(clientX: number, clientY: number): number {
    const near = this.pageAtOffset(clientY + this.surface.scrollTop);
    let best = near;
    let bestDist = Infinity;
    for (let p = Math.max(1, near - 1); p <= Math.min(this.doc.pageCount, near + 1); p++) {
      const mount = this.mounted.get(p);
      if (!mount || !mount.el.isConnected) continue;
      const r = mount.el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (clientX >= r.left && clientX <= r.right && clientY >= r.top && clientY <= r.bottom) {
        return p; // 点明确落在这页里
      }
      const dist = Math.abs(clientX - (r.left + r.width / 2));
      // 注意用严格 <：双页模式下左页与下一行左页的水平距离相同（都居中），
      // 若用 <= 会把「当前行」换成「下一行」→ 吸附每拍前进一行，级联到最后一页。
      if (dist < bestDist) {
        bestDist = dist;
        best = p; // 平手取更小页号（当前行的左页）
      }
    }
    return best;
  }

  /// 翻页模式：前后翻（双页按行翻，单页按页翻），目标页垂直居中。
  flipPage(delta: 1 | -1): void {
    const step = this.spread ? 2 : 1;
    const from = this.currentPage();
    const target = Math.max(1, Math.min(this.doc.pageCount, from + step * delta));
    this.scrollToPage(target, false);
  }

  /// 当前页是否整页放得进视口（放得进 → 滚轮/触控板翻页；
  /// 放不进（放大后页面超高）→ 允许在页内滚动）。
  pageFitsViewport(): boolean {
    const layout = this.layouts[this.currentPage() - 1];
    if (!layout) return true;
    return layout.displayHeight <= this.surface.clientHeight;
  }

  scrollToPage(page: number, instant = false): void {
    const layout = this.layouts[page - 1];
    if (!layout) return;
    let target = layout.top;
    if (layout.displayHeight <= this.surface.clientHeight) {
      // 页面放得下：垂直居中。
      target = layout.top - (this.surface.clientHeight - layout.displayHeight) / 2;
    }
    // 页面比视口高：对齐顶部，用户可在页内滚动（翻页模式只在跨页时吸附）。
    const max = Math.max(0, this.surface.scrollHeight - this.surface.clientHeight);
    target = Math.max(0, Math.min(target, max));
    this.surface.scrollTo({ top: target, behavior: instant ? "auto" : "smooth" });
  }

  /// 滚动事件处理：更新页码、惰性渲染。
  /// 翻页模式下滚轮/触控板由 main.ts 拦截为翻页（无自由滚动，也就没有吸附环节）。
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

    // 屏幕坐标（含滚动）落在哪一页：按选区中心点定位，
    // 双页模式下同一行左右页纵坐标相同，中心点落在哪页就选哪页。
    const page = this.pageAtPoint(x + w / 2, y + h / 2);
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
    for (const mount of this.mounted.values()) {
      if (mount.canvas) {
        mount.canvas.width = 0;
        mount.canvas.height = 0;
      }
    }
    this.content.innerHTML = "";
    this.content.style.transform = "";
    this.mounted.clear();
    this.layouts = [];
  }
}
