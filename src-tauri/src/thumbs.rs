//! 缩略图磁盘缓存：渲染一次存盘，之后打开秒出（不再逐页解码）。
//! 按「文件路径 + 页码」存小 JPEG 到 Application Support/thumbs/。
//! 只做本地缓存，不含原始 PDF 内容之外的信息。

use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

fn thumbs_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let base = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("无法定位应用数据目录：{e}"))?;
    let dir = base.join("thumbs");
    fs::create_dir_all(&dir).map_err(|e| format!("创建缩略图目录失败：{e}"))?;
    Ok(dir)
}

/// 用文件路径生成稳定 key（hash 避免特殊字符路径问题）。
fn cache_key(path: &str, page: usize) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    format!("{:016x}-p{page}.jpg", hasher.finish())
}

/// 读缩略图缓存，命中返回 JPEG base64（不含 data: 前缀）。
#[tauri::command]
pub fn load_thumb(app: AppHandle, path: String, page: usize) -> Result<Option<String>, String> {
    let file = thumbs_dir(&app)?.join(cache_key(&path, page));
    if !file.exists() {
        return Ok(None);
    }
    let bytes = fs::read(&file).map_err(|e| format!("读取缩略图缓存失败：{e}"))?;
    Ok(Some(base64_encode(&bytes)))
}

/// 写入缩略图缓存（JPEG base64）。
#[tauri::command]
pub fn save_thumb(
    app: AppHandle,
    path: String,
    page: usize,
    jpeg_base64: String,
) -> Result<(), String> {
    let bytes = base64_decode(&jpeg_base64).map_err(|e| format!("解码缩略图失败：{e}"))?;
    let file = thumbs_dir(&app)?.join(cache_key(&path, page));
    fs::write(&file, &bytes).map_err(|e| format!("写入缩略图缓存失败：{e}"))
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn base64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s)
}
