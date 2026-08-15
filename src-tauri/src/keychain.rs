//! API Key 优先存 macOS Keychain；测试阶段提供本地开发文件兜底，
//! 避免每次启动都要跟钥匙串打交道。生产逻辑不受影响。

use keyring::{Entry, Error as KeyringError};
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// 新 App 的钥匙串条目（service 名独立于旧版，避免 ACL 冲突）。
const KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v3";
const KEYCHAIN_ACCOUNT: &str = "qwen-api-key";

/// 旧版 Swift App 的钥匙串条目，用于一次性迁移。
const LEGACY_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v2";
const LEGACY_KEYCHAIN_ACCOUNT: &str = "qwen-api-key";

/// 开发兜底文件：Application Support/satori/dev-api-key（纯文本，仅本地测试用）。
/// 不进项目、不进 Git；存在时在钥匙串之后兜底读取。
fn dev_key_file(app: &AppHandle) -> Result<PathBuf, String> {
    let base = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("无法定位应用数据目录：{e}"))?;
    Ok(base.join("satori").join("dev-api-key"))
}

#[tauri::command]
pub fn read_api_key(app: AppHandle) -> Result<Option<String>, String> {
    // 1) 开发文件优先：测试阶段有文件就直接用，完全不碰钥匙串，
    //    避免 keyring 在 release 环境下的任何报错/授权弹窗。
    if let Some(key) = read_dev_key(&app) {
        return Ok(Some(key));
    }
    // 2) 钥匙串读取失败绝不让命令报错（否则前端会弹设置），
    //    吞掉错误继续往下走。
    if let Ok(Some(key)) = read_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT) {
        return Ok(Some(key));
    }
    // 3) 尝试从旧版条目迁移。
    if let Ok(Some(legacy)) = read_entry(LEGACY_KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_ACCOUNT) {
        let _ = write_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, &legacy);
        return Ok(Some(legacy));
    }
    Ok(None)
}

fn read_dev_key(app: &AppHandle) -> Option<String> {
    let path = dev_key_file(app).ok()?;
    let raw = fs::read_to_string(path).ok()?;
    let key = raw.trim().to_string();
    if key.is_empty() { None } else { Some(key) }
}

#[tauri::command]
pub fn save_api_key(api_key: String) -> Result<(), String> {
    let normalized = api_key.trim().to_string();
    if normalized.is_empty() {
        return Err("请输入百炼 API Key。".to_string());
    }
    write_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, &normalized)
}

/// 写入开发兜底文件（测试用：跳过钥匙串）。
#[tauri::command]
pub fn save_dev_key(app: AppHandle, api_key: String) -> Result<(), String> {
    let normalized = api_key.trim().to_string();
    if normalized.is_empty() {
        return Err("Key 不能为空。".to_string());
    }
    let path = dev_key_file(&app)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("创建目录失败：{e}"))?;
    }
    fs::write(&path, &normalized).map_err(|e| format!("写入开发 Key 文件失败：{e}"))
}

fn read_entry(service: &str, account: &str) -> Result<Option<String>, String> {
    let entry = Entry::new(service, account).map_err(|e| format!("无法访问钥匙串：{e}"))?;
    match entry.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(e) => Err(format!("无法读取钥匙串条目：{e}")),
    }
}

fn write_entry(service: &str, account: &str, value: &str) -> Result<(), String> {
    let entry = Entry::new(service, account).map_err(|e| format!("无法访问钥匙串：{e}"))?;
    match entry.set_password(value) {
        Ok(()) => Ok(()),
        Err(KeyringError::NoEntry) => {
            // 条目不存在时直接创建。
            entry
                .set_password(value)
                .map_err(|e| format!("无法写入钥匙串：{e}"))
        }
        Err(e) => Err(format!("无法写入钥匙串：{e}")),
    }
}
