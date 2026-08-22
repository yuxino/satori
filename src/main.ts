// Satori 3.0 主入口：一本书，旁边坐着一个老师。
import "./styles.css";
import { open } from "@tauri-apps/plugin-dialog";
import { convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// 菜单「设置…」触发打开设置面板。
void listen("open-settings", () => {
  openSettings();
});

// 白屏时把错误显示出来，便于定位（而不是一片空白）。
window.addEventListener("error", (e) => {
  showFatalError(String(e.error ?? e.message ?? "未知错误"));
});
window.addEventListener("unhandledrejection", (e) => {
  showFatalError(String(e.reason ?? "未处理的 Promise 错误"));
});

function showFatalError(message: string) {
  const root = document.getElementById("reader-surface");
  if (!root) return;
  if (root.querySelector("#fatal-error")) return;
  const div = document.createElement("div");
  div.id = "fatal-error";
  div.style.cssText =
    "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:#f7f4ee;z-index:100;font:14px/1.7 -apple-system,'PingFang SC',sans-serif;color:#8a2b2b;padding:40px;text-align:left;white-space:pre-wrap;";
  div.textContent = `出错了：\n${message}`;
  root.appendChild(div);
}

import {
  askVisual,
  credentialStatus,
  emptyStore,
  extractOutline,
  findPageByTitle,
  loadStore,
  resolveBookPath,
  saveStore,
  loadThumb,
  saveThumb,
  type AIProfile,
  type BookRecord,
  type HistoryTurn,
  type OutlineEntry,
  type QAEntry,
  type Settings,
  type Store,
} from "./api";
import { PDFDocument } from "./pdf";
import { ScrollReader, type RegionSelection } from "./reader";
import { renderMarkdown } from "./markdown";
import { openAISettings } from "./settings";

// ---- DOM ----
const readerSurface = document.getElementById("reader-surface") as HTMLDivElement;
const teacherSheet = document.getElementById("teacher-sheet") as HTMLDivElement;
const tocDrawer = document.getElementById("toc-drawer") as HTMLDivElement;
const bottomBar = document.getElementById("bottom-bar") as HTMLDivElement;
const homeView = document.getElementById("home-view") as HTMLDivElement;

// ---- 状态 ----
let store: Store = emptyStore();
let activeCredentialSaved = false;
let credentialRefreshGeneration = 0;
let currentBook: BookRecord | null = null;
let currentDoc: PDFDocument | null = null;
let reader: ScrollReader | null = null;
let currentPage = 1;
/// 用户缩放倍数：1 = 页面宽度铺满窗口，可 ⌘+/⌘- 调整。
let zoomFactor = 1;
let history: HistoryTurn[] = [];
let streaming = false;

/// 框选状态。
let regionOverlay: HTMLDivElement | null = null;
let regionStart: { x: number; y: number } | null = null;
let regionActive = false;

// ---- 学习活动统计（总览热力格子图的数据） ----

/// 本地时区的 "YYYY-MM-DD"。
function dateKey(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function todayKey(): string {
  return dateKey(new Date());
}

/// 给当天的活动量 +n（pages 或 questions），不落盘（随下次 persist 一起写）。
function bumpActivity(kind: "pages" | "questions", n: number) {
  if (n <= 0) return;
  const key = todayKey();
  const day = store.activity[key] ?? { pages: 0, questions: 0 };
  day[kind] += n;
  store.activity[key] = day;
}

/// 翻页时累计当天阅读页数（由 persistReadingPosition 防抖落盘）。
let todayPagesPending = 0;
function markPageViewed() {
  todayPagesPending++;
}

function activeProfile(): AIProfile | null {
  const id = store.settings.active_profile_id;
  return store.settings.profiles.find((profile) => profile.id === id) ?? null;
}

async function refreshActiveCredentialStatus(): Promise<void> {
  const generation = ++credentialRefreshGeneration;
  activeCredentialSaved = false;
  const profile = activeProfile();
  if (!profile || !profile.api_key_required) {
    if (generation === credentialRefreshGeneration) activeCredentialSaved = Boolean(profile);
    return;
  }
  const saved = await credentialStatus(profile.id)
    .then((status) => status.saved)
    .catch(() => false);
  if (generation === credentialRefreshGeneration && activeProfile()?.id === profile.id) {
    activeCredentialSaved = saved;
  }
}

/** 当前连接是否足以发起请求；不会静默回退到别的服务。 */
function usableActiveProfile(): AIProfile | null {
  const profile = activeProfile();
  if (!profile || !profile.name.trim() || !profile.model_id.trim() || !profile.base_url.trim()) return null;
  if (profile.api_key_required && !activeCredentialSaved) return null;
  return profile;
}

// ---- 启动 ----
async function boot() {
  // 数据损坏或格式较新时必须明确失败，不能构造默认 provider 后继续写入。
  store = await loadStore();
  await refreshActiveCredentialStatus();

  if (store.books.length > 0 && !usableActiveProfile()) {
    // 有书但没有可用连接：先请用户完成 AI 服务配置。
    openSettings("先完成一个 AI 服务连接，老师才能读取书页。");
  }
  showHome();
  setupReaderSurface();
  setupAskFab();
  setupSheetDrag();
  setupOutsideClickClose();

  // 阅读面尺寸变化时重新铺满（保留当前页）。用 ResizeObserver 监听
  // 阅读面本身，比 window resize 更可靠——初次加载时窗口事件可能丢失，
  // 而 ResizeObserver 在 WebView 真正完成布局后必然触发一次。
  const resizeObserver = new ResizeObserver(() => {
    if (!reader || !currentDoc || openingBook) return; // 打开书进行中：跳过，避免读到半成品布局
    window.clearTimeout(observerTimer);
    observerTimer = window.setTimeout(() => void relayoutOnResize(), 120);
  });
  resizeObserver.observe(readerSurface);
}

let observerTimer: number | undefined;
/// 打开书进行中（openBook 的异步加载/布局期间）。
let openingBook = false;

async function relayoutOnResize() {
  if (!reader || !currentDoc || openingBook) return;
  const anchor = reader.currentPage();
  await reader.setZoom(zoomFactor);
  reader.scrollToPage(anchor, true);
  void reader.onScroll();
}

// ---- 首页 / 总览 ----

/// 显示首页（总览）：覆盖在阅读面上滑入，当前阅读状态保留在下面，
/// 关闭后立即回到原位（不重载）。
function showHome() {
  tocDrawer.classList.remove("open");
  renderHome();
  homeView.classList.add("open");
  closeTeacherSheet();
}

function hideHome() {
  homeView.classList.remove("open");
}

function renderHome() {
  homeView.innerHTML = "";

  const wrap = document.createElement("div");
  wrap.className = "home-wrap";

  // 标题 + （正在读书时）返回按钮
  const header = document.createElement("div");
  header.className = "home-header";
  const brand = document.createElement("div");
  brand.className = "home-brand";
  const logo = document.createElement("span");
  logo.className = "home-logo";
  logo.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.5l2.4 7.1 7.1 2.4-7.1 2.4L12 21.5l-2.4-7.1-7.1-2.4 7.1-2.4z" /></svg>`;
  const title = document.createElement("h1");
  title.textContent = "satori";
  brand.append(logo, title);
  const sub = document.createElement("p");
  sub.textContent = "读懂你手上的 PDF";
  header.append(brand, sub);
  if (currentDoc) {
    const closeBtn = document.createElement("button");
    closeBtn.className = "home-close";
    closeBtn.textContent = "× 返回阅读";
    closeBtn.title = "回到刚才读的位置";
    closeBtn.addEventListener("click", hideHome);
    header.appendChild(closeBtn);
  }
  wrap.appendChild(header);

  // 学习活动热力格子图
  const activitySection = document.createElement("section");
  activitySection.className = "home-section";
  const activityTitle = document.createElement("h2");
  activityTitle.textContent = "学习活动";
  activitySection.appendChild(activityTitle);

  // 统计行
  const stats = document.createElement("div");
  stats.className = "home-stats";
  const days = Object.keys(store.activity).length;
  const pages = Object.values(store.activity).reduce((s, a) => s + a.pages, 0);
  const qs = store.qa.length;
  stats.append(
    statChip(`${computeStreak()}`, "连续学习（天）"),
    statChip(`${days}`, "学习天数"),
    statChip(`${pages}`, "阅读页数"),
    statChip(`${qs}`, "提问次数"),
  );
  activitySection.appendChild(stats);

  activitySection.appendChild(buildActivityGrid());

  // 图例：少 → 多
  const legend = document.createElement("div");
  legend.className = "home-legend";
  legend.append(document.createTextNode("少"));
  for (let lv = 0; lv <= 4; lv++) {
    const swatch = document.createElement("span");
    swatch.className = `grid-cell level-${lv}`;
    legend.appendChild(swatch);
  }
  legend.append(document.createTextNode("多"));
  activitySection.appendChild(legend);
  wrap.appendChild(activitySection);

  // 我的书
  const booksSection = document.createElement("section");
  booksSection.className = "home-section";
  const booksTitle = document.createElement("h2");
  booksTitle.textContent = "我的书";
  booksSection.appendChild(booksTitle);

  if (store.books.length === 0) {
    const empty = document.createElement("div");
    empty.className = "home-empty";
    empty.textContent = "还没有书。打开一本 PDF，开始读懂它。";
    booksSection.appendChild(empty);
  } else {
    const list = document.createElement("div");
    list.className = "home-books";
    for (const book of store.books) list.appendChild(buildBookCard(book));
    booksSection.appendChild(list);
  }
  const openBtn = document.createElement("button");
  openBtn.className = "open-book home-open";
  openBtn.textContent = store.books.length === 0 ? "打开一本书" : "添加一本书";
  openBtn.addEventListener("click", () => void pickAndOpenBook());
  booksSection.appendChild(openBtn);
  wrap.appendChild(booksSection);

  // 最近提问
  const recent = store.qa
    .slice()
    .sort((a, b) => b.ts - a.ts)
    .slice(0, 5);
  if (recent.length > 0) {
    const qaSection = document.createElement("section");
    qaSection.className = "home-section";
    const qaTitle = document.createElement("h2");
    qaTitle.textContent = "最近提问";
    qaSection.appendChild(qaTitle);
    const qaList = document.createElement("div");
    qaList.className = "home-recent";
    for (const entry of recent) {
      const book = store.books.find((b) => b.id === entry.book_id);
      const item = document.createElement("button");
      item.className = "home-recent-item";
      const badge = document.createElement("span");
      badge.className = "home-recent-badge";
      badge.textContent = `${book?.name.replace(/\.pdf$/i, "") ?? "书"} · P${entry.page}`;
      const q = document.createElement("span");
      q.className = "home-recent-q";
      q.textContent = entry.question.length > 40 ? `${entry.question.slice(0, 40)}…` : entry.question;
      item.append(badge, q);
      item.addEventListener("click", () => {
        const target = store.books.find((b) => b.id === entry.book_id);
        if (target) void openBook(target);
      });
      qaList.appendChild(item);
    }
    qaSection.appendChild(qaList);
    wrap.appendChild(qaSection);
  }

  homeView.appendChild(wrap);
}

function statChip(value: string, label: string): HTMLDivElement {
  const chip = document.createElement("div");
  chip.className = "home-stat";
  const v = document.createElement("b");
  v.textContent = value;
  const l = document.createElement("span");
  l.textContent = label;
  chip.append(v, l);
  return chip;
}

/// 最近一年的 GitHub 风格热力格子图（52 列 × 7 行，铺满容器，格子正方形）。
function buildActivityGrid(): HTMLDivElement {
  const weeks = 52;
  const today = new Date();
  const monday = new Date(today);
  monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));

  const grid = document.createElement("div");
  grid.className = "activity-grid";

  // 月份标签：第 1 行，放在月份变更的那一列。
  let prevMonth = -1;
  for (let w = weeks - 1; w >= 0; w--) {
    const date = new Date(monday);
    date.setDate(monday.getDate() - w * 7);
    if (date.getMonth() !== prevMonth) {
      const label = document.createElement("div");
      label.className = "grid-month-label";
      label.textContent = `${date.getMonth() + 1}月`;
      label.style.gridColumn = String(weeks - w + 1);
      label.style.gridRow = "1";
      grid.appendChild(label);
      prevMonth = date.getMonth();
    }
  }

  // 星期提示（第 1 列，行 2-8：一 / 三 / 五）。
  const weekdayNames = ["一", "", "三", "", "五", "", ""];
  for (let dow = 0; dow < 7; dow++) {
    if (!weekdayNames[dow]) continue;
    const l = document.createElement("div");
    l.className = "grid-weekday";
    l.textContent = weekdayNames[dow];
    l.style.gridColumn = "1";
    l.style.gridRow = String(dow + 2);
    grid.appendChild(l);
  }

  // 52 × 7 个格子。
  for (let w = weeks - 1; w >= 0; w--) {
    for (let dow = 0; dow < 7; dow++) {
      const date = new Date(monday);
      date.setDate(monday.getDate() - w * 7 + dow);
      const key = dateKey(date);
      const act = store.activity[key];
      const score = act ? act.pages + act.questions * 5 : 0;
      const cell = document.createElement("div");
      cell.className = `grid-cell level-${activityLevel(score)}`;
      cell.title = `${key}　阅读 ${act?.pages ?? 0} 页 · 提问 ${act?.questions ?? 0}`;
      if (date.getTime() > today.getTime()) cell.classList.add("future");
      cell.style.gridColumn = String(weeks - w + 1);
      cell.style.gridRow = String(dow + 2);
      grid.appendChild(cell);
    }
  }
  return grid;
}

/// 连续学习天数：从今天（今天没学则从昨天）往前数连续有活动的天数。
function computeStreak(): number {
  let streak = 0;
  const cursor = new Date();
  if (!store.activity[dateKey(cursor)]) cursor.setDate(cursor.getDate() - 1);
  while (store.activity[dateKey(cursor)]) {
    streak++;
    cursor.setDate(cursor.getDate() - 1);
  }
  return streak;
}

/// 活动量 → 格子颜色档位（0-4）。
function activityLevel(score: number): number {
  if (score <= 0) return 0;
  if (score <= 2) return 1;
  if (score <= 5) return 2;
  if (score <= 10) return 3;
  return 4;
}

function buildBookCard(book: BookRecord): HTMLDivElement {
  const card = document.createElement("div");
  card.className = "home-book";

  // 左侧迷你封面：读缓存好的第 1 页缩略图；没有缓存就放一个占位块。
  const cover = document.createElement("div");
  cover.className = "home-book-cover";
  const initial = (book.name.replace(/\.pdf$/i, "") || "书").slice(0, 1);
  cover.textContent = initial;
  void loadThumb(book.path, 1)
    .then((b64) => {
      if (!b64 || !cover.isConnected) return;
      const img = document.createElement("img");
      img.src = `data:image/jpeg;base64,${b64}`;
      img.alt = "";
      cover.textContent = "";
      cover.appendChild(img);
    })
    .catch(() => undefined);

  const body = document.createElement("div");
  body.className = "home-book-body";

  const name = document.createElement("div");
  name.className = "home-book-name";
  name.textContent = book.name.replace(/\.pdf$/i, "");

  const meta = document.createElement("div");
  meta.className = "home-book-meta";
  const qCount = store.qa.filter((q) => q.book_id === book.id).length;
  const total = book.pageCount;
  const pct = total && total > 0 ? Math.min(100, Math.round((book.last_page / total) * 100)) : 0;
  meta.textContent = total
    ? `第 ${book.last_page} / ${total} 页 · 问过 ${qCount} 次`
    : `读到了第 ${book.last_page} 页 · 问过 ${qCount} 次`;
  body.appendChild(name);
  body.appendChild(meta);

  const barRow = document.createElement("div");
  barRow.className = "home-progress-row";
  if (total && total > 0) {
    const bar = document.createElement("div");
    bar.className = "home-progress";
    const fill = document.createElement("div");
    fill.className = "home-progress-fill";
    fill.style.width = `${pct}%`;
    bar.appendChild(fill);
    barRow.appendChild(bar);
    const pctLabel = document.createElement("span");
    pctLabel.className = "home-progress-pct";
    pctLabel.textContent = `${pct}%`;
    barRow.appendChild(pctLabel);
    body.appendChild(barRow);
  }

  // 悬停提示「继续阅读」
  const hint = document.createElement("span");
  hint.className = "home-book-hint";
  hint.textContent = book.id === currentBook?.id ? "返回阅读 →" : "继续阅读 →";
  body.appendChild(hint);

  card.append(cover, body);
  card.addEventListener("click", () => void openBook(book));
  return card;
}

async function pickAndOpenBook() {
  const selected = await open({
    multiple: false,
    filters: [{ name: "PDF", extensions: ["pdf"] }],
  });
  if (typeof selected !== "string") return;
  const book: BookRecord = {
    id: crypto.randomUUID(),
    name: selected.split("/").pop() ?? selected,
    path: selected,
    last_page: 1,
    added_at: Date.now(),
    outline: [],
  };
  store.books = [book, ...store.books.filter((b) => b.id !== book.id)];
  await persist();
  await openBook(book);
}

// ---- 打开书 ----
async function openBook(book: BookRecord) {
  // 点的就是当前这本书：只关掉首页回到原位，不重载。
  if (book.id === currentBook?.id && currentDoc) {
    hideHome();
    return;
  }
  showLoading("正在打开书…");
  hideHome();
  openingBook = true;
  try {
    const resolved = await resolveBookPath(book);
    currentBook = resolved;
    const url = convertFileSrc(resolved.path);

    // 换书前清理旧状态：销毁旧文档释放 worker/内存、重置对话历史、
    // 收起面板与菜单，避免跨书串扰。
    reader?.clear();
    currentDoc?.destroy();
    currentDoc = null;
    reader = null;
    history = [];
    sheetQA = null;
    closeTeacherSheet();
    tocDrawer.classList.remove("open");
    bookMenuEl?.remove();
    bookMenuEl = null;
    // 重置缩略图渲染状态，避免旧书的 busy/预热标志卡住新书。
    thumbnailBusy = false;
    thumbnailQueued = false;
    preheating = false;
    preheatPaused = false;
    window.clearTimeout(thumbVirtualTimer);
    hideLoading();

    currentDoc = await PDFDocument.load(url, (loaded, total) => {
      if (total > 0) updateLoading(`正在打开书… ${Math.round((loaded / total) * 100)}%`);
    });
    // 记录总页数（首页进度条用）。
    if (resolved.pageCount !== currentDoc.pageCount) {
      resolved.pageCount = currentDoc.pageCount;
      store.books = store.books.map((b) => (b.id === resolved.id ? resolved : b));
    }
    currentPage = Math.min(Math.max(resolved.last_page, 1), currentDoc.pageCount);
    // 恢复这本书自己的缩放倍数；没记过就是 1（适合宽度）。
    // 每本书记住各自的缩放，切书时不会互相串。
    zoomFactor = clampZoom(resolved.zoom ?? 1);
    readerSurface.innerHTML = "";
    bottomBar.style.display = "flex";
    reader = new ScrollReader(readerSurface, currentDoc, {
      onPageChange: (page) => {
        currentPage = page;
        markPageViewed();
        schedulePersistPosition();
        scheduleBottomBarUpdate();
      },
      onRegionSelected: (region) => {
        void askRegionQuestion(region);
      },
    });
    // 打开时直接应用这本书的缩放与布局（单页/双页），
    // 避免先按 100% 渲染再跳变。
    await reader.open(currentPage, zoomFactor, resolved.spread === true);
    ensureScrollListener();
    hideLoading();
    renderBottomBar();
    showReopenCue(resolved);
    buildTOC();
    // 扫描书无内置目录时自动识别。延迟到开书高峰（首屏渲染 + 缩略图预热）之后，
    // 避免 3x 高清目录页渲染与首屏抢资源导致卡顿。
    window.setTimeout(() => {
      void maybeExtractScannedOutline();
    }, 1500);
    // 更新书籍列表（路径可能被修正）。
    store.books = store.books.map((b) => (b.id === resolved.id ? resolved : b));
    await persist();
  } catch (err) {
    hideLoading();
    readerSurface.innerHTML = `
      <div id="empty-state">
        <div class="hint">打不开这本书：${String(err)}</div>
        <button class="open-book">换一本</button>
      </div>`;
    readerSurface.querySelector(".open-book")!.addEventListener("click", () => void pickAndOpenBook());
  } finally {
    openingBook = false;
  }
}

// ---- 加载提示（打开大书时不白屏） ----
function showLoading(message: string) {
  hideLoading();
  const overlay = document.createElement("div");
  overlay.id = "loading-overlay";
  const spinner = document.createElement("span");
  spinner.className = "spinner";
  const text = document.createElement("span");
  text.textContent = message;
  overlay.append(spinner, text);
  readerSurface.appendChild(overlay);
}

/// 更新加载提示文字（如进度百分比）。
function updateLoading(text: string) {
  const overlay = readerSurface.querySelector("#loading-overlay") as HTMLElement | null;
  if (!overlay) return;
  const t = overlay.querySelector("span:last-child") as HTMLElement | null;
  if (t) t.textContent = text;
  else overlay.textContent = text;
}

function hideLoading() {
  readerSurface.querySelector("#loading-overlay")?.remove();
}

/// 滚动监听只绑定一次（换书时 reader 变化，但监听器要复用）。
let scrollListenerBound = false;
function ensureScrollListener() {
  if (scrollListenerBound) return;
  scrollListenerBound = true;
  readerSurface.addEventListener("scroll", () => void reader?.onScroll(), { passive: true });
}

// ---- 渲染：连续滚动阅读器接管，这里只做滚动/缩放入口 ----

// ---- 重开提示 ----
function showReopenCue(book: BookRecord) {
  if (book.last_page <= 1) return;
  const cue = document.createElement("div");
  cue.id = "reopen-cue";
  cue.innerHTML = `上次读到第 ${book.last_page} 页`;
  const resume = document.createElement("button");
  resume.textContent = "回到那里";
  resume.addEventListener("click", () => {
    currentPage = book.last_page;
    cue.remove();
    if (reader) {
      reader.scrollToPage(book.last_page, true);
      void reader.onScroll();
    }
  });
  cue.appendChild(resume);
  readerSurface.appendChild(cue);
  window.setTimeout(() => cue.remove(), 6000);
}

// ---- 目录 ----
/// 当前书的有效目录（内置大纲清洗后 / 扫描恢复的持久化目录），
/// 供底部栏「当前章节」指示使用。
let effectiveOutline: OutlineEntry[] = [];

function buildTOC() {
  tocDrawer.innerHTML = "";

  // PDF 目录（章节快速跳转）。
  const tocTitle = document.createElement("div");
  tocTitle.className = "toc-section-title";
  tocTitle.textContent = "目录";
  tocDrawer.appendChild(tocTitle);

  const renderOutline = (outline: OutlineEntry[], sourceNote: string) => {
    if (!tocDrawer.isConnected) return;
    if (outline.length === 0) {
      const empty = document.createElement("div");
      empty.className = "toc-item depth-2";
      empty.textContent = sourceNote || "这本书还没有目录。";
      tocDrawer.appendChild(empty);
      return;
    }
    for (const item of outline) {
      const el = document.createElement("div");
      el.className = `toc-item depth-${Math.min(item.depth + 1, 3)}`;
      el.textContent = item.title;
      el.title = `跳到第 ${item.page} 页`;
      el.addEventListener("click", () => {
        tocDrawer.classList.remove("open");
        if (reader) {
          reader.scrollToPage(item.page);
          void reader.onScroll();
        }
      });
      tocDrawer.appendChild(el);
    }
  };

  if (currentDoc) {
    void currentDoc.getOutline().then((native) => {
      if (native.length > 0) {
        // PDF 自带大纲优先。同样清洗前置内容（封面/前言/考试大纲/参考答案…），
        // 与扫描目录识别保持一致。
        const cleaned = cleanOutline(native.map((n) => ({ title: n.title, page: n.page, depth: n.depth })));
        effectiveOutline = cleaned;
        renderOutline(cleaned, "");
        scheduleBottomBarUpdate();
        return;
      }
      // 无内置大纲：用持久化的扫描恢复目录（若有）。
      const errHint = currentBook ? sessionStorage.getItem(`outline-err-${currentBook.id}`) : null;
      const fallback = errHint ? `目录识别失败：${errHint}` : "这本书没有目录（打开时会尝试自动识别）。";
      effectiveOutline = currentBook?.outline ?? [];
      renderOutline(currentBook?.outline ?? [], fallback);
      scheduleBottomBarUpdate();
    });
  } else {
    effectiveOutline = [];
    renderOutline(currentBook?.outline ?? [], "打开一本书后这里会显示目录。");
  }
}

// ---- 扫描书目录恢复（自动） ----
/// 本次会话已尝试过目录恢复的书（避免失败后每次打开都重试烧 API）。
const outlineAttempted = new Set<string>();

/// 判断标题是否为「前置/考试说明类」条目（封面、前言、大纲、考核目标、
/// 题型举例、参考答案、附录、参考文献、后记 等），这些不该出现在章节目录里。
/// 标题常带前缀：罗马数字（I II III…）、书名前缀，所以不只匹配开头词，
/// 还查「包含词」与「前缀」两类形态。
function isFrontMatterTitle(title: string): boolean {
  const t = title.trim();
  const frontMatterRe =
    /^(编者的话|前言|序|目录|绪论|大纲|课程性质|考核目标|课程内容|考核要求|题型举例|参考答案|附录|参考文献|后记|致谢|出版说明|内容简介|学习目标|使用说明|自学考试|组编)/;
  const frontMatterContains = /(考试大纲|自学考试|考核目标|考核要求|题型举例|参考答案|课程性质|课程内容|课程目标|出版说明)/;
  const frontMatterPrefix = /^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩIVX]+[、.\s:：]|^第[一二三四五六七八九十百]+部分/;
  return frontMatterRe.test(t) || frontMatterContains.test(t) || frontMatterPrefix.test(t);
}

/// 目录清洗：先丢掉第一个「第X章/篇」条目之前的所有条目（封面/前言/大纲/
/// 参考答案 等前置内容），再做关键字过滤。若过滤后为空则原样返回——
/// 宁可保留原目录，也不给用户一个空目录。
function cleanOutline(entries: OutlineEntry[]): OutlineEntry[] {
  const firstChapter = entries.findIndex((e) => /第[一二三四五六七八九十\d]+[章篇]/.test(e.title));
  const body = firstChapter > 0 ? entries.slice(firstChapter) : entries;
  const filtered = body.filter((e) => !isFrontMatterTitle(e.title));
  return filtered.length > 0 ? filtered : entries;
}

/// 打开书时调用：PDF 无内置大纲且没有持久化目录时，
/// 用 Qwen 读目录页提取章节，再定位第一章算出偏移，映射成 PDF 页码。
async function maybeExtractScannedOutline() {
  const profile = usableActiveProfile();
  if (!currentDoc || !profile) return;
  if (!currentBook) return;
  // 捕获本次处理的书身份：延迟调用期间可能已切书，检测到变化立即放弃。
  const bookId = currentBook.id;
  const doc = currentDoc;
  // 已有目录（内置或之前恢复过）就不再处理。
  if (currentBook.outline.length > 0) return;
  // 本会话已试过且失败，不再重试（避免每次打开都花两次 API）。
  if (outlineAttempted.has(bookId)) return;
  outlineAttempted.add(bookId);

  const native = await doc.getOutline();
  if (native.length > 0) return;
  // 提取大纲期间用户切书了：放弃。
  if (currentDoc !== doc || currentBook?.id !== bookId) return;

  const pageCount = doc.pageCount;
  // 目录通常在书前部；取第 3-6 页（跳过封面/书名页/前 1-2 页）。
  // 4 页 + 1.3x 是请求大小与覆盖面的折中：太多/太大导致百炼视觉处理超时。
  const frontFrom = 3;
  const frontTo = Math.min(pageCount, 6);
  if (frontTo <= frontFrom) return;

  // 目录识别的渲染阶段需要独占 PDF.js worker；暂停缩略图预热，
  // 否则整书预热排队挤占渲染，识别会慢几十秒甚至超时。
  preheatPaused = true;
  try {
    // 1) 渲染目录候选页 → Qwen 提取目录（印刷页码）。
    const pages = await exportEvidence([...Array(frontTo - frontFrom + 1)].map((_, i) => frontFrom + i), 1.3);
    if (currentDoc !== doc || currentBook?.id !== bookId) return;
    const entries = await extractOutline(profile.id, { pages });
    if (entries.length === 0) return;
    if (currentDoc !== doc || currentBook?.id !== bookId) return;

    // 清洗目录：去前置/考试说明条目（封面/前言/考试大纲/考核目标/题型举例/
    // 参考答案 等），与内置目录的清洗规则一致。
    const bodyEntries = cleanOutline(entries);
    if (bodyEntries.length === 0) return;

    // 2) 找第一章：优先选标题带「第X章」的 depth=0 条目（取最小印刷页），
    // 避免把未过滤的前置项（如「软件工程自学考试大纲」）当第一章。
    const chapters = bodyEntries.filter((e) => e.depth === 0 && /第[一二三四五六七八九十\d]+[章篇]/.test(e.title));
    const fallbackChapters = bodyEntries.filter((e) => e.depth === 0);
    const firstChapter = (chapters.length > 0 ? chapters : fallbackChapters).reduce((a, b) =>
      b.page < a.page ? b : a,
    );
    // 候选正文页：第一章印刷 21 + 前置约 5-15 = PDF 约 26-36。
    // 扫 PDF 20 到 min(45, 书页数)，每 2 页取样控制请求大小。
    const probeFrom = Math.min(Math.max(20, 1), pageCount);
    const probeTo = Math.min(pageCount, Math.max(probeFrom + 1, 45));
    const probePages = await exportEvidence(
      [...Array(Math.max(1, Math.ceil((probeTo - probeFrom + 1) / 2)))].map((_, i) => probeFrom + i * 2),
      1.3,
    );
    if (currentDoc !== doc || currentBook?.id !== bookId) return;
    const foundPdfPage = await findPageByTitle(profile.id, firstChapter.title, probePages);
    if (foundPdfPage === 0) return; // 定位失败，放弃（保留无目录状态）。
    if (currentDoc !== doc || currentBook?.id !== bookId) return;

    // 偏移 = 第一章实际 PDF 页 - 第一章印刷页。
    const offset = foundPdfPage as number - firstChapter.page;

    // 3) 映射所有条目为 PDF 页码并持久化。
    const mapped: OutlineEntry[] = bodyEntries
      .map((e) => ({ title: e.title, depth: e.depth, page: e.page + offset }))
      .filter((e) => e.page >= 1 && e.page <= pageCount);
    if (mapped.length === 0) return;

    currentBook.outline = mapped;
    store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
    await persist();
    // 目录抽屉开着的话刷新。
    if (tocDrawer.classList.contains("open")) buildTOC();
  } catch (err) {
    // 恢复失败：记录原因（目录抽屉可显示），保持无目录状态不打扰阅读。
    try {
      sessionStorage.setItem(`outline-err-${bookId}`, String(err));
    } catch {
      /* ignore */
    }
  } finally {
    // 识别结束（成功/失败/放弃）都恢复缩略图预热。
    preheatPaused = false;
  }
}

async function reopenQA(entry: QAEntry) {
  if (!currentDoc) return;
  currentPage = Math.min(Math.max(entry.page, 1), currentDoc.pageCount);
  persistReadingPosition();
  if (reader) {
    reader.scrollToPage(currentPage);
    void reader.onScroll();
  }
  // 在老师面板里展示这条历史问答（记录为当前问答，可从「问过的」返回）。
  sheetQA = { question: entry.question, answer: entry.answer };
  sheetHistoryMode = false;
  renderQAIntoSheet(entry.question, entry.answer);
}

// ---- 提问：整页 ----
async function askPageQuestion() {
  const question = "这一页在讲什么？用大白话讲。";
  await askQuestion(question);
}

// ---- 提问：框选区域（扫描版也能用） ----
async function askRegionQuestion(region: RegionSelection) {
  const profile = usableActiveProfile();
  if (!currentDoc || !profile) {
    openSettings("请先选择一个已配置的 AI 服务，再解释这处内容。");
    return;
  }
  if (streaming) return;

  // 框选区域截图为最高优先证据；整页图用红框标出选中位置，
  // 让模型一眼看到选的是哪块（否则它会说「图片里没有框选区域」）。
  const regionJPEG = await currentDoc.exportRegionAsJPEG(region.page, region.rect);
  const pageJPEG = await currentDoc.exportPageAsJPEG(region.page, 1.5, region.rect);
  const question = "我在整页图里用红色框标出了选中的区域，解释一下红框里这块内容。如果看不清就直说，不要猜。";

  history.push({ role: "user", content: `${question}（框选第 ${region.page} 页区域）` });

  openTeacherSheet(question);
  const answerNode = teacherSheet.querySelector(".turn.answer") as HTMLDivElement;
  answerNode.classList.add("streaming");
  showTyping(answerNode);
  streaming = true;
  let fullText = "";

  try {
    fullText = await askVisual(
      profile.id,
      {
        question,
        evidence: [
          { page: region.page, jpeg: regionJPEG },
          { page: region.page, jpeg: pageJPEG },
        ],
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        setAnswerContent(answerNode, fullText);
        const sc = teacherSheet.querySelector(".qa-scroll");
        if (sc) sc.scrollTop = sc.scrollHeight;
      },
    );
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode);
    if (sheetQA) sheetQA.answer = fullText;
    await saveQA(`${question}（框选区域）`, fullText);
  } catch (err) {
    setAnswerContent(answerNode, `出错了：${String(err)}`);
    answerNode.classList.remove("streaming");
  } finally {
    streaming = false;
  }
}

/// 决定一次提问带哪些页的图作为证据。规则基于自然语言触发，
/// 读者不需要学会说「跨页」——表达「还是不懂/接上文/下一页」即可。
function evidencePages(question: string): number[] {
  if (!currentDoc) return [currentPage];
  const last = currentDoc.pageCount;
  const q = question;
  const pages = new Set<number>();
  pages.add(currentPage);

  const wantsBefore =
    /接上文|前面|上一页|前文|刚才|上文|衔接|有什么关系|连起来/.test(q);
  const wantsAfter =
    /下一页|然后呢|继续|往下|后面|接着讲|讲完/.test(q);
  const confused =
    /还是不懂|换个说法|更简单|看不懂|没懂|不明白|换角度|例子/.test(q);

  if (wantsBefore && currentPage > 1) pages.add(currentPage - 1);
  if (wantsAfter && currentPage < last) pages.add(currentPage + 1);
  if (confused && !wantsBefore && !wantsAfter) {
    if (currentPage > 1) pages.add(currentPage - 1);
    if (currentPage < last) pages.add(currentPage + 1);
  }

  return [...pages].sort((a, b) => a - b);
}

/// 把若干页渲染成 JPEG 数组，供 Rust 端作为多图证据。
async function exportEvidence(pages: number[], scale = 1.5): Promise<{ page: number; jpeg: string }[]> {
  const out: { page: number; jpeg: string }[] = [];
  for (const page of pages) {
    if (!currentDoc) continue;
    const jpeg = await currentDoc.exportPageAsJPEG(page, scale);
    out.push({ page, jpeg });
  }
  return out;
}

// ---- 核心提问闭环 ----
async function askQuestion(question: string) {
  const profile = usableActiveProfile();
  if (!currentDoc || !profile) {
    openSettings("请先选择一个已配置的 AI 服务，再向老师提问。");
    return;
  }
  if (streaming) return;

  // 页面图像即证据；跨页内容按自然语言触发自动扩页。
  const pages = evidencePages(question);
  const evidence = await exportEvidence(pages);
  history.push({ role: "user", content: question });

  openTeacherSheet(question);
  const answerNode = teacherSheet.querySelector(".turn.answer") as HTMLDivElement;
  answerNode.classList.add("streaming");
  showTyping(answerNode);
  streaming = true;
  let fullText = "";

  try {
    fullText = await askVisual(
      profile.id,
      {
        question,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        setAnswerContent(answerNode, fullText);
        const sc = teacherSheet.querySelector(".qa-scroll");
        if (sc) sc.scrollTop = sc.scrollHeight;
      },
    );
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode);
    if (sheetQA) sheetQA.answer = fullText;
    await saveQA(question, fullText);
  } catch (err) {
    setAnswerContent(answerNode, `出错了：${String(err)}`);
    answerNode.classList.remove("streaming");
  } finally {
    streaming = false;
  }
}

// ---- 老师面板 ----

/// 面板当前展示的问答（从「问过的」列表返回时恢复用）。
let sheetQA: { question: string; answer: string } | null = null;
/// 面板是否正显示「问过的」历史列表（而不是一轮问答）。
let sheetHistoryMode = false;

/// 把回答内容渲染进元素（Markdown → DOM）。
function setAnswerContent(el: HTMLElement, text: string) {
  el.innerHTML = "";
  el.appendChild(renderMarkdown(text));
}

/// 流式回答开始前的「正在讲…」动画占位；首个内容块到达时被替换。
function showTyping(el: HTMLElement) {
  el.innerHTML = '<span class="typing">正在讲…<i></i><i></i><i></i></span>';
}

function closeTeacherSheet() {
  const hadFocus = teacherSheet.contains(document.activeElement);
  teacherSheet.classList.remove("open");
  teacherSheet.setAttribute("aria-hidden", "true");
  sheetHistoryMode = false;
  if (hadFocus) {
    if (homeView.classList.contains("open")) {
      (document.activeElement as HTMLElement | null)?.blur();
    } else {
      (document.getElementById("ask-fab") as HTMLButtonElement | null)?.focus();
    }
  }
}

function showTeacherSheet() {
  teacherSheet.classList.add("open");
  teacherSheet.setAttribute("aria-hidden", "false");
}

function resetTeacherSheetPositionIfNeeded() {
  const rect = teacherSheet.getBoundingClientRect();
  if (
    teacherSheet.style.left !== "" &&
    (rect.left > window.innerWidth - 40 || rect.top > window.innerHeight - 40 || rect.left < -40 || rect.top < 40)
  ) {
    teacherSheet.style.left = "";
    teacherSheet.style.top = "";
    teacherSheet.style.right = "";
    teacherSheet.style.bottom = "";
  }
}

function appendComposer(
  placeholder: string,
  onSubmit: (text: string) => void,
  className?: string,
) {
  const composer = document.createElement("div");
  composer.className = className ? `composer ${className}` : "composer";
  const input = document.createElement("input");
  input.placeholder = placeholder;
  input.setAttribute("aria-label", "向老师提问");
  const send = document.createElement("button");
  send.type = "button";
  send.textContent = "发送";
  send.disabled = true;

  const syncSendState = () => {
    send.disabled = input.value.trim() === "";
  };
  const submit = () => {
    const text = input.value.trim();
    if (!text || streaming) return;
    input.value = "";
    syncSendState();
    onSubmit(text);
  };

  input.addEventListener("input", syncSendState);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") submit();
  });
  send.addEventListener("click", submit);
  composer.append(input, send);
  teacherSheet.append(composer);
  queueMicrotask(() => input.focus());
}

/// 把一轮问答渲染进面板（新问答/回看历史/从历史列表返回共用）。
function renderQAIntoSheet(question: string, answerMarkdown: string) {
  teacherSheet.innerHTML = "";
  teacherSheet.appendChild(buildSheetHeader());
  const scroll = document.createElement("div");
  scroll.className = "qa-scroll";
  const q = document.createElement("div");
  q.className = "turn question";
  q.textContent = question;
  scroll.appendChild(q);
  const a = document.createElement("div");
  a.className = "turn answer";
  setAnswerContent(a, answerMarkdown);
  scroll.appendChild(a);
  teacherSheet.append(scroll);
  showTeacherSheet();
}

/// 老师卡片头部：拖拽条 + 「问过的」切换 + 收起按钮。三种视图共用。
function buildSheetHeader(): HTMLDivElement {
  const header = document.createElement("div");
  header.className = "sheet-header";
  const grip = document.createElement("div");
  grip.className = "grip";
  grip.title = "收起";
  grip.addEventListener("click", closeTeacherSheet);
  // 「问过的」：在面板里切换「当前问答 ⇄ 这本书问过的问题列表」。
  const historyBtn = document.createElement("button");
  historyBtn.className = "sheet-history";
  historyBtn.textContent = sheetHistoryMode ? "返回问答" : "问过的";
  historyBtn.title = sheetHistoryMode ? "返回刚才的问答" : "查看这本书问过的问题";
  historyBtn.addEventListener("click", () => {
    if (sheetHistoryMode) {
      // 从列表回到刚才看的问答（没有就收起）。
      sheetHistoryMode = false;
      if (sheetQA) {
        renderQAIntoSheet(sheetQA.question, sheetQA.answer);
      } else {
        closeTeacherSheet();
      }
    } else {
      showHistoryList();
    }
  });
  const close = document.createElement("button");
  close.className = "sheet-close";
  close.textContent = "收起";
  close.addEventListener("click", closeTeacherSheet);
  header.append(grip, historyBtn, close);
  return header;
}

/// 在面板里展示这本书问过的问题列表（「问过的」视图）。
function showHistoryList() {
  sheetHistoryMode = true;
  teacherSheet.innerHTML = "";
  teacherSheet.appendChild(buildSheetHeader());
  const scroll = document.createElement("div");
  scroll.className = "qa-scroll";
  if (!currentBook) {
    const empty = document.createElement("div");
    empty.className = "qa-history-empty";
    empty.textContent = "打开一本书后，这里会显示问过的问题。";
    scroll.appendChild(empty);
  } else {
    const mine = store.qa
      .filter((q) => q.book_id === currentBook!.id)
      .sort((a, b) => b.ts - a.ts);
    if (mine.length === 0) {
      const empty = document.createElement("div");
      empty.className = "qa-history-empty";
      empty.textContent = "还没有问过问题。框选一段，或点「问书」。";
      scroll.appendChild(empty);
    } else {
      for (const entry of mine.slice(0, 50)) {
        const item = document.createElement("div");
        item.className = "qa-history-item";
        const question = entry.question.length > 28 ? `${entry.question.slice(0, 28)}…` : entry.question;
        item.textContent = `第 ${entry.page} 页 · ${question}`;
        item.title = "回到这页并重看这段问答";
        item.addEventListener("click", () => void reopenQA(entry));
        scroll.appendChild(item);
      }
    }
  }
  teacherSheet.append(scroll);
  showTeacherSheet();
}

function openTeacherSheet(question: string) {
  // 记录当前问答，供「问过的」列表返回时恢复。
  sheetQA = { question, answer: "" };
  sheetHistoryMode = false;
  teacherSheet.innerHTML = "";

  // 如果卡片之前被拖出可视区（比如窗口缩小了），回到默认位置。
  resetTeacherSheetPositionIfNeeded();

  // 头部：拖拽条 + 关闭按钮。
  teacherSheet.appendChild(buildSheetHeader());

  const scroll = document.createElement("div");
  scroll.className = "qa-scroll";

  const questionTurn = document.createElement("div");
  questionTurn.className = "turn question";
  questionTurn.textContent = question;
  scroll.appendChild(questionTurn);

  const answerTurn = document.createElement("div");
  answerTurn.className = "turn answer";
  scroll.appendChild(answerTurn);

  teacherSheet.append(scroll);
  showTeacherSheet();

  appendComposer("还不懂？再问一句…", (text) => void followUp(text));
}

/// 打开老师入口但不发起网络请求。用户发送问题或明确选择
/// “讲讲这一页”之后，才会读取 Keychain 并调用模型。
function openTeacherPrompt() {
  if (!currentDoc) return;
  history = [];
  sheetQA = null;
  sheetHistoryMode = false;
  teacherSheet.innerHTML = "";
  resetTeacherSheetPositionIfNeeded();
  teacherSheet.appendChild(buildSheetHeader());

  const prompt = document.createElement("div");
  prompt.className = "teacher-prompt";
  const title = document.createElement("h3");
  title.textContent = "这页哪里卡住了？";
  const hint = document.createElement("p");
  hint.textContent = "直接问一句，或者让我先讲讲这一页。";
  const quick = document.createElement("button");
  quick.type = "button";
  quick.className = "teacher-page-explain";
  quick.textContent = "讲讲这一页";
  quick.addEventListener("click", () => {
    quick.disabled = true;
    void askPageQuestion();
  });
  prompt.append(title, hint, quick);
  teacherSheet.append(prompt);
  showTeacherSheet();
  appendComposer("比如：这张图为什么这样连接？", (text) => void askQuestion(text), "prompt-composer");
}

function appendActions(answerNode: HTMLDivElement) {
  const actions = document.createElement("div");
  actions.className = "actions";
  const buttons = [
    { label: "再讲细一点", prompt: "再讲细一点" },
    { label: "举个例子", prompt: "举个例子说明" },
    { label: "换个说法", prompt: "我还是不懂，换个角度重新讲，不要更长" },
  ];
  for (const b of buttons) {
    const btn = document.createElement("button");
    btn.textContent = b.label;
    btn.addEventListener("click", () => {
      void followUp(b.prompt);
    });
    actions.appendChild(btn);
  }
  answerNode.appendChild(actions);
}

async function followUp(text: string) {
  const profile = usableActiveProfile();
  if (!currentDoc || !profile || streaming) {
    if (!profile) openSettings("当前 AI 服务尚未配置完成。");
    return;
  }
  const pages = evidencePages(text);
  const evidence = await exportEvidence(pages);
  history.push({ role: "user", content: text });

  // 在面板里追加一轮
  const scroll = teacherSheet.querySelector(".qa-scroll")!;
  const q = document.createElement("div");
  q.className = "turn question";
  q.textContent = text;
  scroll.appendChild(q);
  const a = document.createElement("div");
  a.className = "turn answer streaming";
  showTyping(a);
  scroll.appendChild(a);
  scroll.scrollTop = scroll.scrollHeight;
  streaming = true;

  let fullText = "";
  try {
    fullText = await askVisual(
      profile.id,
      {
        question: text,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        setAnswerContent(a, fullText);
        scroll.scrollTop = scroll.scrollHeight;
      },
    );
    history.push({ role: "assistant", content: fullText });
    a.classList.remove("streaming");
    appendActions(a);
    sheetQA = { question: text, answer: fullText };
    await saveQA(text, fullText);
  } catch (err) {
    setAnswerContent(a, `出错了：${String(err)}`);
    a.classList.remove("streaming");
  } finally {
    streaming = false;
  }
}

// ---- 持久化 ----
let persistQueue: Promise<void> = Promise.resolve();

/** 串行保存完整 Store，避免较早的快照晚到后覆盖刚改好的 AI 连接。 */
function persistOrThrow(): Promise<void> {
  const snapshot = structuredClone(store);
  const next = persistQueue
    .catch(() => undefined)
    .then(() => saveStore(snapshot));
  persistQueue = next;
  return next;
}

async function persist() {
  await persistOrThrow().catch(() => undefined);
}

async function saveQA(question: string, answer: string) {
  if (!currentBook) return;
  const entry: QAEntry = {
    id: crypto.randomUUID(),
    book_id: currentBook.id,
    page: currentPage,
    question,
    answer,
    ts: Date.now(),
  };
  store.qa.push(entry);
  bumpActivity("questions", 1);
  await persist();
}

// ---- 框选交互：拖拽画框，松开发问。文字版与扫描版都可用 ----
function setupReaderSurface() {
  // 选框浮层：挂到 #app（position: fixed），不随 readerSurface 清空，
  // 否则切换书后 `readerSurface.innerHTML = ""` 会把它删掉。
  regionOverlay = document.createElement("div");
  regionOverlay.id = "region-overlay";
  document.getElementById("app")!.appendChild(regionOverlay);

  // 翻页模式：滚轮/触控板 = 翻页（页面放得下时）；放大后页面超高则页内滚动。
  // 由阅读器翻页，不做自由滚动（也就没有吸附/错位问题）。
  let lastWheelFlip = 0;
  readerSurface.addEventListener(
    "wheel",
    (e) => {
      if (!reader || !reader.pageFitsViewport()) return; // 高页：允许原生滚动
      e.preventDefault();
      if (Math.abs(e.deltaY) < 15) return;
      const now = performance.now();
      if (now - lastWheelFlip < 280) return; // 防抖：一次滚动只翻一页
      lastWheelFlip = now;
      reader.flipPage(e.deltaY > 0 ? 1 : -1);
    },
    { passive: false },
  );

  /// 拖拽超过该像素才算框选（单击不触发提问）。
  const DRAG_THRESHOLD = 6;

  readerSurface.addEventListener("mousedown", (e) => {
    if (streaming) return;
    if (e.button !== 0) return;
    // 缩放预览中页面坐标被 transform 扭曲，禁止框选。
    if (reader?.isZoomPreviewing()) return;
    // 点击阅读栏/抽屉/面板时不触发框选。
    const target = e.target as HTMLElement;
    if (target.closest("#toc-drawer") || target.closest("#teacher-sheet") || target.closest("#bottom-bar")) return;
    // 只有按下在页面元素上才记录起点。
    if (!target.closest(".scroll-page")) return;

    regionActive = true;
    regionStart = { x: e.clientX, y: e.clientY };
    e.preventDefault();
  });

  window.addEventListener("mousemove", (e) => {
    if (!regionActive || !regionStart || !regionOverlay) return;
    const x = Math.min(regionStart.x, e.clientX);
    const y = Math.min(regionStart.y, e.clientY);
    const w = Math.abs(e.clientX - regionStart.x);
    const h = Math.abs(e.clientY - regionStart.y);
    // 未超过阈值不显示选框（单击时不闪烁）。
    if (w < DRAG_THRESHOLD && h < DRAG_THRESHOLD) {
      regionOverlay.style.display = "none";
      return;
    }
    regionOverlay.style.display = "block";
    regionOverlay.style.left = `${x}px`;
    regionOverlay.style.top = `${y}px`;
    regionOverlay.style.width = `${w}px`;
    regionOverlay.style.height = `${h}px`;
  });

  window.addEventListener("mouseup", (e) => {
    if (!regionActive || !regionStart || !reader) {
      regionActive = false;
      return;
    }
    regionActive = false;
    // 单击（位移小于阈值）不提问。
    const moved = Math.hypot(e.clientX - regionStart.x, e.clientY - regionStart.y);
    if (moved < DRAG_THRESHOLD) {
      regionStart = null;
      return;
    }
    const region = reader.finishRegionSelect(
      regionStart.x,
      regionStart.y,
      e.clientX,
      e.clientY,
      regionOverlay!,
    );
    regionStart = null;
    if (region) void askRegionQuestion(region);
  });

  // ---- 触控板捏合缩放 ----
  // macOS 触控板捏合在 WKWebView 里触发 gesturechange 事件（scale 是相对倍数）；
  // Ctrl+滚轮是通用兜底。两者都接，同一手势只走一条路径。
  //
  // 手势期间用 CSS transform 即时预览（不重建 DOM、不重渲染，GPU 平滑）；
  // 手势结束才提交真实缩放（重布局 + 重渲染高清画面）。
  let gestureBaseZoom = zoomFactor;
  let gestureActive = false;

  readerSurface.addEventListener(
    "gesturestart",
    ((e: Event) => {
      e.preventDefault();
      gestureActive = true;
      gestureBaseZoom = zoomFactor;
    }) as EventListener,
  );

  readerSurface.addEventListener(
    "gesturechange",
    ((e: Event) => {
      e.preventDefault();
      const scale = (e as unknown as { scale?: number }).scale;
      if (typeof scale !== "number" || !reader) return;
      const next = clampZoom(gestureBaseZoom * scale);
      if (Math.abs(next - zoomFactor) > 0.005) {
        zoomFactor = next;
        reader.previewZoom(next);
      }
    }) as EventListener,
  );

  readerSurface.addEventListener(
    "gestureend",
    ((e: Event) => {
      e.preventDefault();
      gestureActive = false;
      if (reader) {
        void reader.commitZoom(zoomFactor);
        updateBottomBarZoom();
        persistZoom();
      }
    }) as EventListener,
  );

  // 兜底：Ctrl+滚轮缩放（普通鼠标也适用）。连续滚轮只做预览，
  // 停止滚动约 180ms 后提交真实缩放。
  let wheelCommitTimer: number | undefined;
  readerSurface.addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey || gestureActive) return;
      e.preventDefault();
      // deltaY > 0 表示向后滚（缩小），负值放大；取指数让手感平滑。
      const factor = Math.exp(-e.deltaY * 0.002);
      const next = clampZoom(zoomFactor * factor);
      if (Math.abs(next - zoomFactor) > 0.005) {
        zoomFactor = next;
        if (reader) reader.previewZoom(next);
        updateBottomBarZoom();
        window.clearTimeout(wheelCommitTimer);
        wheelCommitTimer = window.setTimeout(() => {
          if (reader) {
            void reader.commitZoom(zoomFactor);
            updateBottomBarZoom();
            persistZoom();
          }
        }, 180);
      }
    },
    { passive: false },
  );
}

function clampZoom(z: number): number {
  return Math.min(3, Math.max(0.5, z));
}

// ---- 悬浮「问书」按钮：只展开提问，不立即调用模型 ----
function setupAskFab() {
  const fab = document.getElementById("ask-fab") as HTMLButtonElement;
  fab.addEventListener("click", () => {
    if (teacherSheet.classList.contains("open")) {
      closeTeacherSheet();
      return;
    }
    openTeacherPrompt();
  });
}

// ---- 老师卡片可拖动 ----
function setupSheetDrag() {
  let dragging = false;
  let offsetX = 0;
  let offsetY = 0;

  teacherSheet.addEventListener("mousedown", (e) => {
    // 只在拖拽条/头部区域拖动，不干扰输入框与按钮。
    const target = e.target as HTMLElement;
    if (target.closest("input") || target.closest("button") || target.closest(".qa-scroll") || target.closest(".composer")) return;
    if (!target.closest(".sheet-header") && !target.classList.contains("grip")) return;
    dragging = true;
    const rect = teacherSheet.getBoundingClientRect();
    offsetX = e.clientX - rect.left;
    offsetY = e.clientY - rect.top;
    e.preventDefault();
  });

  window.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    teacherSheet.style.right = "auto";
    teacherSheet.style.bottom = "auto";
    // 限制在窗口可视范围内，避免拖出屏幕后找不到。
    const w = teacherSheet.offsetWidth;
    const h = teacherSheet.offsetHeight;
    const maxX = Math.max(8, window.innerWidth - w - 8);
    const maxY = Math.max(8, window.innerHeight - h - 8);
    teacherSheet.style.left = `${Math.min(Math.max(8, e.clientX - offsetX), maxX)}px`;
    teacherSheet.style.top = `${Math.min(Math.max(8, e.clientY - offsetY), maxY)}px`;
  });

  window.addEventListener("mouseup", () => {
    dragging = false;
  });
}

// ---- 点空白收起老师卡片 ----
function setupOutsideClickClose() {
  // 捕获阶段：卡片打开时，点击卡片/底部栏/设置弹窗之外任意处就收起。
  document.addEventListener(
    "mousedown",
    (e) => {
      if (!teacherSheet.classList.contains("open")) return;
      const target = e.target as HTMLElement;
      // 点击卡片内部、底部栏、设置弹窗、书菜单时不收起。
      if (
        target.closest("#teacher-sheet") ||
        target.closest("#bottom-bar") ||
        target.closest("#settings-modal") ||
        target.closest("#book-menu") ||
        target.closest("#toc-drawer")
      ) {
        return;
      }
      closeTeacherSheet();
    },
    true,
  );
}

// ---- 键盘 ----
document.addEventListener("keydown", (e) => {
  // 焦点在输入框/文本域时，方向键等不触发全局翻页/缩放，避免干扰输入。
  const activeTag = document.activeElement?.tagName;
  const typing =
    activeTag === "INPUT" ||
    activeTag === "TEXTAREA" ||
    activeTag === "SELECT" ||
    Boolean((document.activeElement as HTMLElement | null)?.isContentEditable);
  if (document.getElementById("settings-modal")) {
    if (e.metaKey && e.key === ",") e.preventDefault();
    return;
  }
  if (e.key === "Escape") {
    if (homeView.classList.contains("open") && currentDoc) {
      // 首页盖在正在读的书上：Esc 回到阅读。
      hideHome();
      return;
    }
    closeTeacherSheet();
    tocDrawer.classList.remove("open");
  }
  if (e.metaKey && e.key === "t") {
    tocDrawer.classList.toggle("open");
  }
  if (e.metaKey && e.key === ",") {
    openSettings();
  }
  // 缩放：⌘+/⌘- 调整，⌘0 回到铺满宽度。
  if (e.metaKey && (e.key === "=" || e.key === "+")) {
    e.preventDefault();
    zoomFactor = Math.min(3, zoomFactor + 0.15);
    void applyZoom();
    return;
  }
  if (e.metaKey && e.key === "-") {
    e.preventDefault();
    zoomFactor = Math.max(0.5, zoomFactor - 0.15);
    void applyZoom();
    return;
  }
  if (e.metaKey && e.key === "0") {
    e.preventDefault();
    zoomFactor = 1;
    void applyZoom();
    return;
  }
  if (typing) return; // 输入中：不响应全局翻页/缩放
  if (homeView.classList.contains("open")) return; // 首页打开时不翻隐藏的阅读器
  if (!e.metaKey && (e.key === "ArrowRight" || e.key === "ArrowDown" || e.key === "PageDown")) {
    reader?.flipPage(1);
  }
  if (!e.metaKey && (e.key === "ArrowLeft" || e.key === "ArrowUp" || e.key === "PageUp")) {
    reader?.flipPage(-1);
  }
});

async function applyZoom() {
  if (!reader) return;
  await reader.setZoom(zoomFactor);
  updateBottomBarZoom();
  persistZoom();
}

/// 记住缩放倍数：写进当前书（每本书各自的缩放）+ 全局默认（新书的起点），
/// 防抖写盘。
let zoomPersistTimer: number | undefined;
function persistZoom() {
  if (!store) return;
  // 缩放记到当前书（每本书记住各自的），防抖写盘。
  if (currentBook) currentBook.zoom = zoomFactor;
  window.clearTimeout(zoomPersistTimer);
  zoomPersistTimer = window.setTimeout(() => void persist(), 400);
}

// ---- 底部工具栏（macOS 原生阅读器风格） ----

const THUMB_COUNT = 25; // 当前页前后各渲染多少缩略图（首次覆盖更广）
const THUMB_WIDTH = 34;

/// 缩略图缓存：page -> 已渲染的 DOM 元素（虚拟滚动，只保留可视区附近）。
let thumbElements = new Map<number, HTMLElement>();
let thumbBarEl: HTMLElement | null = null;
/// 拖动缩略图条后抑制误点击的时间戳。
let suppressThumbClickUntil = 0;
/// 每张缩略图占位宽度（含间距），用于虚拟滚动定位。
const THUMB_STEP = THUMB_WIDTH + 6;

function renderBottomBar() {
  bottomBar.innerHTML = "";
  thumbElements = new Map();
  thumbBarEl = null;

  // 上一页 / 下一页
  const prev = document.createElement("button");
  prev.className = "nav-btn";
  prev.innerHTML = "‹";
  prev.title = "上一页";
  prev.addEventListener("click", () => reader?.flipPage(-1));
  const next = document.createElement("button");
  next.className = "nav-btn";
  next.innerHTML = "›";
  next.title = "下一页";
  next.addEventListener("click", () => reader?.flipPage(1));

  // 书：显示当前书名，点击弹出书列表（切换书）。
  const bookBtn = document.createElement("button");
  bookBtn.className = "action-btn book-btn";
  bookBtn.textContent = currentBook?.name ?? "书";
  bookBtn.title = "切换书";
  bookBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    toggleBookMenu();
  });

  // 目录：章节快速跳转 + 回看历史。
  const reviewBtn = document.createElement("button");
  reviewBtn.className = "action-btn";
  reviewBtn.textContent = "目录";
  reviewBtn.title = "章节跳转";
  reviewBtn.addEventListener("click", () => {
    buildTOC();
    tocDrawer.classList.toggle("open");
  });

  // 首页/总览：一键回到学习总览（当前阅读位置保留，随时返回）。
  const homeBtn = document.createElement("button");
  homeBtn.className = "action-btn home-btn";
  homeBtn.innerHTML = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10v9.5h13V10"/></svg>`;
  homeBtn.title = "回到首页（学习总览）";
  homeBtn.addEventListener("click", () => showHome());

  // 页码：点击变成输入框，输入页码回车跳转。
  const pageNum = document.createElement("span");
  pageNum.className = "page-num";
  pageNum.title = "点击输入页码跳转";
  pageNum.textContent = `${currentPage} / ${currentDoc?.pageCount ?? 0}`;
  pageNum.addEventListener("click", () => {
    if (!currentDoc) return;
    pageNum.innerHTML = "";
    const input = document.createElement("input");
    input.type = "text";
    input.inputMode = "numeric";
    input.className = "page-jump-input";
    input.value = String(currentPage);
    input.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.stopPropagation();
        const target = Math.min(Math.max(Number(input.value) || 1, 1), currentDoc!.pageCount);
        if (reader) {
          reader.scrollToPage(target);
          void reader.onScroll();
        }
        renderBottomBarPageLabel();
      } else if (ev.key === "Escape") {
        renderBottomBarPageLabel();
      }
    });
    input.addEventListener("blur", () => renderBottomBarPageLabel());
    pageNum.appendChild(input);
    input.focus();
    input.select();
  });

  const thumbs = document.createElement("div");
  thumbs.className = "thumbs";
  thumbBarEl = thumbs;

  // 撑起全书宽度的占位（虚拟滚动：滚动条能滑整本书）。
  const spacer = document.createElement("div");
  spacer.className = "thumbs-spacer";
  spacer.style.width = `${Math.max(1, (currentDoc?.pageCount ?? 1) * THUMB_STEP)}px`;
  thumbs.appendChild(spacer);

  // 按住拖动横滚 vs 点击缩略图跳页：拖动超过阈值后抑制 click。
  let thumbDrag = false;
  let thumbMoved = false;
  let thumbDragStartX = 0;
  let thumbDragStartScroll = 0;

  thumbs.addEventListener("mousedown", (e) => {
    thumbDrag = true;
    thumbMoved = false;
    thumbDragStartX = e.clientX;
    thumbDragStartScroll = thumbs.scrollLeft;
  });
  window.addEventListener("mousemove", (e) => {
    if (!thumbDrag) return;
    const dx = e.clientX - thumbDragStartX;
    if (Math.abs(dx) > 4) thumbMoved = true;
    thumbs.scrollLeft = thumbDragStartScroll - dx;
    scheduleThumbVirtualRender();
  });
  window.addEventListener("mouseup", () => {
    thumbDrag = false;
    // 拖动后短暂抑制 click，避免误跳页。
    if (thumbMoved) {
      suppressThumbClickUntil = performance.now() + 300;
    }
  });

  thumbs.addEventListener("click", (e) => {
    if (performance.now() < suppressThumbClickUntil) {
      e.stopPropagation();
      return;
    }
    const t = (e.target as HTMLElement).closest(".thumb") as HTMLElement | null;
    if (!t || !reader) return;
    const page = Number(t.dataset.page);
    if (page) {
      reader.scrollToPage(page);
      void reader.onScroll();
    }
  });
  // 缩略图条展开（悬停状态条）时校正高亮位置并渲染可视区。
  thumbs.addEventListener("mouseenter", () => {
    scheduleBottomBarUpdate();
    scheduleThumbVirtualRender();
  });

  // 鼠标滚轮在缩略图条上转为横向滚动（默认纵向滚轮在横向容器上无效）。
  thumbs.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      thumbs.scrollLeft += e.deltaY + e.deltaX;
      scheduleThumbVirtualRender();
    },
    { passive: false },
  );

  // 虚拟滚动：滑动缩略图条时渲染可视区附近的页面。
  thumbs.addEventListener("scroll", () => scheduleThumbVirtualRender(), { passive: true });

  // 缩放控制
  const zoomGroup = document.createElement("div");
  zoomGroup.className = "zoom-group";
  const zoomOut = document.createElement("button");
  zoomOut.textContent = "−";
  zoomOut.title = "缩小";
  zoomOut.addEventListener("click", () => {
    zoomFactor = clampZoom(zoomFactor - 0.25);
    void applyZoom();
  });
  const zoomPct = document.createElement("span");
  zoomPct.className = "zoom-pct";
  zoomPct.title = "回到适合宽度";
  zoomPct.addEventListener("click", () => {
    zoomFactor = 1;
    void applyZoom();
  });
  const zoomIn = document.createElement("button");
  zoomIn.textContent = "+";
  zoomIn.title = "放大";
  zoomIn.addEventListener("click", () => {
    zoomFactor = clampZoom(zoomFactor + 0.25);
    void applyZoom();
  });
  zoomGroup.append(zoomOut, zoomPct, zoomIn);

  // 布局切换：单页连续滚动 ⇄ 双页（书本展开）。每本书记住自己的偏好。
  const layoutBtn = document.createElement("button");
  layoutBtn.className = "action-btn layout-btn";
  layoutBtn.addEventListener("click", () => {
    void applyLayout(currentBook?.spread !== true);
  });

  const chapterLabel = document.createElement("span");
  chapterLabel.className = "chapter-label";

  bottomBar.append(homeBtn, bookBtn, prev, next, reviewBtn, pageNum, chapterLabel, thumbs, zoomGroup, layoutBtn);
  updateBottomBarZoom();
  updateLayoutButton();

  // 打开书时一次性渲染全部缩略图（缓存），滚动时只更新高亮。
  void renderAllThumbnails();
}

/// 当前页所在的章级标题（目录里 depth=0 的最后一条 ≤ 当前页的条目），
/// 没有目录时返回空。
function currentChapterLabel(): string {
  let chapter = "";
  for (const item of effectiveOutline) {
    if (item.page > currentPage) break;
    if (item.depth === 0) chapter = item.title;
  }
  return chapter;
}

function updateBottomBarZoom() {
  const pct = bottomBar.querySelector(".zoom-pct") as HTMLElement | null;
  if (pct) pct.textContent = `${Math.round(zoomFactor * 100)}%`;
}

/// 底部栏「双页/单页」按钮文案：显示点击后的效果。
function updateLayoutButton() {
  const btn = bottomBar.querySelector(".layout-btn") as HTMLElement | null;
  if (!btn) return;
  const spread = currentBook?.spread === true;
  btn.textContent = spread ? "单页" : "双页";
  btn.title = spread ? "切换为单页连续滚动" : "切换为双页（书本展开，两页并排）";
}

/// 切换单页/双页布局，并把偏好记到当前书。
/// 换布局后回到「适合宽度」（单页 = 页宽铺满，双页 = 展开宽度铺满）。
async function applyLayout(spread: boolean) {
  if (!reader) return;
  zoomFactor = 1;
  await reader.setZoom(1);
  await reader.setSpread(spread);
  if (currentBook) {
    currentBook.spread = spread;
    currentBook.zoom = zoomFactor; // 布局切换后回到适合宽度，一并记住
    store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
    await persist();
  }
  updateLayoutButton();
  updateBottomBarZoom();
}

/// 重建底部栏页码标签（页码输入框失焦/提交后调用）。
function renderBottomBarPageLabel() {
  const pageNum = bottomBar.querySelector(".page-num") as HTMLElement | null;
  if (!pageNum) return;
  pageNum.innerHTML = "";
  pageNum.textContent = `${currentPage} / ${currentDoc?.pageCount ?? 0}`;
}

// ---- 书菜单：列出导入的书，点击切换 ----
let bookMenuEl: HTMLDivElement | null = null;

function toggleBookMenu() {
  if (bookMenuEl) {
    bookMenuEl.remove();
    bookMenuEl = null;
    return;
  }
  const menu = document.createElement("div");
  menu.id = "book-menu";
  bookMenuEl = menu;

  const title = document.createElement("div");
  title.className = "book-menu-title";
  title.textContent = "我的书";
  menu.appendChild(title);

  // 回到首页/总览。
  const homeItem = document.createElement("div");
  homeItem.className = "book-menu-item";
  homeItem.textContent = "总览 · 学习活动";
  homeItem.addEventListener("click", () => {
    bookMenuEl?.remove();
    bookMenuEl = null;
    showHome();
  });
  menu.appendChild(homeItem);

  if (store.books.length === 0) {
    const empty = document.createElement("div");
    empty.className = "book-menu-item muted";
    empty.textContent = "还没有书。";
    menu.appendChild(empty);
  } else {
    for (const book of store.books) {
      const item = document.createElement("div");
      item.className = "book-menu-item";
      item.dataset.bookId = book.id;
      const name = document.createElement("span");
      name.className = "book-menu-name";
      name.textContent = book.name;
      name.title = book.path;
      const info = document.createElement("span");
      info.className = "book-menu-info";
      info.textContent = book.id === currentBook?.id ? "正在读" : `读到第 ${book.last_page} 页`;

      // 删除按钮（悬停时出现）。
      const del = document.createElement("button");
      del.className = "book-menu-del";
      del.textContent = "删除";
      del.title = "从书架移除（不删除原文件）";
      del.addEventListener("click", (e) => {
        e.stopPropagation();
        void removeBook(book);
      });

      item.append(name, info, del);
      if (book.id === currentBook?.id) item.classList.add("current");
      item.addEventListener("click", () => {
        menu.remove();
        bookMenuEl = null;
        if (book.id !== currentBook?.id) void openBook(book);
      });
      menu.appendChild(item);
    }
  }

  const openNew = document.createElement("button");
  openNew.className = "book-menu-open";
  openNew.textContent = "打开一本新书…";
  openNew.addEventListener("click", () => {
    menu.remove();
    bookMenuEl = null;
    void pickAndOpenBook();
  });
  menu.appendChild(openNew);

  bottomBar.appendChild(menu);
  // 点击菜单外部关闭。
  window.addEventListener("mousedown", (e) => {
    if (bookMenuEl && !bookMenuEl.contains(e.target as Node)) {
      bookMenuEl.remove();
      bookMenuEl = null;
    }
  }, { once: true });
}

/// 从书架删除一本书（不删除电脑上的原 PDF 文件），连带清掉它的问答记录。
async function removeBook(book: BookRecord) {
  bookMenuEl?.remove();
  bookMenuEl = null;

  // 从书库移除 + 清掉该书问答。
  store.books = store.books.filter((b) => b.id !== book.id);
  store.qa = store.qa.filter((q) => q.book_id !== book.id);
  await persist();

  // 删除的是当前书：切换到剩余第一本，或回到空书架。
  if (currentBook?.id === book.id) {
    currentDoc?.destroy();
    currentDoc = null;
    reader?.clear();
    reader = null;
    currentBook = null;
    history = [];
    sheetQA = null;
    closeTeacherSheet();
    tocDrawer.classList.remove("open");
    if (store.books.length > 0) {
      await openBook(store.books[0]);
    } else {
      showHome();
    }
  } else {
    // 非当前书：重建书菜单反映变化（若开着）。
    if (bookMenuEl) toggleBookMenu();
  }
}

/// 滚动/翻页后：更新页码、当前章节、把高亮框移到当前页缩略图、滚动缩略图条让当前页可见。
function scheduleBottomBarUpdate() {
  if (!currentDoc || !thumbBarEl) return;
  const pageNum = bottomBar.querySelector(".page-num") as HTMLElement | null;
  if (pageNum) pageNum.textContent = `${currentPage} / ${currentDoc.pageCount}`;

  // 当前章节提示（大书翻页时知道自己在哪一章）。
  const chapterEl = bottomBar.querySelector(".chapter-label") as HTMLElement | null;
  if (chapterEl) chapterEl.textContent = currentChapterLabel();

  // 缩略图条收起时（height 0）不做定位，展开时由 hover 触发一次校正。
  const barRect = thumbBarEl.getBoundingClientRect();
  if (barRect.height < 20) return;

  // 高亮当前页缩略图（直接改 border 颜色，比浮动框更简单可靠）。
  for (const [p, el] of thumbElements) {
    el.style.borderColor = p === currentPage ? "var(--lavender)" : "transparent";
  }
  // 让当前页缩略图滚入视野（只横向滚动缩略图条本身）。
  const target = (currentPage - 1) * THUMB_STEP - barRect.width / 2 + THUMB_WIDTH / 2;
  thumbBarEl.scrollTo({ left: Math.max(0, target), behavior: "smooth" });
  // 滚动后渲染可视区。
  scheduleThumbVirtualRender();
}

/// 打开书时渲染当前页附近的缩略图，并在后台预热全书缓存。
async function renderAllThumbnails() {
  if (!currentDoc || !thumbBarEl) return;
  await ensureThumbnailsAround(currentPage);
  scheduleBottomBarUpdate();
  // 后台预热：把还没缓存的页慢慢渲染进磁盘缓存（低优先级，不抢主线程）。
  // 这样读到哪，那块缩略图早就缓存好了，悬停即秒出。
  void preheatThumbCache();
}

let preheating = false;
/// 目录识别期间置 true：预热循环暂停，把 PDF.js worker 让给目录页渲染。
let preheatPaused = false;

/// 后台预热：把还没缓存的页渲染成小图存盘，但不挂 DOM（避免几千页元素占内存）。
async function preheatThumbCache() {
  if (preheating || !currentDoc) return;
  preheating = true;
  // 捕获本次预热的书身份：切书后 currentDoc 会变，检测到变化立即停止，
  // 避免用新书渲染、按旧书路径写缓存（串书错乱）。
  const doc = currentDoc;
  const bookPath = currentBook?.path ?? "";
  try {
    const total = doc.pageCount;
    for (let p = 1; p <= total; p++) {
      // 切书了：立即停止，让新书的预热接管。
      if (currentDoc !== doc || currentBook?.path !== bookPath) return;
      // 目录识别进行中：原地等待，识别结束自动继续（不丢失预热进度）。
      while (preheatPaused) {
        await new Promise((r) => setTimeout(r, 300));
        if (currentDoc !== doc || currentBook?.path !== bookPath) return;
      }
      // 已挂 DOM 的（可视区附近）已处理；只补未缓存的远处页。
      if (thumbElements.has(p)) continue;
      if (!bookPath) return;
      let cached: string | null = null;
      try {
        cached = await loadThumb(bookPath, p);
      } catch {
        cached = null;
      }
      if (cached) continue;
      try {
        const size = await doc.pageSize(p);
        const canvas = await doc.renderPageToCanvas(p, THUMB_WIDTH / size.width);
        const jpeg = canvas.toDataURL("image/jpeg", 0.85).split(",")[1];
        void saveThumb(bookPath, p, jpeg);
      } catch {
        // 单页预热失败跳过。
      }
      // 每张让出事件循环，避免阻塞阅读交互。
      await new Promise((r) => setTimeout(r, 0));
    }
  } finally {
    preheating = false;
  }
}

let thumbnailBusy = false;
let thumbnailQueued = false;
let thumbVirtualTimer: number | undefined;

/// 虚拟滚动：渲染缩略图条可视区附近的页面，回收远处的（防抖）。
function scheduleThumbVirtualRender() {
  window.clearTimeout(thumbVirtualTimer);
  thumbVirtualTimer = window.setTimeout(() => void ensureThumbnailsAround(currentPage, true), 60);
}

/// 确保缩略图条可视区（±缓冲）附近的页已渲染；`fromScroll` 时按滚动位置算。
async function ensureThumbnailsAround(page: number, fromScroll = false) {
  if (!currentDoc || !thumbBarEl) return;

  let start: number;
  let end: number;
  if (fromScroll && thumbBarEl.scrollWidth > 0) {
    const viewLeft = thumbBarEl.scrollLeft;
    const viewRight = viewLeft + thumbBarEl.clientWidth;
    start = Math.max(1, Math.floor(viewLeft / THUMB_STEP) - 2);
    end = Math.min(currentDoc.pageCount, Math.ceil(viewRight / THUMB_STEP) + 2);
  } else {
    start = Math.max(1, page - THUMB_COUNT);
    end = Math.min(currentDoc.pageCount, page + THUMB_COUNT);
  }

  // 回收可视区之外的缩略图（虚拟滚动，避免全书几千页占内存）。
  for (const [p, el] of thumbElements) {
    if (p < start - 8 || p > end + 8) {
      el.remove();
      thumbElements.delete(p);
    }
  }

  // 渲染缺失的页。
  const missing: number[] = [];
  for (let p = start; p <= end; p++) {
    if (!thumbElements.has(p)) missing.push(p);
  }
  if (missing.length === 0) return;

  if (thumbnailBusy) {
    thumbnailQueued = true;
    return;
  }
  thumbnailBusy = true;
  try {
    // 更激进的并行：PDF.js 支持多页并发渲染（内部 worker 排队）。
    // 骨架已同步就位，这里只负责尽快填充图片。
    const BATCH = 12;
    for (let i = 0; i < missing.length; i += BATCH) {
      const batch = missing.slice(i, i + BATCH);
      await Promise.all(batch.map((p) => renderThumb(p)));
    }
  } finally {
    thumbnailBusy = false;
    if (thumbnailQueued) {
      thumbnailQueued = false;
      void ensureThumbnailsAround(currentPage, true);
    }
  }
}

async function renderThumb(page: number): Promise<void> {
  if (!currentDoc || !thumbBarEl) return;
  if (thumbElements.has(page)) return;

  const thumb = document.createElement("div");
  thumb.className = "thumb placeholder";
  thumb.dataset.page = String(page);
  thumb.title = `第 ${page} 页`;
  // 绝对定位：第 page 页的横坐标 = (page-1) * THUMB_STEP。
  thumb.style.left = `${(page - 1) * THUMB_STEP}px`;

  const size = await currentDoc.pageSize(page);
  const h = Math.round((size.height / size.width) * THUMB_WIDTH);
  thumb.style.width = `${THUMB_WIDTH}px`;
  thumb.style.height = `${h + 4}px`;
  thumbBarEl.appendChild(thumb);
  thumbElements.set(page, thumb);

  // 优先读磁盘缓存（之前渲染过 → 秒出，不再解码）。
  const bookPath = currentBook?.path ?? "";
  let cached: string | null = null;
  try {
    cached = await loadThumb(bookPath, page);
  } catch {
    cached = null;
  }
  if (cached) {
    const img = document.createElement("img");
    img.src = `data:image/jpeg;base64,${cached}`;
    img.style.width = `${THUMB_WIDTH}px`;
    img.style.height = `${h}px`;
    thumb.appendChild(img);
    thumb.classList.remove("placeholder");
    return;
  }

  // 未命中：渲染后写入缓存，下次秒出。
  try {
    const canvas = await currentDoc.renderPageToCanvas(page, THUMB_WIDTH / size.width);
    canvas.style.width = `${THUMB_WIDTH}px`;
    canvas.style.height = `${h}px`;
    thumb.appendChild(canvas);
    thumb.classList.remove("placeholder");
    if (bookPath) {
      try {
        const jpeg = canvas.toDataURL("image/jpeg", 0.85).split(",")[1];
        void saveThumb(bookPath, page, jpeg);
      } catch {
        // 写缓存失败不影响显示。
      }
    }
  } catch {
    // 缩略图渲染失败不阻塞阅读。
  }
}

function persistReadingPosition() {
  if (!currentBook) return;
  currentBook.last_page = currentPage;
  store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
  // 把本轮翻过的页数记进当天的活动量，随这次持久化一起落盘。
  if (todayPagesPending > 0) {
    bumpActivity("pages", todayPagesPending);
    todayPagesPending = 0;
  }
  void persist();
}

/// 滚动触发时防抖保存阅读位置。
let persistTimer: number | undefined;
function schedulePersistPosition() {
  window.clearTimeout(persistTimer);
  persistTimer = window.setTimeout(persistReadingPosition, 800);
}

// ---- 设置 ----
function openSettings(message?: string) {
  openAISettings({
    settings: structuredClone(store.settings),
    message,
    persistSettings: async (next: Settings) => {
      const previous = store.settings;
      store.settings = structuredClone(next);
      try {
        await persistOrThrow();
        await refreshActiveCredentialStatus();
      } catch (error) {
        store.settings = previous;
        await refreshActiveCredentialStatus();
        throw error;
      }
    },
    onChange: (next: Settings) => {
      store.settings = structuredClone(next);
      void refreshActiveCredentialStatus();
    },
  });
}

// ---- 启动 ----
void boot();
