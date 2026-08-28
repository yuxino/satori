// 与 Rust 后端交互的封装：本地存储、AI 连接凭据与视觉请求。
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export interface BookRecord {
  id: string;
  name: string;
  path: string;
  last_page: number;
  added_at: number;
  outline: OutlineEntry[];
  /** 这本书自己的缩放倍数（1 = 适合窗口）；缺省从 1 开始。 */
  zoom?: number;
  /** 双页（书本展开）布局；缺省单页。 */
  spread?: boolean;
  /** 总页数（打开时记录，供总览页显示进度）。 */
  pageCount?: number;
}

/** 某一天的学习活动量（总览热力格子图用）。 */
interface DayActivity {
  pages: number;
  questions: number;
}

export interface OutlineEntry {
  title: string;
  page: number;
  depth: number;
}

export interface QAEntry {
  id: string;
  book_id: string;
  page: number;
  question: string;
  answer: string;
  ts: number;
}

export type AIProviderKind = "model_studio" | "open_ai" | "open_ai_compatible";

/** 非敏感的 AI 连接档案。API Key 永远不进入 Store。 */
export interface AIProfile {
  id: string;
  name: string;
  provider: AIProviderKind;
  base_url: string;
  model_id: string;
  api_key_required: boolean;
}

export interface Settings {
  active_profile_id: string;
  profiles: AIProfile[];
}

export interface Store {
  schema_version: number;
  books: BookRecord[];
  qa: QAEntry[];
  settings: Settings;
  /** 学习活动日志：日期 "YYYY-MM-DD" → 当天阅读页数/提问数。 */
  activity: Record<string, DayActivity>;
}

export interface CredentialStatus {
  saved: boolean;
}

export interface AppUpdateInfo {
  current_version: string;
  latest_version: string;
  available: boolean;
}

export interface HistoryTurn {
  role: "user" | "assistant";
  content: string;
}

interface EvidencePage {
  page: number;
  jpeg: string;
}

interface AskRequest {
  question: string;
  evidence: EvidencePage[];
  history: HistoryTurn[];
}

const DEFAULT_PROFILE_ID = "model-studio-default";

function defaultModelStudioProfile(): AIProfile {
  return {
    id: DEFAULT_PROFILE_ID,
    name: "阿里云百炼",
    provider: "model_studio",
    base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    model_id: "qwen3-vl-plus",
    api_key_required: true,
  };
}

export function emptyStore(): Store {
  return {
    schema_version: 1,
    books: [],
    qa: [],
    settings: {
      active_profile_id: DEFAULT_PROFILE_ID,
      profiles: [defaultModelStudioProfile()],
    },
    activity: {},
  };
}

// ---- AI 连接凭据（只返回状态，不读取 Key 明文） ----

export function credentialStatus(profileId: string): Promise<CredentialStatus> {
  return invoke<CredentialStatus>("credential_status", { profileId });
}

export function saveProfileApiKey(profileId: string, apiKey: string): Promise<void> {
  return invoke("save_profile_api_key", { profileId, apiKey });
}

export function deleteProfileApiKey(profileId: string): Promise<void> {
  return invoke("delete_profile_api_key", { profileId });
}

// ---- 应用版本 ----

export function checkForUpdate(): Promise<AppUpdateInfo> {
  return invoke<AppUpdateInfo>("check_for_update");
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

// ---- 视觉 AI ----

interface AIChunkEvent {
  request_id: string;
  text: string;
}

export async function askVisual(
  profileId: string,
  request: AskRequest,
  onChunk: (text: string) => void,
): Promise<string> {
  const requestId = crypto.randomUUID();
  let fullText = "";
  const unlisten = await listen<AIChunkEvent>("ai://chunk", (event) => {
    if (event.payload.request_id !== requestId) return;
    fullText += event.payload.text;
    onChunk(event.payload.text);
  });
  try {
    // invoke 返回完整文本；chunk 事件用于流式展示。
    fullText = await invoke<string>("ask_visual", { profileId, requestId, request });
  } finally {
    unlisten();
  }
  return fullText;
}

export function testAIProfile(profileId: string): Promise<string> {
  return invoke<string>("test_ai_profile", { profileId });
}

// ---- 扫描书目录恢复 ----

interface OutlineExtractRequest {
  pages: EvidencePage[];
}

export function extractOutline(profileId: string, request: OutlineExtractRequest): Promise<OutlineEntry[]> {
  return invoke<OutlineEntry[]>("extract_outline", { profileId, request });
}

export function findPageByTitle(
  profileId: string,
  title: string,
  pages: EvidencePage[],
): Promise<number> {
  return invoke<number>("find_page_by_title", { profileId, request: { title, pages } });
}
