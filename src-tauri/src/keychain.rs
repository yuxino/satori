//! API Key 只进 macOS Keychain。新 App 使用自己的 service 名；
//! 首次启动尝试从旧版 Satori 的钥匙串条目迁移，避免用户重新粘贴。

use keyring::{Entry, Error as KeyringError};

/// 新 App 的钥匙串条目（service 名独立于旧版，避免 ACL 冲突）。
const KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v3";
const KEYCHAIN_ACCOUNT: &str = "qwen-api-key";

/// 旧版 Swift App 的钥匙串条目，用于一次性迁移。
const LEGACY_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v2";
const LEGACY_KEYCHAIN_ACCOUNT: &str = "qwen-api-key";

#[tauri::command]
pub fn read_api_key() -> Result<Option<String>, String> {
    // 1) 新条目存在则直接返回。
    if let Some(key) = read_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)? {
        return Ok(Some(key));
    }
    // 2) 尝试从旧版条目迁移。
    if let Some(legacy) = read_entry(LEGACY_KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_ACCOUNT)? {
        if write_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, &legacy).is_ok() {
            return Ok(Some(legacy));
        }
    }
    Ok(None)
}

#[tauri::command]
pub fn save_api_key(api_key: String) -> Result<(), String> {
    let normalized = api_key.trim().to_string();
    if normalized.is_empty() {
        return Err("请输入百炼 API Key。".to_string());
    }
    write_entry(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, &normalized)
}

#[tauri::command]
pub fn clear_api_key() -> Result<(), String> {
    match Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT) {
        Ok(entry) => {
            entry
                .delete_credential()
                .map_err(|e| format!("无法删除钥匙串条目：{e}"))?;
            Ok(())
        }
        Err(e) => Err(format!("无法访问钥匙串：{e}")),
    }
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
