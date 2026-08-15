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
  clearApiKey,
  emptyStore,
  listModelOptions,
  loadStore,
  readApiKey,
  resolveBookPath,
  saveApiKey,
  saveDevKey,
  saveStore,
  type BookRecord,
  type HistoryTurn,
  type ModelOption,
  type QAEntry,
  type Store,
} from "./api";
import { PDFDocument } from "./pdf";
import { ScrollReader, type RegionSelection } from "./reader";

// ---- DOM ----
const readerSurface = document.getElementById("reader-surface") as HTMLDivElement;
const teacherSheet = document.getElementById("teacher-sheet") as HTMLDivElement;
const tocDrawer = document.getElementById("toc-drawer") as HTMLDivElement;
const selectionCapsule = document.getElementById("selection-capsule") as HTMLButtonElement;
const bottomBar = document.getElementById("bottom-bar") as HTMLDivElement;

// ---- 状态 ----
let store: Store = emptyStore();
let apiKey: string | null = null;
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

// ---- 启动 ----
async function boot() {
  store = await loadStore().catch(() => emptyStore());
  apiKey = await readApiKey().catch(() => null);

  if (store.books.length > 0 && !apiKey) {
    // 有书但没有 Key：先问 Key（老师需要能说话）。
    openSettings(true);
  } else if (store.books.length === 0) {
    showEmptyState();
  } else {
    const book = store.books[0];
    await openBook(book);
  }
  setupReaderSurface();
  setupAskFab();
  setupSheetDrag();

  // 阅读面尺寸变化时重新铺满（保留当前页）。用 ResizeObserver 监听
  // 阅读面本身，比 window resize 更可靠——初次加载时窗口事件可能丢失，
  // 而 ResizeObserver 在 WebView 真正完成布局后必然触发一次。
  const resizeObserver = new ResizeObserver(() => {
    if (!reader || !currentDoc) return;
    window.clearTimeout(observerTimer);
    observerTimer = window.setTimeout(() => void relayoutOnResize(), 120);
  });
  resizeObserver.observe(readerSurface);
}

let observerTimer: number | undefined;

async function relayoutOnResize() {
  if (!reader || !currentDoc) return;
  const anchor = reader.currentPage();
  await reader.setZoom(zoomFactor);
  reader.scrollToPage(anchor, true);
  void reader.onScroll();
}

// ---- 空书架 ----
function showEmptyState() {
  bottomBar.style.display = "none";
  readerSurface.innerHTML = `
    <div id="empty-state">
      <div class="hint">打开就开始理解</div>
      <button class="open-book">打开一本书</button>
    </div>`;
  readerSurface.querySelector(".open-book")!.addEventListener("click", () => void pickAndOpenBook());
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
  };
  store.books = [book, ...store.books.filter((b) => b.id !== book.id)];
  await persist();
  await openBook(book);
}

// ---- 打开书 ----
async function openBook(book: BookRecord) {
  showLoading("正在打开书…");
  try {
    const resolved = await resolveBookPath(book);
    currentBook = resolved;
    const url = convertFileSrc(resolved.path);
    currentDoc = await PDFDocument.load(url);
    currentPage = Math.min(Math.max(resolved.last_page, 1), currentDoc.pageCount);
    // 每本书从「适合宽度」开始，不继承上次的缩放状态。
    zoomFactor = 1;
    readerSurface.innerHTML = "";
    bottomBar.style.display = "flex";
    reader = new ScrollReader(readerSurface, currentDoc, {
      onPageChange: (page) => {
        currentPage = page;
        schedulePersistPosition();
        scheduleBottomBarUpdate();
      },
      onRegionSelected: (region) => {
        void askRegionQuestion(region);
      },
    });
    await reader.open(currentPage);
    readerSurface.addEventListener("scroll", () => void reader?.onScroll(), { passive: true });
    hideLoading();
    renderBottomBar();
    showReopenCue(resolved);
    buildTOC();
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
  }
}

// ---- 加载提示（打开大书时不白屏） ----
function showLoading(message: string) {
  hideLoading();
  const overlay = document.createElement("div");
  overlay.id = "loading-overlay";
  overlay.textContent = message;
  readerSurface.appendChild(overlay);
}

function hideLoading() {
  readerSurface.querySelector("#loading-overlay")?.remove();
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

// ---- 目录与回看 ----
function buildTOC() {
  tocDrawer.innerHTML = "";
  const title = document.createElement("div");
  title.className = "toc-section-title";
  title.textContent = "回看 · 问过的";
  tocDrawer.appendChild(title);

  if (!currentBook) return;
  const mine = store.qa
    .filter((q) => q.book_id === currentBook!.id)
    .sort((a, b) => b.ts - a.ts);

  if (mine.length === 0) {
    const empty = document.createElement("div");
    empty.className = "toc-item depth-2";
    empty.textContent = "还没有问过问题。划选一段，或点「问这一页」。";
    tocDrawer.appendChild(empty);
    return;
  }

  for (const entry of mine.slice(0, 50)) {
    const item = document.createElement("div");
    item.className = "toc-item depth-1";
    const question = entry.question.length > 28 ? `${entry.question.slice(0, 28)}…` : entry.question;
    item.textContent = `第 ${entry.page} 页 · ${question}`;
    item.addEventListener("click", () => {
      tocDrawer.classList.remove("open");
      void reopenQA(entry);
    });
    tocDrawer.appendChild(item);
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
  // 在老师面板里展示这条历史问答。
  teacherSheet.innerHTML = "";
  const scroll = document.createElement("div");
  scroll.className = "qa-scroll";
  const q = document.createElement("div");
  q.className = "turn question";
  q.textContent = entry.question;
  scroll.appendChild(q);
  const a = document.createElement("div");
  a.className = "turn answer";
  a.textContent = entry.answer;
  scroll.appendChild(a);
  teacherSheet.append(scroll);
  teacherSheet.classList.add("open");
}

// ---- 提问：整页 ----
async function askPageQuestion() {
  const question = "这一页在讲什么？用大白话讲。";
  await askQuestion(question, null);
}

// ---- 提问：选中段 ----
async function askSelectionQuestion(selection: { text: string; page: number }) {
  const question = `解释一下我选的这段：\n${selection.text}`;
  await askQuestion(question, selection.text);
}

// ---- 提问：框选区域（扫描版也能用） ----
async function askRegionQuestion(region: RegionSelection) {
  if (!currentDoc || !apiKey) {
    openSettings(true);
    return;
  }
  if (streaming) return;

  // 框选区域截图为最高优先证据，同时带上所在页全文作为上下文。
  const regionJPEG = await currentDoc.exportRegionAsJPEG(region.page, region.rect);
  const pageJPEG = await currentDoc.exportPageAsJPEG(region.page);
  const question = "解释一下我框选的这块内容。如果看不清就直说，不要猜。";

  history.push({ role: "user", content: `${question}（框选第 ${region.page} 页区域）` });

  openTeacherSheet(question);
  const answerNode = teacherSheet.querySelector(".turn.answer") as HTMLDivElement;
  answerNode.classList.add("streaming");
  answerNode.textContent = "";
  streaming = true;
  let fullText = "";

  try {
    fullText = await askVisual(
      apiKey,
      {
        model: store.settings.model_id,
        question,
        evidence: [
          { page: region.page, jpeg: regionJPEG },
          { page: region.page, jpeg: pageJPEG },
        ],
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        answerNode.textContent = fullText;
      },
    );
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode, question);
    await saveQA(`${question}（框选区域）`, fullText);
  } catch (err) {
    answerNode.textContent = `出错了：${String(err)}`;
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
async function exportEvidence(pages: number[]): Promise<{ page: number; jpeg: string }[]> {
  const out: { page: number; jpeg: string }[] = [];
  for (const page of pages) {
    if (!currentDoc) continue;
    const jpeg = await currentDoc.exportPageAsJPEG(page);
    out.push({ page, jpeg });
  }
  return out;
}

// ---- 核心提问闭环 ----
async function askQuestion(question: string, selectionText: string | null) {
  if (!currentDoc || !apiKey) {
    openSettings(true);
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
  answerNode.textContent = "";
  streaming = true;
  let fullText = "";

  try {
    fullText = await askVisual(
      apiKey,
      {
        model: store.settings.model_id,
        question,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        answerNode.textContent = fullText;
      },
    );
    history.push({ role: "assistant", content: fullText });
    answerNode.classList.remove("streaming");
    appendActions(answerNode, question);
    await saveQA(question, fullText);
  } catch (err) {
    answerNode.textContent = `出错了：${String(err)}`;
    answerNode.classList.remove("streaming");
  } finally {
    streaming = false;
  }
}

// ---- 老师面板 ----
function openTeacherSheet(question: string) {
  teacherSheet.innerHTML = "";

  // 头部：拖拽条 + 关闭按钮。
  const header = document.createElement("div");
  header.className = "sheet-header";
  const grip = document.createElement("div");
  grip.className = "grip";
  grip.title = "收起";
  grip.addEventListener("click", () => teacherSheet.classList.remove("open"));
  const close = document.createElement("button");
  close.className = "sheet-close";
  close.textContent = "收起";
  close.addEventListener("click", () => teacherSheet.classList.remove("open"));
  header.append(grip, close);
  teacherSheet.appendChild(header);

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
  teacherSheet.classList.add("open");

  // 追问输入框
  const composer = document.createElement("div");
  composer.className = "composer";
  const input = document.createElement("input");
  input.placeholder = "还不懂？再问一句…";
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !streaming) {
      const text = input.value.trim();
      if (text) {
        input.value = "";
        void followUp(text);
      }
    }
  });
  const send = document.createElement("button");
  send.textContent = "发送";
  send.addEventListener("click", () => {
    const text = input.value.trim();
    if (text && !streaming) {
      input.value = "";
      void followUp(text);
    }
  });
  composer.append(input, send);
  teacherSheet.append(composer);

  void input.focus();
}

function appendActions(answerNode: HTMLDivElement, lastQuestion: string) {
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
      void askFollowUp(b.prompt);
    });
    actions.appendChild(btn);
  }
  answerNode.appendChild(actions);
}

async function followUp(text: string) {
  if (!currentDoc || !apiKey || streaming) return;
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
  a.textContent = "";
  scroll.appendChild(a);
  scroll.scrollTop = scroll.scrollHeight;
  streaming = true;

  let fullText = "";
  try {
    fullText = await askVisual(
      apiKey,
      {
        model: store.settings.model_id,
        question: text,
        evidence,
        history: history.slice(-6, -1),
      },
      (chunk) => {
        fullText += chunk;
        a.textContent = fullText;
        scroll.scrollTop = scroll.scrollHeight;
      },
    );
    history.push({ role: "assistant", content: fullText });
    a.classList.remove("streaming");
    appendActions(a, text);
    await saveQA(text, fullText);
  } catch (err) {
    a.textContent = `出错了：${String(err)}`;
    a.classList.remove("streaming");
  } finally {
    streaming = false;
  }
}

async function askFollowUp(prompt: string) {
  await followUp(prompt);
}

// ---- 持久化 ----
async function persist() {
  await saveStore(store).catch(() => undefined);
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
  await persist();
}

// ---- 框选交互：拖拽画框，松开发问。文字版与扫描版都可用 ----
function setupReaderSurface() {
  // 选框浮层。
  regionOverlay = document.createElement("div");
  regionOverlay.id = "region-overlay";
  readerSurface.appendChild(regionOverlay);

  readerSurface.addEventListener("mousedown", (e) => {
    if (streaming) return;
    if (e.button !== 0) return;
    // 点击阅读栏/抽屉/面板时不触发框选。
    const target = e.target as HTMLElement;
    if (target.closest("#toc-drawer") || target.closest("#teacher-sheet")) return;
    // 只有按下在页面元素上才开始框选。
    if (!target.closest(".scroll-page")) return;

    regionActive = true;
    regionStart = { x: e.clientX, y: e.clientY };
    selectionCapsule.style.display = "none";
    e.preventDefault();
  });

  window.addEventListener("mousemove", (e) => {
    if (!regionActive || !regionStart || !regionOverlay) return;
    const x = Math.min(regionStart.x, e.clientX);
    const y = Math.min(regionStart.y, e.clientY);
    const w = Math.abs(e.clientX - regionStart.x);
    const h = Math.abs(e.clientY - regionStart.y);
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

// ---- 悬浮「问」按钮：点一下问当前页 ----
function setupAskFab() {
  const fab = document.getElementById("ask-fab") as HTMLButtonElement;
  fab.addEventListener("click", () => {
    if (teacherSheet.classList.contains("open")) {
      teacherSheet.classList.remove("open");
      return;
    }
    void askPageQuestion();
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
    teacherSheet.style.left = `${Math.max(8, e.clientX - offsetX)}px`;
    teacherSheet.style.top = `${Math.max(8, e.clientY - offsetY)}px`;
  });

  window.addEventListener("mouseup", () => {
    dragging = false;
  });
}

// ---- 键盘 ----
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    teacherSheet.classList.remove("open");
    tocDrawer.classList.remove("open");
    selectionCapsule.style.display = "none";
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
  if (!e.metaKey && (e.key === "ArrowRight" || e.key === "PageDown")) {
    if (reader && currentPage < currentDoc!.pageCount) {
      reader.scrollToPage(currentPage + 1);
      void reader.onScroll();
    }
  }
  if (!e.metaKey && (e.key === "ArrowLeft" || e.key === "PageUp")) {
    if (reader && currentPage > 1) {
      reader.scrollToPage(currentPage - 1);
      void reader.onScroll();
    }
  }
});

async function applyZoom() {
  if (!reader) return;
  await reader.setZoom(zoomFactor);
  updateBottomBarZoom();
}

// ---- 底部工具栏（macOS 原生阅读器风格） ----

const THUMB_COUNT = 13; // 当前页前后各渲染多少缩略图
const THUMB_WIDTH = 34;

/// 缩略图缓存：page -> 已渲染的 DOM 元素（打开书时一次性渲染，滚动不重建）。
let thumbElements = new Map<number, HTMLElement>();
let thumbBarEl: HTMLElement | null = null;
let thumbHighlightEl: HTMLElement | null = null;

function renderBottomBar() {
  bottomBar.innerHTML = "";
  thumbElements = new Map();
  thumbBarEl = null;
  thumbHighlightEl = null;

  // 上一页 / 下一页
  const prev = document.createElement("button");
  prev.className = "nav-btn";
  prev.innerHTML = "‹";
  prev.title = "上一页";
  prev.addEventListener("click", () => {
    if (reader && currentPage > 1) {
      reader.scrollToPage(currentPage - 1);
      void reader.onScroll();
    }
  });
  const next = document.createElement("button");
  next.className = "nav-btn";
  next.innerHTML = "›";
  next.title = "下一页";
  next.addEventListener("click", () => {
    if (reader && currentPage < currentDoc!.pageCount) {
      reader.scrollToPage(currentPage + 1);
      void reader.onScroll();
    }
  });

  // 书：显示当前书名，点击弹出书列表（切换书）。
  const bookBtn = document.createElement("button");
  bookBtn.className = "action-btn book-btn";
  bookBtn.textContent = currentBook?.name ?? "书";
  bookBtn.title = "切换书";
  bookBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    toggleBookMenu();
  });

  // 回看（原顶部浮层的功能并入底部栏）。
  const reviewBtn = document.createElement("button");
  reviewBtn.className = "action-btn";
  reviewBtn.textContent = "回看";
  reviewBtn.title = "按页查看问过的问题";
  reviewBtn.addEventListener("click", () => {
    buildTOC();
    tocDrawer.classList.toggle("open");
  });

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
  thumbs.addEventListener("click", (e) => {
    const t = (e.target as HTMLElement).closest(".thumb") as HTMLElement | null;
    if (!t || !reader) return;
    const page = Number(t.dataset.page);
    if (page) {
      reader.scrollToPage(page);
      void reader.onScroll();
    }
  });

  // 高亮框：绝对定位在当前缩略图上，滚动时只移动它，不重建任何 DOM。
  const highlight = document.createElement("div");
  highlight.className = "thumb-highlight";
  thumbs.appendChild(highlight);
  thumbHighlightEl = highlight;

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

  bottomBar.append(bookBtn, prev, next, reviewBtn, pageNum, thumbs, zoomGroup);
  updateBottomBarZoom();

  // 打开书时一次性渲染全部缩略图（缓存），滚动时只更新高亮。
  void renderAllThumbnails();
}

function updateBottomBarZoom() {
  const pct = bottomBar.querySelector(".zoom-pct") as HTMLElement | null;
  if (pct) pct.textContent = `${Math.round(zoomFactor * 100)}%`;
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
      item.append(name, info);
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

/// 滚动/翻页后：只更新页码 + 移动高亮框 + 让当前缩略图可见。不重建 DOM。
function scheduleBottomBarUpdate() {
  if (!currentDoc || !thumbBarEl) return;
  const pageNum = bottomBar.querySelector(".page-num") as HTMLElement | null;
  if (pageNum) pageNum.textContent = `${currentPage} / ${currentDoc.pageCount}`;

  const active = thumbElements.get(currentPage);
  if (active && thumbBarEl) {
    const barRect = thumbBarEl.getBoundingClientRect();
    const thumbRect = active.getBoundingClientRect();
    // 高亮框跟随当前缩略图。
    if (thumbHighlightEl) {
      thumbHighlightEl.style.left = `${thumbRect.left - barRect.left}px`;
      thumbHighlightEl.style.top = `${thumbRect.top - barRect.top}px`;
      thumbHighlightEl.style.width = `${thumbRect.width}px`;
      thumbHighlightEl.style.height = `${thumbRect.height}px`;
      thumbHighlightEl.style.display = "block";
    }
    // 当前缩略图滚入视野（只横向滚动缩略图条本身，不碰页面滚动）。
    const barW = barRect.width;
    const thumbCenter = thumbRect.left - barRect.left + thumbRect.width / 2;
    const target = thumbBarEl.scrollLeft + (thumbCenter - barW / 2);
    thumbBarEl.scrollTo({ left: target, behavior: "smooth" });
  }
}

/// 一次性渲染当前页附近的缩略图并缓存。滚动时不调用。
async function renderAllThumbnails() {
  if (!currentDoc || !thumbBarEl) return;
  const start = Math.max(1, currentPage - THUMB_COUNT);
  const end = Math.min(currentDoc.pageCount, currentPage + THUMB_COUNT);

  const jobs: Promise<void>[] = [];
  for (let p = start; p <= end; p++) {
    jobs.push(renderThumb(p));
  }
  await Promise.all(jobs);
  scheduleBottomBarUpdate();
}

async function renderThumb(page: number): Promise<void> {
  if (!currentDoc || !thumbBarEl) return;
  if (thumbElements.has(page)) return;

  const thumb = document.createElement("div");
  thumb.className = "thumb";
  thumb.dataset.page = String(page);
  thumb.title = `第 ${page} 页`;
  thumbBarEl.appendChild(thumb);
  thumbElements.set(page, thumb);

  try {
    const size = await currentDoc.pageSize(page);
    const h = Math.round((size.height / size.width) * THUMB_WIDTH);
    const canvas = await currentDoc.renderPageToCanvas(page, THUMB_WIDTH / size.width);
    canvas.style.width = `${THUMB_WIDTH}px`;
    canvas.style.height = `${h}px`;
    thumb.appendChild(canvas);
  } catch {
    // 缩略图渲染失败不阻塞阅读。
  }
}

function persistReadingPosition() {
  if (!currentBook) return;
  currentBook.last_page = currentPage;
  store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
  void persist();
}

/// 滚动触发时防抖保存阅读位置。
let persistTimer: number | undefined;
function schedulePersistPosition() {
  window.clearTimeout(persistTimer);
  persistTimer = window.setTimeout(persistReadingPosition, 800);
}

// ---- 设置 ----
function openSettings(force: boolean = false) {
  const modal = document.createElement("div");
  modal.id = "settings-modal";
  modal.className = "open";
  modal.innerHTML = `
    <div class="card">
      <h2>连接老师</h2>
      <label>百炼 API Key（优先存钥匙串；测试可用下方「开发模式」存本地文件）</label>
      <input type="password" placeholder="sk-…" value="${apiKey ?? ""}" />
      <label>模型</label>
      <select></select>
      <div class="status"></div>
      <div class="row">
        <button class="cancel">关闭</button>
        <button class="dev">存为开发 Key</button>
        <button class="primary save">保存到钥匙串</button>
      </div>
    </div>`;

  const select = modal.querySelector("select")!;
  void listModelOptions().then((options: ModelOption[]) => {
    for (const opt of options) {
      const el = document.createElement("option");
      el.value = opt.id;
      el.textContent = opt.title;
      if (opt.id === store.settings.model_id) el.selected = true;
      select.appendChild(el);
    }
  });

  const statusEl = modal.querySelector(".status")!;
  if (apiKey) {
    statusEl.textContent = "已连接百炼（Key 可用）。";
  } else {
    statusEl.textContent = "还没有 Key——填上它，老师才能开口。";
  }

  modal.querySelector(".cancel")!.addEventListener("click", () => modal.remove());

  async function applyKey(key: string, save: () => Promise<void>, done: string) {
    if (!key) {
      statusEl.textContent = "Key 不能为空。";
      return;
    }
    try {
      await save();
      apiKey = key;
      store.settings.model_id = select.value;
      await persist();
      statusEl.textContent = done;
      window.setTimeout(() => modal.remove(), 700);
    } catch (err) {
      statusEl.textContent = `保存失败：${String(err)}`;
    }
  }

  modal.querySelector(".save")!.addEventListener("click", async () => {
    const keyInput = modal.querySelector('input[type="password"]') as HTMLInputElement;
    await applyKey(keyInput.value.trim(), () => saveApiKey(keyInput.value.trim()), "已保存到钥匙串。");
  });

  modal.querySelector(".dev")!.addEventListener("click", async () => {
    const keyInput = modal.querySelector('input[type="password"]') as HTMLInputElement;
    await applyKey(keyInput.value.trim(), () => saveDevKey(keyInput.value.trim()), "已存为开发 Key（本地文件，仅测试用）。");
  });

  modal.addEventListener("click", (e) => {
    if (e.target === modal) modal.remove();
  });
  document.body.appendChild(modal);
}

// ---- 启动 ----
void boot();
