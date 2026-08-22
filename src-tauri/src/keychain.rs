//! 每个 AI 配置使用独立的 macOS Keychain 条目。
//! 旧 Qwen 条目和开发明文文件只作为默认百炼配置的一次性迁移输入。

use crate::provider::resolve_profile;
use crate::store::{load_ai_profile, validate_profile_id, AIProfile, DEFAULT_PROFILE_ID};
use keyring::{Entry, Error as KeyringError};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use tauri::{AppHandle, Manager};

const PROFILE_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.ai.v1";
const CURRENT_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v3";
const LEGACY_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v2";
const LEGACY_QWEN_KEYCHAIN_ACCOUNT: &str = "qwen-api-key";
const MIGRATION_MARKER_DIRECTORY: &str = "credential-migrations";
const CREDENTIAL_ENVELOPE_VERSION: u8 = 1;
const DELETION_TOMBSTONE_VALUE: &str = "deleted-v1";

static CREDENTIAL_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Copy, Serialize)]
pub struct CredentialStatus {
    pub saved: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct CredentialEnvelope {
    version: u8,
    scope: String,
    secret: String,
}

enum StoredCredential {
    Bound(CredentialEnvelope),
    LegacyRaw(String),
    Malformed,
}

/// 同步读取供 AI 请求路径使用。Tauri UI 命令会在阻塞线程中调用它。
pub(crate) fn read_profile_api_key(
    app: &AppHandle,
    profile_id: &str,
    expected_scope: &str,
) -> Result<Option<String>, String> {
    let _guard = credential_guard()?;
    read_profile_api_key_unlocked(app, profile_id, expected_scope)
}

fn read_profile_api_key_unlocked(
    app: &AppHandle,
    profile_id: &str,
    expected_scope: &str,
) -> Result<Option<String>, String> {
    let account = profile_account(profile_id)?;

    if profile_id == DEFAULT_PROFILE_ID && deletion_tombstone_exists(profile_id)? {
        // A Keychain tombstone survives Application Support resets and closes
        // the cross-process race where a late legacy migration could otherwise
        // recreate a credential after an explicit delete.
        return Ok(None);
    }

    // Any current-service entry is authoritative. A mismatched or malformed
    // envelope must never fall through to legacy migration.
    if let Some(raw) = read_entry(PROFILE_KEYCHAIN_SERVICE, &account)? {
        return match decode_stored_credential(&raw) {
            StoredCredential::Bound(envelope) if envelope.scope == expected_scope => {
                if profile_id == DEFAULT_PROFILE_ID && !migration_marker_exists(app, profile_id)? {
                    // If a previous migration wrote the scoped entry but failed
                    // during plaintext cleanup, keep retrying until the marker
                    // proves the cleanup completed.
                    remove_legacy_dev_key_if_present(app)?;
                    write_migration_marker(app, profile_id)?;
                }
                Ok(Some(envelope.secret))
            }
            StoredCredential::Bound(_) => Ok(None),
            StoredCredential::LegacyRaw(secret)
                if profile_id == DEFAULT_PROFILE_ID
                    && expected_scope == default_profile_scope()?.as_str() =>
            {
                // The deterministic default profile always resolves to the
                // official Model Studio endpoint, so this one migration is safe.
                write_scoped_entry(&account, expected_scope, &secret)?;
                remove_legacy_dev_key_if_present(app)?;
                write_migration_marker(app, profile_id)?;
                Ok(Some(secret))
            }
            StoredCredential::LegacyRaw(_) => {
                Err("这个连接的旧凭据没有服务地址绑定，请重新保存 API Key。".to_string())
            }
            StoredCredential::Malformed => {
                Err("钥匙串中的 AI 凭据格式无效，请移除后重新保存。".to_string())
            }
        };
    }

    if profile_id != DEFAULT_PROFILE_ID || migration_marker_exists(app, profile_id)? {
        return Ok(None);
    }

    if expected_scope != default_profile_scope()? {
        // The deterministic ID alone is not enough: legacy Qwen secrets are
        // trusted only for the built-in official Model Studio scope.
        return Ok(None);
    }

    migrate_default_profile_key(app, &account, expected_scope)
}

fn default_profile_scope() -> Result<String, String> {
    Ok(resolve_profile(&AIProfile::default())?.credential_scope)
}

#[tauri::command]
pub async fn credential_status(
    app: AppHandle,
    profile_id: String,
) -> Result<CredentialStatus, String> {
    run_blocking(move || {
        validate_profile_id(&profile_id)?;
        let profile = load_ai_profile(&app, &profile_id)?;
        let scope = resolve_profile(&profile)?.credential_scope;
        read_profile_api_key(&app, &profile_id, &scope).map(|key| CredentialStatus {
            saved: key.is_some(),
        })
    })
    .await
}

#[tauri::command]
pub async fn save_profile_api_key(
    app: AppHandle,
    profile_id: String,
    api_key: String,
) -> Result<CredentialStatus, String> {
    run_blocking(move || {
        let _guard = credential_guard()?;
        let account = profile_account(&profile_id)?;
        let normalized = api_key.trim();
        if normalized.is_empty() {
            return Err("API Key 不能为空。".to_string());
        }
        let profile = load_ai_profile(&app, &profile_id)?;
        let scope = resolve_profile(&profile)?.credential_scope;

        write_scoped_entry(&account, &scope, normalized)?;
        if profile_id == DEFAULT_PROFILE_ID {
            delete_deletion_tombstone(&profile_id)?;
            remove_legacy_dev_key_if_present(&app)?;
            write_migration_marker(&app, &profile_id)?;
        }
        Ok(CredentialStatus { saved: true })
    })
    .await
}

#[tauri::command]
pub async fn delete_profile_api_key(
    app: AppHandle,
    profile_id: String,
) -> Result<CredentialStatus, String> {
    run_blocking(move || {
        let _guard = credential_guard()?;
        let account = profile_account(&profile_id)?;
        if profile_id == DEFAULT_PROFILE_ID {
            // 先落 marker 再删除；marker 失败时保留新 Key，避免下一次读取
            // 又从 qwen.v3/v2 或开发文件把用户删除的凭据恢复回来。
            write_deletion_tombstone(&profile_id)?;
            write_migration_marker(&app, &profile_id)?;
            remove_legacy_dev_key_if_present(&app)?;
            remove_legacy_keychain_entries()?;
        }
        delete_entry(PROFILE_KEYCHAIN_SERVICE, &account)?;
        Ok(CredentialStatus { saved: false })
    })
    .await
}

fn credential_guard() -> Result<MutexGuard<'static, ()>, String> {
    CREDENTIAL_LOCK
        .lock()
        .map_err(|_| "钥匙串操作锁已损坏，请重新启动 Satori。".to_string())
}

async fn run_blocking<T, F>(task: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(task)
        .await
        .map_err(|error| format!("钥匙串任务失败：{error}"))?
}

fn profile_account(profile_id: &str) -> Result<String, String> {
    validate_profile_id(profile_id)?;
    Ok(format!("profile:{profile_id}:api-key"))
}

fn deletion_tombstone_account(profile_id: &str) -> Result<String, String> {
    validate_profile_id(profile_id)?;
    Ok(format!("profile:{profile_id}:api-key-deleted"))
}

fn deletion_tombstone_exists(profile_id: &str) -> Result<bool, String> {
    let account = deletion_tombstone_account(profile_id)?;
    Ok(
        read_entry(PROFILE_KEYCHAIN_SERVICE, &account)?.as_deref()
            == Some(DELETION_TOMBSTONE_VALUE),
    )
}

fn write_deletion_tombstone(profile_id: &str) -> Result<(), String> {
    let account = deletion_tombstone_account(profile_id)?;
    write_entry(PROFILE_KEYCHAIN_SERVICE, &account, DELETION_TOMBSTONE_VALUE)?;
    if !deletion_tombstone_exists(profile_id)? {
        return Err("无法验证凭据删除标记。".to_string());
    }
    Ok(())
}

fn delete_deletion_tombstone(profile_id: &str) -> Result<(), String> {
    let account = deletion_tombstone_account(profile_id)?;
    delete_entry(PROFILE_KEYCHAIN_SERVICE, &account)
}

fn migration_marker_name(profile_id: &str) -> Result<String, String> {
    validate_profile_id(profile_id)?;
    Ok(format!("profile-{profile_id}-api-key-migration-v1.done"))
}

fn migration_marker_file(app: &AppHandle, profile_id: &str) -> Result<PathBuf, String> {
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("无法定位应用数据目录：{error}"))?
        .join(MIGRATION_MARKER_DIRECTORY);
    Ok(directory.join(migration_marker_name(profile_id)?))
}

fn legacy_dev_key_file(app: &AppHandle) -> Result<PathBuf, String> {
    let base = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("无法定位应用数据目录：{error}"))?;
    Ok(base.join("satori").join("dev-api-key"))
}

fn migration_marker_exists(app: &AppHandle, profile_id: &str) -> Result<bool, String> {
    let path = migration_marker_file(app, profile_id)?;
    match fs::metadata(path) {
        Ok(metadata) => Ok(metadata.is_file()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("无法读取凭据迁移标记：{error}")),
    }
}

fn write_migration_marker(app: &AppHandle, profile_id: &str) -> Result<(), String> {
    let path = migration_marker_file(app, profile_id)?;
    if let Some(directory) = path.parent() {
        fs::create_dir_all(directory).map_err(|error| format!("无法创建凭据迁移目录：{error}"))?;
    }
    fs::write(path, b"1\n").map_err(|error| format!("无法写入凭据迁移标记：{error}"))
}

enum LegacyCredential {
    Keychain(String),
    DevFile(String),
}

impl LegacyCredential {
    fn value(&self) -> &str {
        match self {
            Self::Keychain(value) | Self::DevFile(value) => value,
        }
    }
}

fn migrate_default_profile_key(
    app: &AppHandle,
    destination_account: &str,
    expected_scope: &str,
) -> Result<Option<String>, String> {
    let candidate = find_legacy_credential(app)?;
    let Some(candidate) = candidate else {
        // 没有旧凭据也完成这次探测，避免每次启动反复访问旧 Keychain。
        write_migration_marker(app, DEFAULT_PROFILE_ID)?;
        return Ok(None);
    };

    let value = candidate.value().to_string();
    // Re-check while holding the process-wide credential lock. This keeps a
    // concurrent delete from being followed by a late legacy migration write.
    if migration_marker_exists(app, DEFAULT_PROFILE_ID)? {
        return Ok(None);
    }
    write_scoped_entry(destination_account, expected_scope, &value)?;

    // Re-check the Keychain tombstone after writing. This closes the remaining
    // cross-process interleaving: delete may have started after the marker
    // check but before this write completed.
    if deletion_tombstone_exists(DEFAULT_PROFILE_ID)? {
        delete_entry(PROFILE_KEYCHAIN_SERVICE, destination_account)?;
        return Ok(None);
    }

    // A plaintext development fallback must never survive a successful
    // migration, even when a Keychain candidate had higher priority.
    remove_legacy_dev_key_if_present(app)?;
    write_migration_marker(app, DEFAULT_PROFILE_ID)?;
    Ok(Some(value))
}

fn find_legacy_credential(app: &AppHandle) -> Result<Option<LegacyCredential>, String> {
    if let Some(value) = read_entry(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)? {
        return Ok(Some(LegacyCredential::Keychain(value)));
    }
    if let Some(value) = read_entry(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)? {
        return Ok(Some(LegacyCredential::Keychain(value)));
    }
    read_legacy_dev_key(app).map(|value| value.map(LegacyCredential::DevFile))
}

fn read_legacy_dev_key(app: &AppHandle) -> Result<Option<String>, String> {
    let path = legacy_dev_key_file(app)?;
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("无法读取旧开发 Key 文件：{error}")),
    };
    let normalized = raw.trim().to_string();
    Ok((!normalized.is_empty()).then_some(normalized))
}

fn remove_legacy_dev_key_if_present(app: &AppHandle) -> Result<(), String> {
    let path = legacy_dev_key_file(app)?;
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除旧开发 Key 文件：{error}")),
    }
}

fn remove_legacy_keychain_entries() -> Result<(), String> {
    delete_entry(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?;
    delete_entry(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)
}

fn read_entry(service: &str, account: &str) -> Result<Option<String>, String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    match entry.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(error) => Err(format!("无法读取钥匙串条目：{error}")),
    }
}

fn decode_stored_credential(raw: &str) -> StoredCredential {
    match serde_json::from_str::<CredentialEnvelope>(raw) {
        Ok(envelope) if envelope.version == CREDENTIAL_ENVELOPE_VERSION => {
            StoredCredential::Bound(envelope)
        }
        Ok(_) => StoredCredential::Malformed,
        Err(_) if raw.trim_start().starts_with('{') => StoredCredential::Malformed,
        Err(_) => StoredCredential::LegacyRaw(raw.to_string()),
    }
}

fn write_scoped_entry(account: &str, scope: &str, secret: &str) -> Result<(), String> {
    let envelope = CredentialEnvelope {
        version: CREDENTIAL_ENVELOPE_VERSION,
        scope: scope.to_string(),
        secret: secret.to_string(),
    };
    let encoded =
        serde_json::to_string(&envelope).map_err(|error| format!("无法封装钥匙串凭据：{error}"))?;
    write_entry(PROFILE_KEYCHAIN_SERVICE, account, &encoded)?;

    let verified = read_entry(PROFILE_KEYCHAIN_SERVICE, account)?
        .ok_or_else(|| "钥匙串写入后无法读回凭据。".to_string())?;
    match decode_stored_credential(&verified) {
        StoredCredential::Bound(stored) if stored.scope == scope && stored.secret == secret => {
            Ok(())
        }
        _ => Err("钥匙串写入校验失败。".to_string()),
    }
}

fn write_entry(service: &str, account: &str, value: &str) -> Result<(), String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    entry
        .set_password(value)
        .map_err(|error| format!("无法写入钥匙串：{error}"))
}

fn delete_entry(service: &str, account: &str) -> Result<(), String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
        Err(error) => Err(format!("无法删除钥匙串条目：{error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_id_accepts_only_the_safe_ascii_set() {
        let max_length = "a".repeat(128);
        for valid in ["a", "model-studio-default", "openai.profile_1", &max_length] {
            assert!(
                validate_profile_id(valid).is_ok(),
                "expected valid ID: {valid}"
            );
        }

        let too_long = "a".repeat(129);
        for invalid in [
            "",
            "has space",
            "profile:key",
            "../profile",
            "模型",
            &too_long,
        ] {
            assert!(
                validate_profile_id(invalid).is_err(),
                "expected invalid ID: {invalid}"
            );
        }
    }

    #[test]
    fn profile_account_uses_stable_namespacing() {
        assert_eq!(
            profile_account(DEFAULT_PROFILE_ID).expect("default ID should be valid"),
            "profile:model-studio-default:api-key"
        );
        assert_eq!(
            deletion_tombstone_account(DEFAULT_PROFILE_ID).expect("default ID should be valid"),
            "profile:model-studio-default:api-key-deleted"
        );
    }

    #[test]
    fn migration_marker_name_is_profile_scoped_and_versioned() {
        assert_eq!(
            migration_marker_name(DEFAULT_PROFILE_ID).expect("default ID should be valid"),
            "profile-model-studio-default-api-key-migration-v1.done"
        );
    }

    #[test]
    fn credential_envelope_requires_matching_scope() {
        let encoded = serde_json::to_string(&CredentialEnvelope {
            version: CREDENTIAL_ENVELOPE_VERSION,
            scope:
                "v1\nprovider=open_ai\nurl=https://api.openai.com/v1/chat/completions\nauth=true"
                    .to_string(),
            secret: "test-secret".to_string(),
        })
        .unwrap();

        match decode_stored_credential(&encoded) {
            StoredCredential::Bound(envelope) => {
                assert_eq!(envelope.secret, "test-secret");
                assert!(envelope.scope.contains("api.openai.com"));
            }
            _ => panic!("expected a bound credential"),
        }
    }

    #[test]
    fn malformed_json_is_not_treated_as_a_legacy_secret() {
        assert!(matches!(
            decode_stored_credential("{not-an-envelope}"),
            StoredCredential::Malformed
        ));
        assert!(matches!(
            decode_stored_credential("legacy-plain-key"),
            StoredCredential::LegacyRaw(_)
        ));
    }
}
