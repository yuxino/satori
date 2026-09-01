// Satori 3.0 主入口：一本书，旁边坐着一个老师。
import "./styles.css";
import { open } from "@tauri-apps/plugin-dialog";
import { convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWindow } from "@tauri-apps/api/window";

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
  div.textContent = `出错了：\n${message}`;
  root.appendChild(div);
}

import {
  askVisual,
  completeAppExit,
  credentialStatus,
  emptyStore,
  extractOutline,
  findPageByTitle,
  inspectPdfFile,
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
import type { PDFDocument } from "./pdf";
import { ScrollReader, type RegionSelection } from "./reader";
import { renderMarkdown } from "./markdown";
import { pageTransitionDelta } from "./activity";
import { decideBookRemovalUI } from "./book-removal-ui";
import { requestedEvidencePages } from "./evidence-policy";
import { outlineEvidencePlan } from "./outline-evidence-policy";
import { RequestGate } from "./request-gate";
import {
  fileNameFromPath,
  hasPrimaryModifier,
  shouldHandlePageFlipWheel,
  versionLabel,
} from "./platform";
import { fileSizeLabel, pdfOpenErrorMessage } from "./pdf-open-policy";
import { decidePdfDrop } from "./pdf-drop";
import { actionableConnectionError } from "./connection-error";
import { openAISettings } from "./settings";
import { StorePersistence } from "./store-persistence";
import {
  getAppUpdateSnapshot,
  initializeAppUpdateCheck,
  subscribeToAppUpdates,
  type AppUpdateSnapshot,
} from "./update";

// ---- DOM ----
const readerSurface = document.getElementById("reader-surface") as HTMLDivElement;
const teacherSheet = document.getElementById("teacher-sheet") as HTMLDivElement;
const tocDrawer = document.getElementById("toc-drawer") as HTMLDivElement;
const bottomBar = document.getElementById("bottom-bar") as HTMLDivElement;
const homeView = document.getElementById("home-view") as HTMLDivElement;

// ---- 状态 ----
let store: Store = emptyStore();
let storeLoaded = false;
let activeCredentialSaved = false;
let credentialRefreshGeneration = 0;
let currentBook: BookRecord | null = null;
let currentDoc: PDFDocument | null = null;
let reader: ScrollReader | null = null;
let currentPage = 1;
/// 用户缩放倍数：1 = 页面或展开适合窗口，可用主修饰键 +/- 调整。
let zoomFactor = 1;
let history: HistoryTurn[] = [];
const questionGate = new RequestGate();
let appUpdateState: AppUpdateSnapshot = getAppUpdateSnapshot();
let activeOpenAbort: AbortController | null = null;

interface QuestionContext {
  token: number;
  bookId: string;
  page: number;
  doc: PDFDocument;
}

function beginQuestionContext(page = currentPage): QuestionContext | null {
  if (!currentBook || !currentDoc) return null;
  const token = questionGate.begin();
  if (token === null) return null;
  return {
    token,
    bookId: currentBook.id,
    page,
    doc: currentDoc,
  };
}

function questionContextIsCurrent(context: QuestionContext): boolean {
  return (
    questionGate.isCurrent(context.token) &&
    currentDoc === context.doc &&
    currentBook?.id === context.bookId
  );
}

subscribeToAppUpdates((state) => {
  appUpdateState = state;
  syncHomeUpdateIndicator();
});

/// 框选状态。
let regionOverlay: HTMLDivElement | null = null;
let regionStart: { x: number; y: number } | null = null;
let regionActive = false;
let wheelCommitTimer: number | undefined;

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

/**
 * Resolve credentials only after an explicit AI action. Ordinary startup,
 * importing, reading, and library management never touch secure storage.
 */
async function activeProfileForAI(missingMessage: string): Promise<AIProfile | null> {
  const profile = activeProfile();
  if (!profile || !profile.name.trim() || !profile.model_id.trim() || !profile.base_url.trim()) {
    openSettings(missingMessage);
    return null;
  }
  if (!profile.api_key_required) return profile;
  try {
    activeCredentialSaved = (await credentialStatus(profile.id)).saved;
  } catch (error) {
    openSettings(`无法读取系统安全凭据：${String(error)}。请在设置中重试。`);
    return null;
  }
  if (!activeCredentialSaved) {
    openSettings(missingMessage);
    return null;
  }
  return profile;
}

// ---- 启动 ----
async function boot() {
  await setupExitPersistence();
  // 数据损坏或格式较新时必须明确失败，不能构造默认 provider 后继续写入。
  store = await loadStore();
  storeLoaded = true;
  let recoveredInterruptedOpen = false;
  store.books = store.books.map((book) => {
    if (!book.opening) return book;
    recoveredInterruptedOpen = true;
    return {
      ...book,
      opening: false,
      open_error: "上次打开在完成前中断了。Satori 已跳过自动恢复，你可以重试或从书架移除。",
    };
  });
  if (recoveredInterruptedOpen) {
    await persistOrThrow();
  }
  showHome();
  setupReaderSurface();
  setupAskFab();
  setupSheetDrag();
  setupOutsideClickClose();
  await setupNativePdfDrop().catch(() => undefined);
  initializeAppUpdateCheck();

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

  // 首页题头只保留操作入口，让内容本身承担页面识别。
  const header = document.createElement("header");
  header.className = "home-masthead";

  const headerActions = document.createElement("div");
  headerActions.className = "home-header-actions";
  const settingsBtn = document.createElement("button");
  settingsBtn.className = "home-settings-action";
  settingsBtn.type = "button";
  settingsBtn.setAttribute("aria-label", "打开设置");
  settingsBtn.title = "设置";
  settingsBtn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.75v2.1M12 18.15v2.1M20.25 12h-2.1M5.85 12h-2.1M17.83 6.17l-1.48 1.48M7.65 16.35l-1.48 1.48M17.83 17.83l-1.48-1.48M7.65 7.65 6.17 6.17"/><circle cx="12" cy="12" r="4.15"/><circle cx="12" cy="12" r="1.05" fill="currentColor" stroke="none"/></svg><span>设置</span>`;
  settingsBtn.addEventListener("click", () => openSettings());
  headerActions.appendChild(settingsBtn);
  if (currentDoc) {
    const closeBtn = document.createElement("button");
    closeBtn.className = "home-close";
    closeBtn.textContent = "返回书页";
    closeBtn.title = "回到刚才读的位置";
    closeBtn.addEventListener("click", hideHome);
    headerActions.appendChild(closeBtn);
  }
  header.appendChild(headerActions);
  wrap.appendChild(header);

  const featured = featuredBook();
  if (featured) {
    wrap.appendChild(buildContinueStage(featured));
  } else {
    wrap.appendChild(buildEmptyDesk());
  }

  // 保留完整年度格子：这是用户喜欢的学习反馈，而不是任务或排名。
  const activitySection = document.createElement("section");
  activitySection.className = "home-activity";
  const activityHeading = document.createElement("div");
  activityHeading.className = "home-section-heading";
  const activityTitle = document.createElement("h2");
  activityTitle.textContent = "学习足迹";
  const activityMeta = document.createElement("span");
  const activeDays = Object.keys(store.activity).length;
  activityMeta.textContent = activeDays > 0 ? `${activeDays} 天有读过 · ${store.qa.length} 次提问` : "从第一天开始";
  activityHeading.append(activityTitle, activityMeta);
  activitySection.append(activityHeading, buildActivityGrid());
  wrap.appendChild(activitySection);

  const homeGrid = document.createElement("div");
  homeGrid.className = "home-grid";

  // 书架：纵向书脊，不再做卡片矩阵。
  const booksSection = document.createElement("section");
  booksSection.className = "home-section home-library";
  const booksTitle = document.createElement("h2");
  booksTitle.textContent = "书架";
  const addBtn = document.createElement("button");
  addBtn.className = "home-section-action";
  addBtn.textContent = "打开 PDF…";
  addBtn.addEventListener("click", () => void pickAndOpenBook());
  const booksHeading = document.createElement("div");
  booksHeading.className = "home-section-heading";
  booksHeading.append(booksTitle, addBtn);
  booksSection.appendChild(booksHeading);

  if (store.books.length === 0) {
    const empty = document.createElement("div");
    empty.className = "home-empty";
    empty.textContent = "书架还是空的。打开一本 PDF，它会留在这里。";
    booksSection.appendChild(empty);
  } else {
    const list = document.createElement("div");
    list.className = "home-books";
    for (const book of store.books) list.appendChild(buildBookCard(book));
    booksSection.appendChild(list);
  }
  homeGrid.appendChild(booksSection);

  // 最近问答：同时露出问题与回答摘要，但不替用户判断是否已经理解。
  const recent = store.qa
    .slice()
    .sort((a, b) => b.ts - a.ts)
    .slice(0, 4);
  const qaSection = document.createElement("section");
  qaSection.className = "home-section home-traces";
  const qaTitle = document.createElement("h2");
  qaTitle.textContent = "最近问过";
  qaSection.appendChild(qaTitle);
  if (recent.length > 0) {
    const qaList = document.createElement("div");
    qaList.className = "home-recent";
    for (const entry of recent) {
      const book = store.books.find((b) => b.id === entry.book_id);
      const item = document.createElement("button");
      item.className = "home-recent-item";
      const meta = document.createElement("span");
      meta.className = "home-recent-meta";
      meta.textContent = `${bookName(book?.name ?? "书")} · 第 ${entry.page} 页`;
      const q = document.createElement("span");
      q.className = "home-recent-q";
      q.textContent = entry.question;
      const answer = document.createElement("span");
      answer.className = "home-recent-answer";
      answer.textContent = plainTextExcerpt(entry.answer, 74);
      item.append(meta, q, answer);
      item.addEventListener("click", async () => {
        const target = store.books.find((b) => b.id === entry.book_id);
        if (!target) return;
        await openBook(target);
        await reopenQA(entry);
      });
      qaList.appendChild(item);
    }
    qaSection.appendChild(qaList);
  } else {
    const empty = document.createElement("div");
    empty.className = "home-empty";
    empty.textContent = "问过的问题和回答会留在这里，方便之后回看。";
    qaSection.appendChild(empty);
  }
  homeGrid.appendChild(qaSection);

  wrap.appendChild(homeGrid);
  homeView.appendChild(wrap);
  syncHomeUpdateIndicator();
}

function syncHomeUpdateIndicator(): void {
  const settingsButton = homeView.querySelector<HTMLButtonElement>(".home-settings-action");
  if (!settingsButton) return;
  const hasDownload = appUpdateState.phase === "available" && Boolean(appUpdateState.latestVersion);
  const hasReleaseOnly = appUpdateState.phase === "release-only" && Boolean(appUpdateState.latestVersion);
  const hasNewRelease = hasDownload || hasReleaseOnly;
  settingsButton.classList.toggle("update-available", hasNewRelease);
  const label = hasDownload
    ? `打开设置，Satori ${versionLabel(appUpdateState.latestVersion)} 可下载`
    : hasReleaseOnly
      ? `打开设置，Satori ${versionLabel(appUpdateState.latestVersion)} 已发布，当前系统暂无适用安装包`
      : "打开设置";
  settingsButton.setAttribute("aria-label", label);
  settingsButton.title = hasNewRelease ? label.replace("打开设置，", "") : "设置";
}

function bookName(name: string): string {
  return name.replace(/\.pdf$/i, "");
}

function bookProgress(book: BookRecord): { percent: number; detail: string } {
  const total = book.pageCount;
  const percent = total && total > 0 ? Math.min(100, Math.round((book.last_page / total) * 100)) : 0;
  return {
    percent,
    detail: total ? `第 ${book.last_page} / ${total} 页` : `读到第 ${book.last_page} 页`,
  };
}

function featuredBook(): BookRecord | null {
  if (currentBook) return currentBook;
  const latestQA = store.qa.slice().sort((a, b) => b.ts - a.ts)[0];
  return store.books.find((book) => book.id === latestQA?.book_id) ?? store.books[0] ?? null;
}

function studySummaryText(): string {
  const today = store.activity[todayKey()];
  if (today && (today.pages > 0 || today.questions > 0)) {
    const parts = [];
    if (today.pages > 50) parts.push("读过一阵");
    else if (today.pages > 0) parts.push(`翻过 ${today.pages} 页`);
    if (today.questions > 0) parts.push(`问过 ${today.questions} 次`);
    return `今天已经${parts.join("，")}。慢一点也没关系。`;
  }
  const streak = computeStreak();
  if (streak > 0) return `最近连续读了 ${streak} 天。今天从一页开始就好。`;
  if (store.qa.length > 0) return `这里留着 ${store.qa.length} 次问答，随时可以回来接着想。`;
  return "不设任务，也不催进度。只从眼前这一页开始。";
}

function buildContinueStage(book: BookRecord): HTMLElement {
  const stage = document.createElement("section");
  stage.className = "home-continue";

  const cover = document.createElement("div");
  cover.className = "home-featured-cover";
  hydrateBookCover(cover, book);

  const copy = document.createElement("div");
  copy.className = "home-continue-copy";
  const eyebrow = document.createElement("span");
  eyebrow.className = "home-eyebrow";
  eyebrow.textContent = book.open_error ? "上次打开没有完成" : currentBook?.id === book.id ? "书页还在原处" : "接着读";
  const title = document.createElement("h2");
  title.textContent = bookName(book.name);
  const progress = bookProgress(book);
  const meta = document.createElement("p");
  meta.className = "home-continue-meta";
  const qCount = store.qa.filter((entry) => entry.book_id === book.id).length;
  meta.textContent = book.open_error ?? `${progress.detail} · 问过 ${qCount} 次`;
  const bar = document.createElement("div");
  bar.className = "home-continue-progress";
  bar.setAttribute("aria-label", `阅读进度 ${progress.percent}%`);
  const fill = document.createElement("span");
  fill.style.width = `${progress.percent}%`;
  bar.appendChild(fill);
  const button = document.createElement("button");
  button.className = "home-primary-action";
  button.textContent = book.open_error ? "重新打开" : currentBook?.id === book.id ? "回到书页" : "继续阅读";
  button.addEventListener("click", () => void openBook(book));
  copy.append(eyebrow, title, meta);

  const note = document.createElement("p");
  note.className = "home-continue-note";
  note.textContent = studySummaryText();
  const footer = document.createElement("div");
  footer.className = "home-continue-footer";
  const progressLabel = document.createElement("span");
  progressLabel.className = "home-progress-label";
  progressLabel.textContent = `${progress.percent}%`;
  footer.append(button, progressLabel);

  copy.append(note, bar, footer);
  stage.append(cover, copy);

  const latestUnderstanding = store.qa
    .filter((entry) => entry.book_id === book.id)
    .sort((a, b) => b.ts - a.ts)[0];
  if (latestUnderstanding) {
    stage.classList.add("has-trace");
    const trace = document.createElement("button");
    trace.type = "button";
    trace.className = "home-last-trace";
    trace.title = `回到第 ${latestUnderstanding.page} 页查看这次问答`;
    const traceLabel = document.createElement("span");
    traceLabel.className = "home-eyebrow";
    traceLabel.textContent = "上次提问";
    const traceQuestion = document.createElement("strong");
    traceQuestion.textContent = latestUnderstanding.question;
    const traceMeta = document.createElement("span");
    traceMeta.className = "home-last-trace-meta";
    traceMeta.textContent = `第 ${latestUnderstanding.page} 页 · 回看这次问答`;
    trace.append(traceLabel, traceQuestion, traceMeta);
    trace.addEventListener("click", async () => {
      await openBook(book);
      await reopenQA(latestUnderstanding);
    });
    stage.appendChild(trace);
  }
  return stage;
}

function buildEmptyDesk(): HTMLElement {
  const empty = document.createElement("section");
  empty.className = "home-continue home-first-book";
  const kicker = document.createElement("span");
  kicker.className = "home-eyebrow";
  kicker.textContent = "你的书房还空着";
  const title = document.createElement("h2");
  title.textContent = "带一本正在读的书进来。";
  const body = document.createElement("p");
  body.textContent = "阅读位置会留在这台电脑上，真正卡住时再请老师一起弄懂这一页。";
  const button = document.createElement("button");
  button.className = "home-primary-action";
  button.textContent = "打开 PDF…";
  button.addEventListener("click", () => void pickAndOpenBook());
  empty.append(kicker, title, body, button);
  return empty;
}

/// 最近一年的学习格子。完整保留用户熟悉的 52 周节奏，但不附带排名或任务。
function buildActivityGrid(): HTMLDivElement {
  const weeks = 52;
  const today = new Date();
  const currentDateKey = dateKey(today);
  const monday = new Date(today);
  monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));

  const frame = document.createElement("div");
  frame.className = "home-activity-frame";
  const grid = document.createElement("div");
  grid.className = "activity-grid";
  grid.setAttribute("role", "img");
  grid.setAttribute("aria-label", "最近一年的阅读与提问活动");

  let previousMonth = -1;
  const monthLabels: Array<{ column: number; month: number }> = [];
  for (let week = weeks - 1; week >= 0; week--) {
    const date = new Date(monday);
    date.setDate(monday.getDate() - week * 7);
    if (date.getMonth() === previousMonth) continue;
    monthLabels.push({ column: weeks - week + 2, month: date.getMonth() + 1 });
    previousMonth = date.getMonth();
  }
  for (let index = 0; index < monthLabels.length; index++) {
    const current = monthLabels[index];
    const next = monthLabels[index + 1];
    // 最左侧常是上个月最后一周；离下个月太近时省略，避免两个标签挤在一起。
    if (index === 0 && next && next.column - current.column < 4) continue;
    const label = document.createElement("span");
    label.className = "grid-month-label";
    label.textContent = `${current.month}月`;
    label.style.gridColumn = String(current.column);
    label.style.gridRow = "1";
    grid.appendChild(label);
  }

  for (const [day, label] of [[0, "一"], [2, "三"], [4, "五"]] as const) {
    const weekday = document.createElement("span");
    weekday.className = "grid-weekday";
    weekday.textContent = label;
    weekday.style.gridColumn = "1";
    weekday.style.gridRow = String(day + 2);
    grid.appendChild(weekday);
  }

  for (let week = weeks - 1; week >= 0; week--) {
    for (let day = 0; day < 7; day++) {
      const date = new Date(monday);
      date.setDate(monday.getDate() - week * 7 + day);
      const key = dateKey(date);
      const activity = store.activity[key];
      const score = activity ? activity.pages + activity.questions * 5 : 0;
      const cell = document.createElement("span");
      cell.className = `grid-cell level-${activityLevel(score)}`;
      if (key === currentDateKey) cell.classList.add("today");
      if (date.getTime() > today.getTime()) cell.classList.add("future");
      cell.style.gridColumn = String(weeks - week + 2);
      cell.style.gridRow = String(day + 2);
      cell.title = `${key} · 阅读 ${activity?.pages ?? 0} 页 · 提问 ${activity?.questions ?? 0}`;
      grid.appendChild(cell);
    }
  }

  const legend = document.createElement("div");
  legend.className = "home-activity-legend";
  legend.append(document.createTextNode("少"));
  for (let level = 0; level <= 4; level++) {
    const swatch = document.createElement("span");
    swatch.className = `grid-cell level-${level}`;
    legend.appendChild(swatch);
  }
  legend.append(document.createTextNode("多"));
  frame.append(grid, legend);
  return frame;
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

  const openButton = document.createElement("button");
  openButton.type = "button";
  openButton.className = "home-book-open";

  const cover = document.createElement("div");
  cover.className = "home-book-cover";
  hydrateBookCover(cover, book);

  const body = document.createElement("div");
  body.className = "home-book-body";

  const name = document.createElement("div");
  name.className = "home-book-name";
  name.textContent = bookName(book.name);

  const meta = document.createElement("div");
  meta.className = "home-book-meta";
  const qCount = store.qa.filter((q) => q.book_id === book.id).length;
  const progress = bookProgress(book);
  meta.textContent = book.open_error ?? `${progress.detail} · ${qCount} 次提问`;
  body.append(name, meta);

  const hint = document.createElement("span");
  hint.className = "home-book-hint";
  hint.textContent = book.open_error ? "重试" : book.id === currentBook?.id ? "正在读" : `${progress.percent}%`;

  openButton.append(cover, body, hint);
  openButton.addEventListener("click", () => void openBook(book));
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "home-book-remove";
  remove.textContent = "移除";
  remove.title = "只从 Satori 书架移除，不删除原 PDF";
  remove.addEventListener("click", () => void removeBook(book));
  card.append(openButton, remove);
  return card;
}

function hydrateBookCover(cover: HTMLElement, book: BookRecord) {
  const title = bookName(book.name) || "未命名";
  const palette = ["#202124", "#343537", "#48494b", "#5b5c5e", "#6d6e70", "#7e7e7b"];
  let hash = 0;
  for (const character of `${book.id}:${title}`) hash = (hash * 31 + character.charCodeAt(0)) >>> 0;

  cover.style.setProperty("--book-cover", palette[hash % palette.length]);
  cover.classList.add("book-cover-type");
  cover.setAttribute("aria-hidden", "true");
  if (cover.classList.contains("home-featured-cover")) {
    const kicker = document.createElement("span");
    kicker.className = "book-cover-kicker";
    kicker.textContent = "READING · EDITION";
    const coverTitle = document.createElement("strong");
    coverTitle.className = "book-cover-title";
    coverTitle.textContent = title;
    if (title.length > 18) coverTitle.classList.add("long");
    const meta = document.createElement("span");
    meta.className = "book-cover-meta";
    meta.textContent = book.pageCount ? `${book.pageCount} PAGES` : "PDF EDITION";
    cover.append(kicker, coverTitle, meta);
  } else {
    const monogram = document.createElement("span");
    monogram.className = "book-cover-monogram";
    monogram.textContent = title.slice(0, 1).toUpperCase();
    cover.appendChild(monogram);
  }
}

function plainTextExcerpt(markdown: string, maxLength: number): string {
  const plain = markdown
    .replace(/```[\s\S]*?```/g, "代码示例")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/^[#>*+-]+\s*/gm, "")
    .replace(/\*\*|__/g, "")
    .replace(/\s+/g, " ")
    .trim();
  if (!plain) return "回答已保存在这本书里。";
  return plain.length > maxLength ? `${plain.slice(0, maxLength)}…` : plain;
}

async function pickAndOpenBook() {
  const selected = await open({
    multiple: false,
    filters: [{ name: "PDF", extensions: ["pdf"] }],
  });
  if (typeof selected !== "string") return;
  await importAndOpenBook(selected);
}

async function importAndOpenBook(path: string) {
  const existing = store.books.find((book) => book.path === path);
  if (existing) {
    await openBook(existing);
    return;
  }
  const book: BookRecord = {
    id: crypto.randomUUID(),
    name: fileNameFromPath(path),
    path,
    last_page: 1,
    added_at: Date.now(),
    outline: [],
  };
  store.books = [book, ...store.books.filter((b) => b.id !== book.id)];
  await persist();
  await openBook(book);
}

let dropOverlay: HTMLDivElement | null = null;

function showPdfDropOverlay(message: string, error = false) {
  dropOverlay?.remove();
  const overlay = document.createElement("div");
  overlay.className = `pdf-drop-overlay${error ? " error" : ""}`;
  const title = document.createElement("strong");
  title.textContent = message;
  const hint = document.createElement("span");
  hint.textContent = error ? "请调整后再试" : "松开鼠标即可打开";
  overlay.append(title, hint);
  document.body.appendChild(overlay);
  dropOverlay = overlay;
}

function hidePdfDropOverlay(delay = 0) {
  const overlay = dropOverlay;
  if (!overlay) return;
  window.setTimeout(() => {
    if (dropOverlay === overlay) dropOverlay = null;
    overlay.remove();
  }, delay);
}

async function setupNativePdfDrop() {
  await getCurrentWebview().onDragDropEvent((event) => {
    if (openingBook) {
      if (event.payload.type === "enter" || event.payload.type === "drop") {
        showPdfDropOverlay("正在打开另一份 PDF，请先等待或取消。", true);
        if (event.payload.type === "drop") hidePdfDropOverlay(1600);
      } else if (event.payload.type === "leave") {
        hidePdfDropOverlay();
      }
      return;
    }
    if (event.payload.type === "enter") {
      const decision = decidePdfDrop(event.payload.paths);
      showPdfDropOverlay(decision.accepted ? "打开这份 PDF" : decision.message, !decision.accepted);
      return;
    }
    if (event.payload.type === "leave") {
      hidePdfDropOverlay();
      return;
    }
    if (event.payload.type !== "drop") return;
    const decision = decidePdfDrop(event.payload.paths);
    if (!decision.accepted) {
      showPdfDropOverlay(decision.message, true);
      hidePdfDropOverlay(1600);
      return;
    }
    hidePdfDropOverlay();
    void importAndOpenBook(decision.path);
  });
}

// ---- 打开书 ----
async function openBook(book: BookRecord) {
  // 点的就是当前这本书：只关掉首页回到原位，不重载。
  if (book.id === currentBook?.id && currentDoc) {
    hideHome();
    return;
  }
  if (openingBook) return;
  questionGate.invalidate();
  const abort = new AbortController();
  activeOpenAbort = abort;
  showLoading("正在检查 PDF…", () => abort.abort());
  hideHome();
  openingBook = true;
  let pendingDoc: PDFDocument | null = null;
  let replacedReader = false;
  let resolved: BookRecord = { ...book };
  try {
    resolved = await resolveBookPath(book);
    const info = await inspectPdfFile(resolved.path);
    if (abort.signal.aborted) throw Object.assign(new Error("已取消打开 PDF。"), { name: "PDFLoadCancelledError" });
    resolved.opening = true;
    delete resolved.open_error;
    store.books = store.books.map((item) => (item.id === resolved.id ? resolved : item));
    await persistOrThrow();

    const url = convertFileSrc(resolved.path);
    updateLoading(info.large ? `正在打开大文件（${fileSizeLabel(info.size_bytes)}）…` : "正在打开书…");
    const { PDFDocument } = await import("./pdf");
    pendingDoc = await PDFDocument.load(url, {
      signal: abort.signal,
      stallTimeoutMs: 120_000,
      onProgress: (loaded, total) => {
        if (total > 0) {
          const size = info.large ? ` · ${fileSizeLabel(info.size_bytes)}` : "";
          updateLoading(`正在打开书… ${Math.round((loaded / total) * 100)}%${size}`);
        }
      },
    });

    // PDF 本身已完成解析，再切换阅读器。失败前保留旧书，避免坏文件
    // 把一个原本可用的阅读会话一起拖垮。
    reader?.clear();
    void currentDoc?.destroy();
    replacedReader = true;
    currentBook = resolved;
    currentDoc = pendingDoc;
    pendingDoc = null;
    reader = null;
    history = [];
    sheetQA = null;
    closeTeacherSheet();
    tocDrawer.classList.remove("open");
    bookMenuEl?.remove();
    bookMenuEl = null;
    thumbnailBusy = false;
    thumbnailQueued = false;
    preheating = false;
    preheatPaused = false;
    window.clearTimeout(thumbVirtualTimer);
    readerSurface.replaceChildren();
    showLoading("正在准备页面…", () => abort.abort());

    // 记录总页数（首页进度条用）。
    if (resolved.pageCount !== currentDoc.pageCount) {
      resolved.pageCount = currentDoc.pageCount;
      store.books = store.books.map((b) => (b.id === resolved.id ? resolved : b));
    }
    currentPage = Math.min(Math.max(resolved.last_page, 1), currentDoc.pageCount);
    // 恢复这本书自己的缩放倍数；没记过就是 1（适合窗口）。
    // 每本书记住各自的缩放，切书时不会互相串。
    zoomFactor = clampZoom(resolved.zoom ?? 1);
    bottomBar.style.display = "flex";
    reader = new ScrollReader(readerSurface, currentDoc, {
      onPageChange: (page) => {
        const previousPage = currentPage;
        currentPage = page;
        if (pageTransitionDelta(previousPage, page) > 0) markPageViewed();
        schedulePersistPosition();
        scheduleBottomBarUpdate();
      },
      onRegionSelected: (region) => {
        void askRegionQuestion(region);
      },
    });
    // 打开时直接应用这本书的缩放与布局（单页/双页），
    // 避免先按 100% 渲染再跳变。
    await reader.open(currentPage, zoomFactor, resolved.spread === true, {
      signal: abort.signal,
      onStage: updateLoading,
    });
    ensureScrollListener();
    hideLoading();
    renderBottomBar();
    showReopenCue(resolved);
    buildTOC();
    // 更新书籍列表（路径可能被修正）。
    resolved.opening = false;
    delete resolved.open_error;
    store.books = store.books.map((b) => (b.id === resolved.id ? resolved : b));
    await persistOrThrow();
  } catch (err) {
    void pendingDoc?.destroy();
    const message = pdfOpenErrorMessage(err);
    resolved.opening = false;
    resolved.open_error = message;
    store.books = store.books.map((item) => (item.id === resolved.id ? resolved : item));
    await persist().catch(() => undefined);
    hideLoading();
    if (replacedReader) {
      reader?.clear();
      void currentDoc?.destroy();
      reader = null;
      currentDoc = null;
      currentBook = null;
      readerSurface.replaceChildren();
      bottomBar.style.display = "none";
    }
    showHome();
  } finally {
    openingBook = false;
    if (activeOpenAbort === abort) activeOpenAbort = null;
  }
}

// ---- 加载提示（打开大书时不白屏） ----
function showLoading(message: string, onCancel?: () => void) {
  hideLoading();
  const overlay = document.createElement("div");
  overlay.id = "loading-overlay";
  const spinner = document.createElement("span");
  spinner.className = "spinner";
  const text = document.createElement("span");
  text.className = "loading-message";
  text.textContent = message;
  overlay.append(spinner, text);
  if (onCancel) {
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "loading-cancel";
    cancel.textContent = "取消";
    cancel.addEventListener("click", onCancel, { once: true });
    overlay.appendChild(cancel);
  }
  readerSurface.appendChild(overlay);
}

/// 更新加载提示文字（如进度百分比）。
function updateLoading(text: string) {
  const overlay = readerSurface.querySelector("#loading-overlay") as HTMLElement | null;
  if (!overlay) return;
  const message = overlay.querySelector<HTMLElement>(".loading-message");
  if (message) message.textContent = text;
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

// ---- 渲染：翻页阅读器接管，这里只做翻页/缩放入口 ----

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

function describePageSelection(pages: number[]): string {
  if (pages.length === 0) return "没有可发送的页面";
  if (pages.length === 1) return `PDF 第 ${pages[0]} 页（1 张）`;
  const first = pages[0];
  const last = pages[pages.length - 1];
  const step = pages[1] - first;
  if (pages.every((page, index) => index === 0 || page - pages[index - 1] === step)) {
    if (step === 1) return `PDF 第 ${first}–${last} 页（${pages.length} 张）`;
    if (step === 2) return `PDF 从第 ${first} 页起每隔一页，到第 ${last} 页（${pages.length} 张）`;
  }
  return `PDF 第 ${pages.join("、")} 页（${pages.length} 张）`;
}

function buildTOC() {
  tocDrawer.innerHTML = "";
  const renderedBook = currentBook;
  const renderedDoc = currentDoc;

  // PDF 目录（章节快速跳转）。
  const tocHeader = document.createElement("div");
  tocHeader.className = "toc-header";
  const tocHeading = document.createElement("div");
  const tocTitle = document.createElement("strong");
  tocTitle.textContent = "这本书";
  const tocBook = document.createElement("span");
  tocBook.textContent = currentBook ? bookName(currentBook.name) : "目录";
  tocHeading.append(tocTitle, tocBook);
  const tocClose = document.createElement("button");
  tocClose.type = "button";
  tocClose.textContent = "×";
  tocClose.setAttribute("aria-label", "收起目录");
  tocClose.addEventListener("click", () => tocDrawer.classList.remove("open"));
  tocHeader.append(tocHeading, tocClose);
  tocDrawer.appendChild(tocHeader);
  const tocContent = document.createElement("div");
  tocContent.className = "toc-content";
  tocDrawer.appendChild(tocContent);

  const isCurrentTOC = () =>
    tocContent.isConnected &&
    currentDoc === renderedDoc &&
    (currentBook?.id ?? null) === (renderedBook?.id ?? null);

  const renderOutline = (outline: OutlineEntry[], sourceNote: string) => {
    if (!isCurrentTOC()) return;
    tocContent.replaceChildren();
    if (outline.length === 0) {
      const empty = document.createElement("div");
      empty.className = "toc-item depth-2";
      empty.textContent = sourceNote || "这本书还没有目录。";
      tocContent.appendChild(empty);
      return;
    }
    for (const item of outline) {
      const el = document.createElement("button");
      el.type = "button";
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
      tocContent.appendChild(el);
    }
  };

  const renderOutlineRecovery = (book: BookRecord, errorMessage: string | null) => {
    if (!isCurrentTOC()) return;
    const recovering = outlineRecovering.has(book.id);
    tocContent.replaceChildren();

    const empty = document.createElement("section");
    empty.className = "toc-recovery";
    const title = document.createElement("strong");
    title.textContent = errorMessage ? "目录识别没有完成" : "这本书没有内置目录";
    const plan = outlineEvidencePlan(renderedDoc?.pageCount ?? book.pageCount ?? 0);
    const description = document.createElement("p");
    description.id = "toc-recovery-disclosure";
    description.textContent =
      `点击后会分两次把书页发送到当前 AI 服务：先发送${describePageSelection(plan.outlinePages)}识别章节，` +
      `再发送${describePageSelection(plan.chapterProbePages)}定位第一章。打开书本身不会发送内容。`;
    const error = errorMessage ? document.createElement("p") : null;
    if (error) {
      error.id = "toc-recovery-error";
      error.textContent = errorMessage;
    }
    const action = document.createElement("button");
    action.type = "button";
    action.textContent = recovering ? "正在识别…" : errorMessage ? "重新识别" : "识别目录";
    action.disabled = recovering;
    action.setAttribute("aria-describedby", error ? `${error.id} ${description.id}` : description.id);
    action.addEventListener("click", () => void recoverScannedOutline());
    empty.append(title);
    if (error) empty.append(error);
    empty.append(description, action);
    tocContent.appendChild(empty);
  };

  if (renderedDoc && renderedBook) {
    void renderedDoc.getOutline()
      .then((native) => {
        if (!isCurrentTOC()) return;
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
        effectiveOutline = renderedBook.outline;
        if (renderedBook.outline.length > 0) {
          renderOutline(renderedBook.outline, "");
        } else {
          const errHint = sessionStorage.getItem(`outline-err-${renderedBook.id}`);
          renderOutlineRecovery(renderedBook, errHint);
        }
        scheduleBottomBarUpdate();
      })
      .catch((error) => {
        if (!isCurrentTOC()) return;
        effectiveOutline = renderedBook.outline;
        if (renderedBook.outline.length > 0) {
          renderOutline(renderedBook.outline, "");
        } else {
          renderOutlineRecovery(renderedBook, `无法读取 PDF 内置目录：${String(error)}`);
        }
        scheduleBottomBarUpdate();
      });
  } else {
    effectiveOutline = [];
    renderOutline(currentBook?.outline ?? [], "打开一本书后这里会显示目录。");
  }
}

// ---- 扫描书目录恢复（明确触发） ----
/// 正在恢复目录的书。单书 single-flight，失败后允许用户主动重试。
const outlineRecovering = new Set<string>();

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

/// 用户在目录抽屉明确点击后调用：用当前 AI 服务读取目录候选页，
/// 再定位第一章算出偏移并映射成 PDF 页码。
async function recoverScannedOutline() {
  const profile = await activeProfileForAI("请先配置当前 AI 服务，再识别目录。");
  if (!profile) return;
  if (!currentDoc || !currentBook) return;
  // 捕获本次处理的书身份；识别期间切书后立即放弃结果。
  const bookId = currentBook.id;
  const doc = currentDoc;
  // 已有目录（内置或之前恢复过）就不再处理。
  if (currentBook.outline.length > 0) return;
  if (outlineRecovering.has(bookId)) return;
  outlineRecovering.add(bookId);
  sessionStorage.removeItem(`outline-err-${bookId}`);
  buildTOC();

  try {
    const native = await doc.getOutline().catch(() => []);
    if (native.length > 0) return;
    if (currentDoc !== doc || currentBook?.id !== bookId) return;

    const pageCount = doc.pageCount;
    // 两阶段页面计划同时用于点击前披露，不能在请求处另写一套范围。
    const evidencePlan = outlineEvidencePlan(pageCount);
    if (evidencePlan.outlinePages.length === 0) {
      throw new Error("页数太少，无法从书前内容识别目录。");
    }

    // 目录识别的渲染阶段需要独占 PDF.js worker；暂停缩略图预热。
    preheatPaused = true;
    // 1) 渲染目录候选页 → Qwen 提取目录（印刷页码）。
    const pages = await exportEvidence(
      doc,
      evidencePlan.outlinePages,
      1.3,
    );
    if (currentDoc !== doc || currentBook?.id !== bookId) return;
    const entries = await extractOutline(profile.id, { pages });
    if (entries.length === 0) throw new Error("没有从书前几页找到可用的章节目录。");
    if (currentDoc !== doc || currentBook?.id !== bookId) return;

    // 清洗目录：去前置/考试说明条目（封面/前言/考试大纲/考核目标/题型举例/
    // 参考答案 等），与内置目录的清洗规则一致。
    const bodyEntries = cleanOutline(entries);
    if (bodyEntries.length === 0) throw new Error("识别结果里没有可用的章节条目。");

    // 2) 找第一章：优先选标题带「第X章」的 depth=0 条目（取最小印刷页），
    // 避免把未过滤的前置项（如「软件工程自学考试大纲」）当第一章。
    const chapters = bodyEntries.filter((e) => e.depth === 0 && /第[一二三四五六七八九十\d]+[章篇]/.test(e.title));
    const fallbackChapters = bodyEntries.filter((e) => e.depth === 0);
    const firstChapter = (chapters.length > 0 ? chapters : fallbackChapters).reduce((a, b) =>
      b.page < a.page ? b : a,
    );
    const probePages = await exportEvidence(
      doc,
      evidencePlan.chapterProbePages,
      1.3,
    );
    if (currentDoc !== doc || currentBook?.id !== bookId) return;
    const foundPdfPage = await findPageByTitle(profile.id, firstChapter.title, probePages);
    if (foundPdfPage === 0) throw new Error("找到了目录，但没有定位到第一章所在的 PDF 页。");
    if (currentDoc !== doc || currentBook?.id !== bookId) return;

    // 偏移 = 第一章实际 PDF 页 - 第一章印刷页。
    const offset = foundPdfPage as number - firstChapter.page;

    // 3) 映射所有条目为 PDF 页码并持久化。
    const mapped: OutlineEntry[] = bodyEntries
      .map((e) => ({ title: e.title, depth: e.depth, page: e.page + offset }))
      .filter((e) => e.page >= 1 && e.page <= pageCount);
    if (mapped.length === 0) throw new Error("识别到的章节页码不在这本 PDF 的范围内。");

    currentBook.outline = mapped;
    store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
    await persist();
    sessionStorage.removeItem(`outline-err-${bookId}`);
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
    outlineRecovering.delete(bookId);
    if (currentDoc === doc && currentBook?.id === bookId) buildTOC();
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
  sheetQA = { question: entry.question, answer: entry.answer, page: entry.page };
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
  if (!currentDoc) return;
  const profile = await activeProfileForAI("请先选择一个已配置的 AI 服务，再解释这处内容。");
  if (!profile) return;
  const context = beginQuestionContext(region.page);
  if (!context) return;

  const question = "我在整页图里用红色框标出了选中的区域，解释一下红框里这块内容。如果看不清就直说，不要猜。";
  const storedQuestion = `${question}（框选区域）`;
  history.push({ role: "user", content: `${question}（框选第 ${region.page} 页区域）` });
  openTeacherSheet(question);
  const answerNode = teacherSheet.querySelector(".turn.answer") as HTMLDivElement;
  answerNode.classList.add("streaming");
  showTyping(answerNode);
  let fullText = "";

  try {
    // 框选区域截图为最高优先证据；整页图用红框标出选中位置，
    // 让模型一眼看到选的是哪块（否则它会说「图片里没有框选区域」）。
    const regionJPEG = await context.doc.exportRegionAsJPEG(region.page, region.rect);
    const pageJPEG = await context.doc.exportPageAsJPEG(region.page, 1.5, region.rect);
    if (!questionContextIsCurrent(context)) return;

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
        if (!questionContextIsCurrent(context)) return;
        fullText += chunk;
        setAnswerContent(answerNode, fullText);
        const sc = teacherSheet.querySelector(".qa-scroll");
        if (sc) sc.scrollTop = sc.scrollHeight;
      },
    );
    if (!questionContextIsCurrent(context)) return;
    setAnswerContent(answerNode, fullText);
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode);
    if (sheetQA) sheetQA.answer = fullText;
    await saveQA(context.bookId, context.page, storedQuestion, fullText);
  } catch (err) {
    if (!questionContextIsCurrent(context)) return;
    if (history[history.length - 1]?.role === "user") history.pop();
    showRetryableAIError(answerNode, err, () => void askRegionQuestion(region));
    answerNode.classList.remove("streaming");
  } finally {
    questionGate.finish(context.token);
  }
}


/// 把若干页渲染成 JPEG 数组，供 Rust 端作为多图证据。
async function exportEvidence(
  doc: PDFDocument,
  pages: number[],
  scale = 1.5,
): Promise<{ page: number; jpeg: string }[]> {
  const out: { page: number; jpeg: string }[] = [];
  for (const page of pages) {
    const jpeg = await doc.exportPageAsJPEG(page, scale);
    out.push({ page, jpeg });
  }
  return out;
}

// ---- 核心提问闭环 ----
async function askQuestion(question: string) {
  if (!currentDoc) return;
  const profile = await activeProfileForAI("请先选择一个已配置的 AI 服务，再向老师提问。");
  if (!profile) return;
  const context = beginQuestionContext();
  if (!context) return;

  history.push({ role: "user", content: question });
  openTeacherSheet(question);
  const answerNode = teacherSheet.querySelector(".turn.answer") as HTMLDivElement;
  answerNode.classList.add("streaming");
  showTyping(answerNode);
  let fullText = "";

  try {
    // 页面图像即证据；跨页内容按自然语言触发自动扩页。
    const pages = requestedEvidencePages(context.page, context.doc.pageCount, question);
    const evidence = await exportEvidence(context.doc, pages);
    if (!questionContextIsCurrent(context)) return;

    fullText = await askVisual(
      profile.id,
      {
        question,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        if (!questionContextIsCurrent(context)) return;
        fullText += chunk;
        setAnswerContent(answerNode, fullText);
        const sc = teacherSheet.querySelector(".qa-scroll");
        if (sc) sc.scrollTop = sc.scrollHeight;
      },
    );
    if (!questionContextIsCurrent(context)) return;
    setAnswerContent(answerNode, fullText);
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode);
    if (sheetQA) sheetQA.answer = fullText;
    await saveQA(context.bookId, context.page, question, fullText);
  } catch (err) {
    if (!questionContextIsCurrent(context)) return;
    if (history[history.length - 1]?.role === "user") history.pop();
    showRetryableAIError(answerNode, err, () => void askQuestion(question));
    answerNode.classList.remove("streaming");
  } finally {
    questionGate.finish(context.token);
  }
}

// ---- 老师面板 ----

/// 面板当前展示的问答（从「问过的」列表返回时恢复用）。
let sheetQA: { question: string; answer: string; page: number } | null = null;
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

function showRetryableAIError(answerNode: HTMLDivElement, error: unknown, retry: () => void) {
  setAnswerContent(answerNode, `出错了：${actionableConnectionError(error)}`);
  const actions = document.createElement("div");
  actions.className = "actions";
  const retryButton = document.createElement("button");
  retryButton.type = "button";
  retryButton.textContent = "重试";
  retryButton.addEventListener("click", retry, { once: true });
  const settingsButton = document.createElement("button");
  settingsButton.type = "button";
  settingsButton.textContent = "打开 AI 设置";
  settingsButton.addEventListener("click", () => openSettings("检查当前服务、模型和 Key 后，可以回来重试。"));
  actions.append(retryButton, settingsButton);
  answerNode.appendChild(actions);
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
  const input = document.createElement("textarea");
  input.rows = 1;
  input.placeholder = placeholder;
  input.setAttribute("aria-label", "继续问这本书");
  const send = document.createElement("button");
  send.type = "button";
  send.textContent = "问";
  send.setAttribute("aria-label", "发送问题");
  send.disabled = true;

  const syncSendState = () => {
    send.disabled = input.value.trim() === "";
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 88)}px`;
  };
  const submit = () => {
    const text = input.value.trim();
    if (!text || questionGate.busy) return;
    input.value = "";
    syncSendState();
    onSubmit(text);
  };

  input.addEventListener("input", syncSendState);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
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
  appendActions(a);
  scroll.appendChild(a);
  teacherSheet.append(scroll);
  showTeacherSheet();
  appendComposer("还有哪里没想通？", (text) => void followUp(text));
}

/// 老师卡片头部：拖拽条 + 「问过的」切换 + 收起按钮。三种视图共用。
function buildSheetHeader(): HTMLDivElement {
  const header = document.createElement("div");
  header.className = "sheet-header";
  const grip = document.createElement("div");
  grip.className = "grip";
  grip.title = "收起";
  grip.addEventListener("click", closeTeacherSheet);

  const heading = document.createElement("div");
  heading.className = "sheet-heading";
  const title = document.createElement("strong");
  title.textContent = sheetHistoryMode ? "问答记录" : "问书";
  const context = document.createElement("span");
  const contextPage = !sheetHistoryMode && sheetQA ? sheetQA.page : currentPage;
  const chapter = chapterLabelForPage(contextPage);
  context.textContent = currentBook
    ? `第 ${contextPage} 页${chapter ? ` · ${chapter}` : ""}`
    : "和这一页一起想清楚";
  heading.append(title, context);

  // 「问过的」：在面板里切换「当前问答 ⇄ 这本书问过的问题列表」。
  const historyBtn = document.createElement("button");
  historyBtn.className = "sheet-history";
  historyBtn.textContent = sheetHistoryMode ? "返回" : "回看";
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
  close.textContent = "×";
  close.setAttribute("aria-label", "收起问书面板");
  close.addEventListener("click", closeTeacherSheet);
  header.append(grip, heading, historyBtn, close);
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
        const item = document.createElement("button");
        item.type = "button";
        item.className = "qa-history-item";
        const meta = document.createElement("span");
        meta.textContent = `第 ${entry.page} 页`;
        const question = document.createElement("strong");
        question.textContent = entry.question;
        const excerpt = document.createElement("span");
        excerpt.textContent = plainTextExcerpt(entry.answer, 60);
        item.append(meta, question, excerpt);
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
  sheetQA = { question, answer: "", page: currentPage };
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
/// “讲讲这一页”之后，才会读取系统安全凭据并调用模型。
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
  const eyebrow = document.createElement("span");
  eyebrow.className = "teacher-eyebrow";
  eyebrow.textContent = "从眼前这页开始";
  const title = document.createElement("h3");
  title.textContent = "你想先弄懂什么？";
  const hint = document.createElement("p");
  hint.textContent = "说出卡住的地方，或选一个起点。只有你发问后，我才会读取书页。";
  const starts = document.createElement("div");
  starts.className = "teacher-starts";
  const suggestions = [
    { label: "先概括这一页", action: () => void askPageQuestion() },
    {
      label: "说清核心概念",
      action: () => void askQuestion("这一页最核心的概念是什么？先用大白话说清楚，再指出书上对应的位置。"),
    },
    {
      label: "带我走一个例子",
      action: () => void askQuestion("请用一个具体的小例子，带我一步步理解这一页。"),
    },
  ];
  for (const suggestion of suggestions) {
    const quick = document.createElement("button");
    quick.type = "button";
    quick.className = "teacher-page-explain";
    quick.textContent = suggestion.label;
    quick.addEventListener("click", () => {
      for (const button of starts.querySelectorAll("button")) button.setAttribute("disabled", "true");
      suggestion.action();
    });
    starts.appendChild(quick);
  }
  prompt.append(eyebrow, title, hint, starts);
  teacherSheet.append(prompt);
  showTeacherSheet();
  appendComposer("把不懂的地方说给我听…", (text) => void askQuestion(text), "prompt-composer");
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
  if (!currentDoc) return;
  const profile = await activeProfileForAI("当前 AI 服务尚未配置完成。请先保存 Key，再重试这次提问。");
  if (!profile) return;
  const context = beginQuestionContext();
  if (!context) return;

  history.push({ role: "user", content: text });

  // 在面板里追加一轮
  const scroll = teacherSheet.querySelector(".qa-scroll") as HTMLDivElement | null;
  if (!scroll) {
    questionGate.finish(context.token);
    return;
  }
  const q = document.createElement("div");
  q.className = "turn question";
  q.textContent = text;
  scroll.appendChild(q);
  const a = document.createElement("div");
  a.className = "turn answer streaming";
  showTyping(a);
  scroll.appendChild(a);
  scroll.scrollTop = scroll.scrollHeight;

  let fullText = "";
  try {
    const pages = requestedEvidencePages(context.page, context.doc.pageCount, text);
    const evidence = await exportEvidence(context.doc, pages);
    if (!questionContextIsCurrent(context)) return;

    fullText = await askVisual(
      profile.id,
      {
        question: text,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        if (!questionContextIsCurrent(context)) return;
        fullText += chunk;
        setAnswerContent(a, fullText);
        scroll.scrollTop = scroll.scrollHeight;
      },
    );
    if (!questionContextIsCurrent(context)) return;
    setAnswerContent(a, fullText);
    history.push({ role: "assistant", content: fullText });
    a.classList.remove("streaming");
    appendActions(a);
    sheetQA = { question: text, answer: fullText, page: context.page };
    await saveQA(context.bookId, context.page, text, fullText);
  } catch (err) {
    if (!questionContextIsCurrent(context)) return;
    if (history[history.length - 1]?.role === "user") history.pop();
    showRetryableAIError(a, err, () => void followUp(text));
    a.classList.remove("streaming");
  } finally {
    questionGate.finish(context.token);
  }
}

// ---- 持久化 ----
const storePersistence = new StorePersistence(
  () => structuredClone(store),
  saveStore,
  {
    setTimeout: (callback, delayMs) => window.setTimeout(callback, delayMs),
    clearTimeout: (id) => window.clearTimeout(id),
  },
);

/** 串行保存完整 Store，避免较早的快照晚到后覆盖刚改好的 AI 连接。 */
function persistOrThrow(): Promise<void> {
  return storePersistence.persist();
}

async function persist() {
  await persistOrThrow().catch(() => undefined);
}

/** 正常关闭前取消所有延迟，并把当前阅读状态作为最后一个快照写盘。 */
async function flushPendingPersistence(): Promise<void> {
  if (!storeLoaded) {
    await completeAppExit();
    return;
  }
  window.clearTimeout(wheelCommitTimer);
  wheelCommitTimer = undefined;
  checkpointCurrentReadingState();
  await storePersistence.flush(completeAppExit);
}

let exitRequest: Promise<void> | null = null;
function requestAppExit(): Promise<void> {
  if (exitRequest) return exitRequest;
  questionGate.invalidate();
  exitRequest = (async () => {
    try {
      await flushPendingPersistence();
    } catch (error) {
      storePersistence.resume();
      exitRequest = null;
      showFatalError(`退出前无法保存阅读进度：${String(error)}`);
    }
  })();
  return exitRequest;
}

async function setupExitPersistence(): Promise<void> {
  await getCurrentWindow().onCloseRequested((event) => {
    // 必须在任何 await 前阻止默认销毁，给最后一次 Store 写入留出时间。
    event.preventDefault();
    void requestAppExit();
  });
}

async function saveQA(bookId: string, page: number, question: string, answer: string) {
  if (!store.books.some((book) => book.id === bookId)) return;
  const entry: QAEntry = {
    id: crypto.randomUUID(),
    book_id: bookId,
    page,
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
      if (!shouldHandlePageFlipWheel(e)) return;
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
    if (questionGate.busy) return;
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
          wheelCommitTimer = undefined;
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
  const primaryModifier = hasPrimaryModifier(e);
  if (document.getElementById("settings-modal")) {
    if (primaryModifier && e.key === ",") e.preventDefault();
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
  if (primaryModifier && e.key === "t") {
    tocDrawer.classList.toggle("open");
  }
  if (primaryModifier && e.key === ",") {
    openSettings();
  }
  // 缩放：Command（macOS）或 Control（Windows）配合 +/-，0 回到铺满宽度。
  if (primaryModifier && (e.key === "=" || e.key === "+")) {
    e.preventDefault();
    zoomFactor = Math.min(3, zoomFactor + 0.15);
    void applyZoom();
    return;
  }
  if (primaryModifier && e.key === "-") {
    e.preventDefault();
    zoomFactor = Math.max(0.5, zoomFactor - 0.15);
    void applyZoom();
    return;
  }
  if (primaryModifier && e.key === "0") {
    e.preventDefault();
    zoomFactor = 1;
    void applyZoom();
    return;
  }
  if (typing) return; // 输入中：不响应全局翻页/缩放
  if (homeView.classList.contains("open")) return; // 首页打开时不翻隐藏的阅读器
  if (!primaryModifier && (e.key === "ArrowRight" || e.key === "ArrowDown" || e.key === "PageDown")) {
    reader?.flipPage(1);
  }
  if (!primaryModifier && (e.key === "ArrowLeft" || e.key === "ArrowUp" || e.key === "PageUp")) {
    reader?.flipPage(-1);
  }
});

async function applyZoom() {
  if (!reader) return;
  await reader.setZoom(zoomFactor);
  updateBottomBarZoom();
  persistZoom();
}

/// 记住当前书自己的缩放倍数，并防抖写盘。
function persistZoom() {
  checkpointCurrentReadingState();
  storePersistence.schedule("zoom", 400);
}

// ---- 底部工具栏（原生阅读器风格） ----

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
  bookBtn.textContent = currentBook ? bookName(currentBook.name) : "书";
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
  const pageNum = document.createElement("button");
  pageNum.type = "button";
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
  const zoomPct = document.createElement("button");
  zoomPct.type = "button";
  zoomPct.className = "zoom-pct";
  zoomPct.title = "回到适合窗口";
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

  // 布局切换：单页 ⇄ 双页（书本展开）。每本书记住自己的偏好。
  const layoutBtn = document.createElement("button");
  layoutBtn.className = "action-btn layout-btn";
  layoutBtn.addEventListener("click", () => {
    void applyLayout(currentBook?.spread !== true);
  });

  const chapterLabel = document.createElement("span");
  chapterLabel.className = "chapter-label";

  const libraryGroup = document.createElement("div");
  libraryGroup.className = "rail-group rail-library";
  libraryGroup.append(homeBtn, bookBtn, reviewBtn);
  const navigationGroup = document.createElement("div");
  navigationGroup.className = "rail-group rail-navigation";
  navigationGroup.append(prev, pageNum, next);
  const contextGroup = document.createElement("div");
  contextGroup.className = "rail-context";
  contextGroup.appendChild(chapterLabel);
  const viewGroup = document.createElement("div");
  viewGroup.className = "rail-group rail-view";
  viewGroup.append(zoomGroup, layoutBtn);

  bottomBar.append(libraryGroup, navigationGroup, contextGroup, viewGroup, thumbs);
  updateBottomBarZoom();
  updateLayoutButton();

  // 先渲染当前页附近的缩略图，滚动时按需补充并更新高亮。
  void renderAllThumbnails();
}

/// 当前页所在的章级标题（目录里 depth=0 的最后一条 ≤ 当前页的条目），
/// 没有目录时返回空。
function currentChapterLabel(): string {
  return chapterLabelForPage(currentPage);
}

function chapterLabelForPage(page: number): string {
  let chapter = "";
  for (const item of effectiveOutline) {
    if (item.page > page) break;
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
  btn.title = spread ? "切换为单页" : "切换为双页（书本展开，两页并排）";
}

/// 切换单页/双页布局，并把偏好记到当前书。
/// 换布局后回到「适合窗口」（单页或整个展开都不超出视口）。
async function applyLayout(spread: boolean) {
  if (!reader) return;
  zoomFactor = 1;
  await reader.setZoom(1);
  await reader.setSpread(spread);
  if (currentBook) {
    currentBook.spread = spread;
    currentBook.zoom = zoomFactor; // 布局切换后回到适合窗口，一并记住
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
  const homeItem = document.createElement("button");
  homeItem.type = "button";
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

      const switchBook = document.createElement("button");
      switchBook.type = "button";
      switchBook.className = "book-menu-switch";
      switchBook.title = book.path;
      const name = document.createElement("span");
      name.className = "book-menu-name";
      name.textContent = book.name;
      const info = document.createElement("span");
      info.className = "book-menu-info";
      info.textContent = book.id === currentBook?.id ? "正在读" : `读到第 ${book.last_page} 页`;
      switchBook.append(name, info);
      switchBook.addEventListener("click", () => {
        menu.remove();
        bookMenuEl = null;
        if (book.id !== currentBook?.id) void openBook(book);
      });

      // 删除按钮（悬停时出现）。
      const del = document.createElement("button");
      del.type = "button";
      del.className = "book-menu-del";
      del.textContent = "移除";
      del.title = "从书架移除（不删除原文件）";
      del.addEventListener("click", (e) => {
        e.stopPropagation();
        void removeBook(book);
      });

      item.append(switchBook, del);
      if (book.id === currentBook?.id) item.classList.add("current");
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

function confirmBookRemoval(book: BookRecord, qaCount: number): Promise<boolean> {
  const dialog = document.createElement("dialog");
  dialog.className = "book-remove-dialog";
  dialog.setAttribute("aria-labelledby", "book-remove-title");
  dialog.setAttribute("aria-describedby", "book-remove-message");

  const title = document.createElement("h2");
  title.id = "book-remove-title";
  title.textContent = `从书架移除“${bookName(book.name)}”？`;
  const message = document.createElement("p");
  message.id = "book-remove-message";
  const qaMessage = qaCount > 0 ? `以及 ${qaCount} 条问答记录` : "";
  message.textContent = `原 PDF 不会被删除，但阅读位置、目录${qaMessage}会从 Satori 清除。`;

  const actions = document.createElement("div");
  actions.className = "book-remove-actions";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "book-remove-cancel";
  cancel.textContent = "取消";
  const confirm = document.createElement("button");
  confirm.type = "button";
  confirm.className = "book-remove-confirm";
  confirm.textContent = "移除";
  actions.append(cancel, confirm);
  dialog.append(title, message, actions);
  document.body.appendChild(dialog);

  return new Promise((resolve) => {
    const finish = (confirmed: boolean) => {
      dialog.close();
      dialog.remove();
      resolve(confirmed);
    };
    dialog.addEventListener("cancel", (event) => {
      event.preventDefault();
      finish(false);
    }, { once: true });
    cancel.addEventListener("click", () => finish(false), { once: true });
    confirm.addEventListener("click", () => finish(true), { once: true });
    dialog.showModal();
    cancel.focus();
  });
}

/// 从书架移除一本书（不删除电脑上的原 PDF 文件），连带清掉它的问答记录。
async function removeBook(book: BookRecord) {
  const menuWasOpen = bookMenuEl !== null;
  const homeWasOpen = homeView.classList.contains("open");
  bookMenuEl?.remove();
  bookMenuEl = null;

  const qaCount = store.qa.filter((q) => q.book_id === book.id).length;
  if (!(await confirmBookRemoval(book, qaCount))) return;

  // 从书库移除 + 清掉该书问答。
  store.books = store.books.filter((b) => b.id !== book.id);
  store.qa = store.qa.filter((q) => q.book_id !== book.id);
  await persist();

  const uiActions = decideBookRemovalUI({
    removingCurrentBook: currentBook?.id === book.id,
    remainingBookCount: store.books.length,
    homeWasOpen,
    menuWasOpen,
  });

  // 删除的是当前书：切换到剩余第一本，或回到空书架。
  if (uiActions.currentBookAction !== "keep-current") {
    questionGate.invalidate();
    currentDoc?.destroy();
    currentDoc = null;
    reader?.clear();
    reader = null;
    currentBook = null;
    history = [];
    sheetQA = null;
    closeTeacherSheet();
    tocDrawer.classList.remove("open");
    if (uiActions.currentBookAction === "open-first-remaining") {
      await openBook(store.books[0]);
    } else {
      showHome();
    }
  } else {
    // 非当前书：首页与书菜单都可能已经渲染了被删除的书，需要按删除前的
    // 可见状态刷新。菜单在确认前已关闭，因此这里只能依据快照重开。
    if (uiActions.renderHome) renderHome();
    if (uiActions.reopenBookMenu) toggleBookMenu();
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
    el.style.borderColor = p === currentPage ? "var(--accent)" : "transparent";
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

function checkpointCurrentReadingState() {
  if (!currentBook) return;
  currentBook.last_page = currentPage;
  currentBook.zoom = zoomFactor;
  store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
  // 把本轮翻过的页数记进当天的活动量，随下次持久化一起落盘。
  if (todayPagesPending > 0) {
    bumpActivity("pages", todayPagesPending);
    todayPagesPending = 0;
  }
}

function persistReadingPosition() {
  checkpointCurrentReadingState();
  void persist();
}

/// 滚动触发时防抖保存阅读位置。
function schedulePersistPosition() {
  checkpointCurrentReadingState();
  storePersistence.schedule("reading-position", 800);
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
