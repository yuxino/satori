// Satori 3.0 主入口：一本书，旁边坐着一个老师。
import "./styles.css";
import { open } from "@tauri-apps/plugin-dialog";
import { convertFileSrc } from "@tauri-apps/api/core";
import {
  askVisual,
  clearApiKey,
  emptyStore,
  listModelOptions,
  loadStore,
  readApiKey,
  resolveBookPath,
  saveApiKey,
  saveStore,
  type BookRecord,
  type HistoryTurn,
  type ModelOption,
  type QAEntry,
  type Store,
} from "./api";
import { PDFDocument } from "./pdf";

// ---- DOM ----
const readerSurface = document.getElementById("reader-surface") as HTMLDivElement;
const readingBar = document.getElementById("reading-bar") as HTMLDivElement;
const teacherSheet = document.getElementById("teacher-sheet") as HTMLDivElement;
const tocDrawer = document.getElementById("toc-drawer") as HTMLDivElement;
const selectionCapsule = document.getElementById("selection-capsule") as HTMLButtonElement;

// ---- 状态 ----
let store: Store = emptyStore();
let apiKey: string | null = null;
let currentBook: BookRecord | null = null;
let currentDoc: PDFDocument | null = null;
let currentPage = 1;
let renderScale = 1.4;
let history: HistoryTurn[] = [];
let lastSelection: { text: string; page: number } | null = null;
let streaming = false;

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
}

// ---- 空书架 ----
function showEmptyState() {
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
  try {
    const resolved = await resolveBookPath(book);
    currentBook = resolved;
    const url = convertFileSrc(resolved.path);
    currentDoc = await PDFDocument.load(url);
    currentPage = Math.min(Math.max(resolved.last_page, 1), currentDoc.pageCount);
    readerSurface.innerHTML = "";
    await renderPage();
    showReopenCue(resolved);
    buildTOC();
    // 更新书籍列表（路径可能被修正）。
    store.books = store.books.map((b) => (b.id === resolved.id ? resolved : b));
    await persist();
  } catch (err) {
    readerSurface.innerHTML = `
      <div id="empty-state">
        <div class="hint">打不开这本书：${String(err)}</div>
        <button class="open-book">换一本</button>
      </div>`;
    readerSurface.querySelector(".open-book")!.addEventListener("click", () => void pickAndOpenBook());
  }
}

// ---- 渲染当前页 ----
async function renderPage() {
  if (!currentDoc) return;
  readerSurface.innerHTML = "";
  const canvas = await currentDoc.renderPageToCanvas(currentPage, renderScale);
  readerSurface.appendChild(canvas);
  updateReadingBar();
}

// ---- 阅读栏 ----
function updateReadingBar() {
  readingBar.innerHTML = "";
  const pageLabel = document.createElement("span");
  pageLabel.className = "page-label";
  pageLabel.textContent = `${currentPage} / ${currentDoc?.pageCount ?? 0}`;

  const chapterLabel = document.createElement("span");
  chapterLabel.className = "chapter-label";
  chapterLabel.textContent = currentChapterLabel() ?? "";

  const askButton = document.createElement("button");
  askButton.textContent = "问这一页";
  askButton.addEventListener("click", () => {
    hideReadingBarSoon();
    void askPageQuestion();
  });

  const tocButton = document.createElement("button");
  tocButton.textContent = "回看";
  tocButton.addEventListener("click", () => {
    buildTOC();
    tocDrawer.classList.toggle("open");
  });

  const settingsButton = document.createElement("button");
  settingsButton.textContent = "设置";
  settingsButton.addEventListener("click", () => openSettings());

  readingBar.append(pageLabel, chapterLabel, askButton, tocButton, settingsButton);
  readingBar.classList.add("visible");
  scheduleHideReadingBar();
}

let barHideTimer: number | undefined;
function scheduleHideReadingBar() {
  window.clearTimeout(barHideTimer);
  barHideTimer = window.setTimeout(() => readingBar.classList.remove("visible"), 2500);
}
function hideReadingBarSoon() {
  window.clearTimeout(barHideTimer);
  readingBar.classList.remove("visible");
}

function currentChapterLabel(): string | null {
  return null; // MVP：章节识别后续做，先只有页码。
}

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
    void renderPage();
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
  await renderPage();
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

// ---- 核心提问闭环 ----
async function askQuestion(question: string, selectionText: string | null) {
  if (!currentDoc || !apiKey) {
    openSettings(true);
    return;
  }
  if (streaming) return;

  // 页面图像即证据。
  const image = await currentDoc.exportPageAsJPEG(currentPage);
  history.push({ role: "user", content: question });
  lastSelection = selectionText ? { text: selectionText, page: currentPage } : null;

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
        image_base64: image,
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
  const image = await currentDoc.exportPageAsJPEG(currentPage);
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
        image_base64: image,
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

// ---- 选中胶囊 ----
function setupReaderSurface() {
  document.addEventListener("mouseup", () => {
    if (streaming) return;
    const sel = window.getSelection();
    const text = sel?.toString().trim();
    if (text && text.length > 0 && sel && !sel.isCollapsed) {
      const range = sel.getRangeAt(0);
      const rect = range.getBoundingClientRect();
      selectionCapsule.style.display = "block";
      selectionCapsule.style.left = `${rect.left}px`;
      selectionCapsule.style.top = `${Math.max(rect.bottom + 8, 40)}px`;
      lastSelection = { text, page: currentPage };
    } else {
      selectionCapsule.style.display = "none";
    }
  });
  selectionCapsule.addEventListener("click", () => {
    selectionCapsule.style.display = "none";
    if (lastSelection) void askSelectionQuestion(lastSelection);
  });
  // 翻页/点击时收起胶囊
  document.addEventListener("mousedown", (e) => {
    if (e.target !== selectionCapsule) selectionCapsule.style.display = "none";
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
  if (!e.metaKey && (e.key === "ArrowRight" || e.key === "PageDown")) {
    if (currentDoc && currentPage < currentDoc.pageCount) {
      currentPage += 1;
      persistReadingPosition();
      void renderPage();
    }
  }
  if (!e.metaKey && (e.key === "ArrowLeft" || e.key === "PageUp")) {
    if (currentPage > 1) {
      currentPage -= 1;
      persistReadingPosition();
      void renderPage();
    }
  }
});

function persistReadingPosition() {
  if (!currentBook) return;
  currentBook.last_page = currentPage;
  store.books = store.books.map((b) => (b.id === currentBook!.id ? currentBook! : b));
  void persist();
}

// ---- 设置 ----
function openSettings(force: boolean = false) {
  const modal = document.createElement("div");
  modal.id = "settings-modal";
  modal.className = "open";
  modal.innerHTML = `
    <div class="card">
      <h2>连接老师</h2>
      <label>百炼 API Key（只存本机钥匙串）</label>
      <input type="password" placeholder="sk-…" value="${apiKey ?? ""}" />
      <label>模型</label>
      <select></select>
      <div class="status"></div>
      <div class="row">
        <button class="cancel">关闭</button>
        <button class="primary save">保存</button>
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
    statusEl.textContent = "已连接百炼（Key 在钥匙串里）。";
  } else {
    statusEl.textContent = "还没有 Key——填上它，老师才能开口。";
  }

  modal.querySelector(".cancel")!.addEventListener("click", () => modal.remove());
  modal.querySelector(".save")!.addEventListener("click", async () => {
    const keyInput = modal.querySelector('input[type="password"]') as HTMLInputElement;
    const key = keyInput.value.trim();
    if (!key) {
      statusEl.textContent = "Key 不能为空。";
      return;
    }
    try {
      await saveApiKey(key);
      apiKey = key;
      store.settings.model_id = select.value;
      await persist();
      statusEl.textContent = "已保存。";
      window.setTimeout(() => modal.remove(), 600);
    } catch (err) {
      statusEl.textContent = `保存失败：${String(err)}`;
    }
  });
  modal.addEventListener("click", (e) => {
    if (e.target === modal) modal.remove();
  });
  document.body.appendChild(modal);
}

// ---- 启动 ----
void boot();
