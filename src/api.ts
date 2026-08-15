// 与 Rust 后端交互的封装：命令调用 + 流式事件。
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface BookRecord {
  id: string;
  name: string;
  path: string;
  last_page: number;
  added_at: number;
}

export interface QAEntry {
  id: string;
  book_id: string;
  page: number;
  question: string;
  answer: string;
  ts: number;
}

export interface Settings {
  model_id: string;
  zoom: number;
}

export interface Store {
  books: BookRecord[];
  qa: QAEntry[];
  settings: Settings;
}

export interface ModelOption {
  id: string;
  title: string;
  explanation: string;
}

export interface HistoryTurn {
  role: "user" | "assistant";
  content: string;
}

export interface EvidencePage {
  page: number;
  jpeg: string;
}

export interface AskRequest {
  model: string;
  question: string;
  evidence: EvidencePage[];
  history: HistoryTurn[];
}

export function emptyStore(): Store {
  return { books: [], qa: [], settings: { model_id: "qwen3-vl-plus", zoom: 1 } };
}

// ---- Keychain ----

export function readApiKey(): Promise<string | null> {
  return invoke<string | null>("read_api_key");
}

export function saveApiKey(apiKey: string): Promise<void> {
  return invoke("save_api_key", { apiKey });
}

export function saveDevKey(apiKey: string): Promise<void> {
  return invoke("save_dev_key", { apiKey });
}

// ---- Store ----

export function loadStore(): Promise<Store> {
  return invoke<Store>("load_store");
}

export function saveStore(store: Store): Promise<void> {
  return invoke("save_store", { store });
}

export function resolveBookPath(book: BookRecord): Promise<BookRecord> {
  return invoke<BookRecord>("resolve_book_path", { book });
}

// ---- 缩略图磁盘缓存 ----

export function loadThumb(path: string, page: number): Promise<string | null> {
  return invoke<string | null>("load_thumb", { path, page });
}

export function saveThumb(path: string, page: number, jpegBase64: string): Promise<void> {
  return invoke("save_thumb", { path, page, jpegBase64 });
}

// ---- Qwen ----

export function listModelOptions(): Promise<ModelOption[]> {
  return invoke<ModelOption[]>("list_model_options");
}

export async function askVisual(apiKey: string, request: AskRequest, onChunk: (text: string) => void): Promise<string> {
  let fullText = "";
  const unlisten = await listen<string>("qwen://chunk", (event) => {
    fullText += event.payload;
    onChunk(event.payload);
  });
  try {
    // invoke 返回完整文本；chunk 事件用于流式展示。
    fullText = await invoke<string>("ask_visual", { apiKey, request });
  } finally {
    unlisten();
  }
  return fullText;
}
