//! 本地 JSON 持久化：书库、阅读位置、每页 Q&A 归档。
//! 全部保存在 Application Support，不上云。

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

const STORE_SCHEMA_VERSION: u32 = 1;
pub const DEFAULT_PROFILE_ID: &str = "model-studio-default";
const MODEL_STUDIO_BASE_URL: &str = "https://dashscope.aliyuncs.com/compatible-mode/v1";
const DEFAULT_MODEL_ID: &str = "qwen3-vl-plus";

static STORE_WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BookRecord {
    pub id: String,
    pub name: String,
    pub path: String,
    pub last_page: usize,
    pub added_at: u64,
    /// 目录（含扫描书恢复的），空 = 尚无。持久化，打开秒显示。
    pub outline: Vec<OutlineEntry>,
    /// 这本书自己的缩放倍数（1 = 适合宽度）。None = 用全局默认。
    pub zoom: Option<f64>,
    /// 双页（书本展开）布局。false = 单页连续滚动。
    pub spread: bool,
    /// 总页数（打开时记录，供总览页显示进度）。None = 尚未打开过。
    #[serde(rename = "pageCount", alias = "page_count")]
    pub page_count: Option<usize>,
}

/// 某一天的学习活动量（总览热力格子图用）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DayActivity {
    pub pages: u64,
    pub questions: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct OutlineEntry {
    pub title: String,
    pub page: usize,
    pub depth: usize,
}

impl Default for OutlineEntry {
    fn default() -> Self {
        Self {
            title: String::new(),
            page: 1,
            depth: 0,
        }
    }
}

impl Default for BookRecord {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            path: String::new(),
            last_page: 1,
            added_at: 0,
            outline: Vec::new(),
            zoom: None,
            spread: false,
            page_count: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct QAEntry {
    pub id: String,
    pub book_id: String,
    pub page: usize,
    pub question: String,
    pub answer: String,
    pub ts: u64,
}

impl Default for QAEntry {
    fn default() -> Self {
        Self {
            id: String::new(),
            book_id: String::new(),
            page: 1,
            question: String::new(),
            answer: String::new(),
            ts: 0,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AIProviderKind {
    #[default]
    ModelStudio,
    OpenAi,
    OpenAiCompatible,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AIProfile {
    pub id: String,
    pub name: String,
    pub provider: AIProviderKind,
    pub base_url: String,
    pub model_id: String,
    pub api_key_required: bool,
}

impl Default for AIProfile {
    fn default() -> Self {
        Self {
            id: DEFAULT_PROFILE_ID.to_string(),
            name: "阿里云百炼".to_string(),
            provider: AIProviderKind::ModelStudio,
            base_url: MODEL_STUDIO_BASE_URL.to_string(),
            model_id: DEFAULT_MODEL_ID.to_string(),
            api_key_required: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub active_profile_id: String,
    pub profiles: Vec<AIProfile>,
    /// Satori 3.0 单模型设置的迁移入口。只读取旧 JSON，永不再次写回。
    #[serde(default, rename = "model_id", skip_serializing)]
    legacy_model_id: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            active_profile_id: DEFAULT_PROFILE_ID.to_string(),
            profiles: vec![AIProfile::default()],
            legacy_model_id: None,
        }
    }
}

impl Settings {
    fn normalize(&mut self) -> Result<(), String> {
        let legacy_model = self
            .legacy_model_id
            .take()
            .map(|model| model.trim().to_string())
            .filter(|model| !model.is_empty());

        if self.profiles.is_empty() {
            let mut profile = AIProfile::default();
            if let Some(model) = legacy_model.as_ref() {
                profile.model_id.clone_from(model);
            }
            self.profiles.push(profile);
            self.active_profile_id = DEFAULT_PROFILE_ID.to_string();
        } else if let Some(model) = legacy_model {
            // `#[serde(default)]` may have supplied the default profile while
            // deserializing a legacy object that only contained `model_id`.
            // Apply the legacy choice only to that deterministic default and
            // never overwrite a real multi-profile configuration.
            if self.profiles.len() == 1 && self.profiles[0].id == DEFAULT_PROFILE_ID {
                self.profiles[0].model_id = model;
            }
        }

        if !self
            .profiles
            .iter()
            .any(|profile| profile.id == self.active_profile_id)
        {
            return Err(format!(
                "当前使用的 AI 连接不存在：{}",
                self.active_profile_id
            ));
        }
        Ok(())
    }
}

pub(crate) fn validate_profile_id(profile_id: &str) -> Result<(), String> {
    if profile_id.is_empty() || profile_id.len() > 128 {
        return Err("配置 ID 长度必须为 1 到 128 个 ASCII 字符。".to_string());
    }
    if !profile_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("配置 ID 只能包含 ASCII 字母、数字、点、下划线和连字符。".to_string());
    }
    Ok(())
}

fn validate_profiles(profiles: &[AIProfile]) -> Result<(), String> {
    let mut ids = std::collections::HashSet::with_capacity(profiles.len());
    if profiles.is_empty() {
        return Err("至少需要一个 AI 连接。".to_string());
    }
    for profile in profiles {
        validate_profile_id(&profile.id)?;
        if !ids.insert(profile.id.as_str()) {
            return Err(format!("AI 连接 ID 重复：{}", profile.id));
        }
    }
    Ok(())
}

fn validate_store_structure(store: &Store) -> Result<(), String> {
    if store.schema_version > STORE_SCHEMA_VERSION {
        return Err(format!(
            "本地数据格式版本 {} 高于当前支持的版本 {}，请升级 Satori 后再保存。",
            store.schema_version, STORE_SCHEMA_VERSION
        ));
    }
    validate_profiles(&store.settings.profiles)?;
    if !store
        .settings
        .profiles
        .iter()
        .any(|profile| profile.id == store.settings.active_profile_id)
    {
        return Err("当前使用的 AI 连接不存在。".to_string());
    }
    Ok(())
}

fn validate_store_for_save(store: &Store) -> Result<(), String> {
    validate_store_structure(store)?;
    for profile in &store.settings.profiles {
        crate::provider::validate_profile_for_storage(profile)?;
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Store {
    pub schema_version: u32,
    pub books: Vec<BookRecord>,
    pub qa: Vec<QAEntry>,
    pub settings: Settings,
    /// 学习活动日志：日期 "YYYY-MM-DD" → 当天阅读页数/提问数。
    pub activity: std::collections::HashMap<String, DayActivity>,
}

impl Default for Store {
    fn default() -> Self {
        Self {
            schema_version: STORE_SCHEMA_VERSION,
            books: Vec::new(),
            qa: Vec::new(),
            settings: Settings::default(),
            activity: std::collections::HashMap::new(),
        }
    }
}

impl Store {
    fn normalize(&mut self) -> Result<(), String> {
        self.schema_version = self.schema_version.max(STORE_SCHEMA_VERSION);
        self.settings.normalize()
    }
}

fn store_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("无法定位应用数据目录：{e}"))?;
    Ok(dir.join("store.json"))
}

#[tauri::command]
pub fn load_store(app: AppHandle) -> Result<Store, String> {
    let path = store_path(&app)?;
    if !path.exists() {
        return Ok(Store::default());
    }
    let raw = fs::read_to_string(&path).map_err(|e| format!("读取存储失败：{e}"))?;
    match parse_store(&raw) {
        Ok(store) => Ok(store),
        Err(StoreParseError::Unsupported(version)) => Err(format!(
            "本地学习数据使用较新的格式版本 {version}；当前只支持版本 {STORE_SCHEMA_VERSION}。请升级 Satori，数据未被修改。"
        )),
        Err(StoreParseError::Invalid(error)) => {
            // 损坏时保留原文件和一份副本，并阻止默认数据覆盖它。
            let backup = path.with_extension("corrupt.json");
            let backup_note = match fs::copy(&path, &backup) {
                Ok(_) => format!("已另存备份：{}", backup.display()),
                Err(backup_error) => format!("备份也失败：{backup_error}"),
            };
            Err(format!(
                "本地学习数据无法读取，Satori 已停止加载以避免覆盖原数据：{error}。{backup_note}"
            ))
        }
    }
}

/// Resolve exactly one persisted AI profile. Request commands accept only an
/// ID from the WebView and use this trusted copy for endpoint and model data.
pub(crate) fn load_ai_profile(app: &AppHandle, profile_id: &str) -> Result<AIProfile, String> {
    validate_profile_id(profile_id)?;
    let store = load_store(app.clone())?;
    let mut matches = store
        .settings
        .profiles
        .into_iter()
        .filter(|profile| profile.id == profile_id);
    let profile = matches
        .next()
        .ok_or_else(|| format!("找不到 AI 连接：{profile_id}"))?;
    if matches.next().is_some() {
        return Err(format!("AI 连接 ID 重复，请先在设置中修复：{profile_id}"));
    }
    Ok(profile)
}

#[derive(Debug)]
enum StoreParseError {
    Invalid(String),
    Unsupported(u64),
}

impl std::fmt::Display for StoreParseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(error) => error.fmt(formatter),
            Self::Unsupported(version) => write!(formatter, "不支持的数据格式版本 {version}"),
        }
    }
}

fn parse_store(raw: &str) -> Result<Store, StoreParseError> {
    let value: Value =
        serde_json::from_str(raw).map_err(|error| StoreParseError::Invalid(error.to_string()))?;
    if let Some(version) = value.get("schema_version").and_then(Value::as_u64) {
        if version > u64::from(STORE_SCHEMA_VERSION) {
            return Err(StoreParseError::Unsupported(version));
        }
    }
    let mut store: Store = serde_json::from_value(value)
        .map_err(|error| StoreParseError::Invalid(error.to_string()))?;
    store.normalize().map_err(StoreParseError::Invalid)?;
    validate_store_structure(&store).map_err(StoreParseError::Invalid)?;
    Ok(store)
}

#[tauri::command]
pub fn save_store(app: AppHandle, mut store: Store) -> Result<(), String> {
    validate_store_for_save(&store)?;
    let path = store_path(&app)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("创建数据目录失败：{e}"))?;
    }
    store.normalize()?;
    let raw = serde_json::to_string_pretty(&store).map_err(|e| format!("序列化失败：{e}"))?;
    let _guard = STORE_WRITE_LOCK
        .lock()
        .map_err(|_| "本地存储写入锁已损坏，请重新启动 Satori。".to_string())?;
    write_store_atomically(&path, raw.as_bytes())
}

fn write_store_atomically(path: &std::path::Path, contents: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension("json.tmp");
    let result = (|| {
        let mut file =
            fs::File::create(&temporary).map_err(|e| format!("创建临时存储失败：{e}"))?;
        file.write_all(contents)
            .map_err(|e| format!("写入临时存储失败：{e}"))?;
        file.sync_all()
            .map_err(|e| format!("同步临时存储失败：{e}"))?;
        fs::rename(&temporary, path).map_err(|e| format!("替换存储失败：{e}"))
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// 已保存的书只能使用 Store 中记录的精确路径；文件移动后必须由用户
/// 再次通过原生文件选择器选择，不能按同名文件静默扩大读取范围。
fn resolve_persisted_book_path(book: BookRecord) -> Result<BookRecord, String> {
    let path = PathBuf::from(&book.path);
    if !path.exists() {
        return Err(format!(
            "找不到已保存的书文件：{}。请重新从本机选择这份 PDF。",
            book.path
        ));
    }
    Ok(book)
}

#[tauri::command]
pub fn resolve_book_path(book: BookRecord) -> Result<BookRecord, String> {
    resolve_persisted_book_path(book)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn legacy_store_json() -> String {
        json!({
            "books": [{
                "id": "book-1",
                "name": "Operating Systems",
                "path": "/tmp/os.pdf",
                "last_page": 17,
                "added_at": 42,
                "outline": [],
                "zoom": 1.25,
                "spread": true,
                "page_count": 320
            }],
            "qa": [{
                "id": "qa-1",
                "book_id": "book-1",
                "page": 17,
                "question": "什么是虚拟内存？",
                "answer": "一种地址空间抽象。",
                "ts": 99
            }],
            "settings": { "model_id": "qwen-vl-max" },
            "activity": { "2026-08-22": { "pages": 3, "questions": 1 } }
        })
        .to_string()
    }

    #[test]
    fn migrates_legacy_model_without_changing_learning_data() {
        let store = parse_store(&legacy_store_json()).expect("legacy store should migrate");

        assert_eq!(store.schema_version, STORE_SCHEMA_VERSION);
        assert_eq!(store.settings.active_profile_id, DEFAULT_PROFILE_ID);
        assert_eq!(store.settings.profiles.len(), 1);
        assert_eq!(store.settings.profiles[0].model_id, "qwen-vl-max");
        assert_eq!(store.books.len(), 1);
        assert_eq!(store.books[0].last_page, 17);
        assert_eq!(store.books[0].page_count, Some(320));
        assert_eq!(store.qa.len(), 1);
        assert_eq!(store.qa[0].answer, "一种地址空间抽象。");
        assert_eq!(store.activity["2026-08-22"].questions, 1);
    }

    #[test]
    fn migration_is_idempotent() {
        let migrated = parse_store(&legacy_store_json()).expect("first migration should work");
        let serialized = serde_json::to_string(&migrated).expect("migrated store should serialize");
        let migrated_again = parse_store(&serialized).expect("second migration should work");

        assert_eq!(migrated_again.settings.profiles.len(), 1);
        assert_eq!(migrated_again.settings.profiles[0].model_id, "qwen-vl-max");
        assert_eq!(
            migrated_again.settings.active_profile_id,
            DEFAULT_PROFILE_ID
        );
    }

    #[test]
    fn invalid_active_profile_is_rejected() {
        let mut settings = Settings {
            active_profile_id: "missing".to_string(),
            profiles: vec![
                AIProfile {
                    id: "custom".to_string(),
                    ..AIProfile::default()
                },
                AIProfile::default(),
            ],
            legacy_model_id: None,
        };

        assert!(settings
            .normalize()
            .unwrap_err()
            .contains("当前使用的 AI 连接不存在"));
    }

    #[test]
    fn legacy_model_is_deserialization_only() {
        let store = parse_store(&legacy_store_json()).expect("legacy store should migrate");
        let serialized = serde_json::to_value(store).expect("store should serialize");

        assert!(serialized["settings"].get("model_id").is_none());
        assert_eq!(
            serialized["settings"]["profiles"][0]["model_id"],
            "qwen-vl-max"
        );
    }

    #[test]
    fn page_count_accepts_both_spellings_and_serializes_as_camel_case() {
        let snake: BookRecord = serde_json::from_value(json!({ "page_count": 12 }))
            .expect("legacy page_count should deserialize");
        let camel: BookRecord = serde_json::from_value(json!({ "pageCount": 34 }))
            .expect("pageCount should deserialize");

        assert_eq!(snake.page_count, Some(12));
        assert_eq!(camel.page_count, Some(34));
        let serialized = serde_json::to_value(camel).expect("book should serialize");
        assert_eq!(serialized["pageCount"], 34);
        assert!(serialized.get("page_count").is_none());
    }

    #[test]
    fn save_validation_rejects_duplicate_or_unsafe_profile_ids() {
        let mut store = Store::default();
        store.settings.profiles.push(AIProfile::default());
        assert!(validate_store_for_save(&store)
            .unwrap_err()
            .contains("ID 重复"));

        store.settings.profiles = vec![AIProfile {
            id: "../unsafe".to_string(),
            ..AIProfile::default()
        }];
        store.settings.active_profile_id = "../unsafe".to_string();
        assert!(validate_store_for_save(&store)
            .unwrap_err()
            .contains("只能包含"));
    }

    #[test]
    fn newer_schema_is_read_only_to_this_version() {
        let store = Store {
            schema_version: STORE_SCHEMA_VERSION + 1,
            ..Store::default()
        };
        assert!(validate_store_for_save(&store)
            .unwrap_err()
            .contains("请升级 Satori"));

        let raw = serde_json::to_string(&store).unwrap();
        assert!(matches!(
            parse_store(&raw),
            Err(StoreParseError::Unsupported(version))
                if version == u64::from(STORE_SCHEMA_VERSION + 1)
        ));
    }

    #[test]
    fn unsafe_legacy_profile_metadata_loads_for_repair_but_cannot_be_saved() {
        let mut store = Store::default();
        store.settings.profiles = vec![AIProfile {
            id: "unsafe-profile".to_string(),
            name: "Unsafe profile".to_string(),
            provider: AIProviderKind::OpenAiCompatible,
            base_url: "https://user:secret@example.com/v1".to_string(),
            model_id: "vision-model".to_string(),
            api_key_required: true,
        }];
        store.settings.active_profile_id = "unsafe-profile".to_string();

        assert!(validate_store_for_save(&store).is_err());
        let raw = serde_json::to_string(&store).expect("fixture store should serialize");
        assert!(parse_store(&raw).is_ok());
    }

    #[test]
    fn missing_persisted_book_never_rebinds_to_a_same_named_pdf() {
        let saved = BookRecord {
            id: "saved-book".to_string(),
            name: "Saved book".to_string(),
            path: "/path/that/does/not/exist/satori-book.pdf".to_string(),
            ..BookRecord::default()
        };

        let error =
            resolve_persisted_book_path(saved).expect_err("a missing path must fail closed");
        assert!(error.contains("重新从本机选择"));
    }
}
