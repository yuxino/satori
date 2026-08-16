//! 本地 JSON 持久化：书库、阅读位置、每页 Q&A 归档。
//! 全部保存在 Application Support，不上云。

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub model_id: String,
    /// 用户缩放倍数（1 = 适合宽度），跨会话记住。
    pub zoom: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            model_id: "qwen3-vl-plus".to_string(),
            zoom: 1.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Store {
    pub books: Vec<BookRecord>,
    pub qa: Vec<QAEntry>,
    pub settings: Settings,
}

impl Default for Store {
    fn default() -> Self {
        Self {
            books: Vec::new(),
            qa: Vec::new(),
            settings: Settings::default(),
        }
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
    match serde_json::from_str(&raw) {
        Ok(store) => Ok(store),
        Err(_) => {
            // 损坏时不静默覆盖，备份后返回默认。
            let backup = path.with_extension("corrupt.json");
            let _ = fs::copy(&path, &backup);
            Ok(Store::default())
        }
    }
}

#[tauri::command]
pub fn save_store(app: AppHandle, store: Store) -> Result<(), String> {
    let path = store_path(&app)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("创建数据目录失败：{e}"))?;
    }
    let raw = serde_json::to_string_pretty(&store).map_err(|e| format!("序列化失败：{e}"))?;
    fs::write(&path, raw).map_err(|e| format!("写入存储失败：{e}"))
}

/// 书文件可能被移动或改名：如果记录的路径不存在，尝试在常见位置
/// （原路径的父目录、用户文档目录、桌面）按文件名找回。
#[tauri::command]
pub fn resolve_book_path(book: BookRecord) -> Result<BookRecord, String> {
    let path = PathBuf::from(&book.path);
    if path.exists() {
        return Ok(book);
    }
    if let Some(name) = path.file_name() {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(parent) = path.parent() {
            candidates.push(parent.join(name));
        }
        if let Ok(home) = std::env::var("HOME") {
            candidates.push(PathBuf::from(&home).join("Desktop").join(name));
            candidates.push(PathBuf::from(&home).join("Documents").join(name));
            candidates.push(PathBuf::from(&home).join("Downloads").join(name));
        }
        // 也试试当前工作目录（开发时书常放在项目附近）。
        if let Ok(cwd) = std::env::current_dir() {
            candidates.push(cwd.join(name));
        }
        for candidate in candidates {
            if candidate.exists() {
                let mut fixed = book.clone();
                fixed.path = candidate.to_string_lossy().to_string();
                return Ok(fixed);
            }
        }
    }
    Err(format!("找不到书文件：{}", book.path))
}
