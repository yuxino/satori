//! 每个 AI 配置使用独立的系统安全凭据条目。
//! macOS 保持既有 Keychain 路径；Windows 使用 Credential Manager。
//! 旧 Qwen 条目和开发明文文件只作为默认百炼配置的一次性迁移输入。

use crate::provider::resolve_profile;
use crate::store::{load_ai_profile, validate_profile_id, AIProfile, DEFAULT_PROFILE_ID};
use fs2::FileExt;
#[cfg(target_os = "macos")]
use keyring::{Entry, Error as KeyringError};
#[cfg(target_os = "macos")]
use security_framework::item::{ItemClass, ItemSearchOptions};
#[cfg(target_os = "macos")]
use security_framework::os::macos::keychain::{SecKeychain, SecPreferencesDomain};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::AppHandle;
use zeroize::Zeroizing;

#[cfg(target_os = "windows")]
use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
#[cfg(target_os = "windows")]
use windows_sys::Win32::Security::Credentials::{
    CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_MAX_CREDENTIAL_BLOB_SIZE,
    CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
};

const PROFILE_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.ai.v1";
#[cfg(target_os = "macos")]
const CURRENT_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v3";
#[cfg(target_os = "macos")]
const LEGACY_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v2";
#[cfg(target_os = "macos")]
const LEGACY_QWEN_KEYCHAIN_ACCOUNT: &str = "qwen-api-key";
const MIGRATION_MARKER_DIRECTORY: &str = "credential-migrations";
const CREDENTIAL_SCOPE_DIRECTORY: &str = "credential-scopes";
const CREDENTIAL_SCOPE_MARKER_VERSION: u8 = 1;
const CREDENTIAL_ENVELOPE_VERSION: u8 = 2;
const LEGACY_CREDENTIAL_ENVELOPE_VERSION: u8 = 1;
const CREDENTIAL_LOCK_FILE: &str = "credential-operations-v1.lock";
const DELETION_TOMBSTONE_VALUE: &str = "deleted-v1";
#[cfg(target_os = "macos")]
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;
#[cfg(any(target_os = "windows", test))]
const WINDOWS_CREDENTIAL_TARGET_PREFIX: &str = "Satori";
#[cfg(any(target_os = "windows", test))]
const WINDOWS_CREDENTIAL_BLOB_MAX_BYTES: usize = 2560;

static CREDENTIAL_LOCK: Mutex<()> = Mutex::new(());
static CREDENTIAL_CACHE: LazyLock<Mutex<HashMap<String, CachedCredential>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CREDENTIAL_MARKER_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LegacyMigrationPolicy {
    MacOsKeychainAndDevFile,
    Disabled,
}

fn legacy_migration_policy_for(target_os: &str) -> LegacyMigrationPolicy {
    if target_os == "macos" {
        LegacyMigrationPolicy::MacOsKeychainAndDevFile
    } else {
        LegacyMigrationPolicy::Disabled
    }
}

fn legacy_migration_enabled() -> bool {
    legacy_migration_policy_for(std::env::consts::OS)
        == LegacyMigrationPolicy::MacOsKeychainAndDevFile
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct CredentialStatus {
    pub saved: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct CredentialEnvelope {
    version: u8,
    scope: String,
    #[serde(default)]
    generation: String,
    secret: String,
}

struct LoadedCredential {
    generation: String,
    secret: String,
}

struct CachedCredential {
    scope: String,
    generation: String,
    secret: Zeroizing<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CredentialScopeMarker {
    version: u8,
    scope: String,
    generation: String,
    #[serde(default)]
    pending: bool,
}

struct CredentialGuard {
    _process_guard: MutexGuard<'static, ()>,
    lock_file: File,
}

impl Drop for CredentialGuard {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.lock_file);
    }
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
    allow_interaction: bool,
) -> Result<Option<String>, String> {
    validate_profile_id(profile_id)?;
    let _guard = credential_guard(app)?;
    if let Some(secret) = cached_profile_api_key_if_current(app, profile_id, expected_scope)? {
        return Ok(Some(secret));
    }

    // Background work (for example scanned-outline recovery) must never cause
    // a surprise macOS authorization dialog. Explicit user actions such as
    // asking a question or testing a connection may request authorization.
    #[cfg(target_os = "macos")]
    let _interaction_lock = if allow_interaction {
        None
    } else {
        Some(
            SecKeychain::disable_user_interaction()
                .map_err(|error| format!("无法暂停钥匙串授权界面：{error}"))?,
        )
    };
    #[cfg(not(target_os = "macos"))]
    let _ = allow_interaction;

    let loaded = read_profile_api_key_unlocked(app, profile_id, expected_scope)?;
    let Some(loaded) = loaded else {
        return Ok(None);
    };

    // The generation is stored in both the Keychain envelope and a non-secret
    // sidecar. Holding the cross-process lock makes the envelope authoritative
    // after an interrupted save and prevents stale secrets from being cached
    // under a newer generation.
    match bind_credential_scope_marker(app, profile_id, expected_scope, &loaded.generation) {
        Ok(marker) => cache_profile_api_key(
            profile_id,
            expected_scope,
            &marker.generation,
            &loaded.secret,
        )?,
        Err(error) => {
            evict_cached_profile_api_key(profile_id)?;
            crate::debug_log(
                app,
                &format!("credential scope marker write failed: {error}"),
            );
        }
    }
    Ok(Some(loaded.secret))
}

fn read_profile_api_key_unlocked(
    app: &AppHandle,
    profile_id: &str,
    expected_scope: &str,
) -> Result<Option<LoadedCredential>, String> {
    let account = profile_account(profile_id)?;
    let tombstone_exists = deletion_tombstone_exists(profile_id)?;
    let current_entry_exists = entry_exists(PROFILE_KEYCHAIN_SERVICE, &account)?;
    let migration_complete = if profile_id == DEFAULT_PROFILE_ID {
        migration_marker_exists(app, profile_id)?
    } else {
        false
    };
    let uses_official_default_scope =
        profile_id == DEFAULT_PROFILE_ID && expected_scope == default_profile_scope()?;

    // The plaintext file is a migration source in exactly one state: the
    // default profile has no tombstone/current entry/marker and still targets
    // the official Model Studio scope. Everywhere else it is forbidden residue.
    if profile_id == DEFAULT_PROFILE_ID
        && legacy_migration_enabled()
        && (tombstone_exists
            || current_entry_exists
            || migration_complete
            || !uses_official_default_scope)
    {
        remove_legacy_dev_key_if_present(app)?;
    }

    if tombstone_exists {
        // A Keychain tombstone survives Application Support resets and closes
        // the cross-process race where a late legacy migration could otherwise
        // recreate a credential after an explicit delete.
        return Ok(None);
    }

    // Any current-service entry is authoritative. A mismatched or malformed
    // envelope must never fall through to legacy migration.
    if current_entry_exists {
        let Some(raw) = read_entry(PROFILE_KEYCHAIN_SERVICE, &account)? else {
            // Another, older process may have removed the entry without using
            // our lock. Never turn that race into a plaintext migration.
            return Ok(None);
        };
        return match decode_stored_credential(&raw) {
            StoredCredential::Bound(mut envelope) if envelope.scope == expected_scope => {
                if profile_id == DEFAULT_PROFILE_ID && legacy_migration_enabled() {
                    // Cleanup must remain idempotent even if an earlier build
                    // wrote the migration marker before plaintext deletion
                    // failed. A current scoped entry never justifies keeping it.
                    remove_legacy_dev_key_if_present(app)?;
                    if !migration_marker_exists(app, profile_id)? {
                        write_migration_marker(app, profile_id)?;
                    }
                }

                if envelope.generation.is_empty() {
                    let generation = next_credential_generation();
                    write_credential_scope_marker(
                        app,
                        profile_id,
                        expected_scope,
                        &generation,
                        true,
                    )?;
                    write_scoped_entry(&account, expected_scope, &generation, &envelope.secret)?;
                    envelope.generation = generation;
                }
                Ok(Some(LoadedCredential {
                    generation: envelope.generation,
                    secret: envelope.secret,
                }))
            }
            StoredCredential::Bound(_) => Ok(None),
            StoredCredential::LegacyRaw(secret)
                if profile_id == DEFAULT_PROFILE_ID
                    && legacy_migration_enabled()
                    && expected_scope == default_profile_scope()?.as_str() =>
            {
                // The deterministic default profile always resolves to the
                // official Model Studio endpoint, so this one migration is safe.
                let generation = next_credential_generation();
                write_credential_scope_marker(app, profile_id, expected_scope, &generation, true)?;
                write_scoped_entry(&account, expected_scope, &generation, &secret)?;
                remove_legacy_dev_key_if_present(app)?;
                write_migration_marker(app, profile_id)?;
                Ok(Some(LoadedCredential { generation, secret }))
            }
            StoredCredential::LegacyRaw(_) => {
                Err("这个连接的旧凭据没有服务地址绑定，请重新保存 API Key。".to_string())
            }
            StoredCredential::Malformed => {
                Err("系统安全凭据中的 AI 凭据格式无效，请移除后重新保存。".to_string())
            }
        };
    }

    if profile_id != DEFAULT_PROFILE_ID {
        return Ok(None);
    }

    if migration_complete {
        return Ok(None);
    }

    if !uses_official_default_scope {
        // The deterministic ID alone is not enough: legacy Qwen secrets are
        // trusted only for the built-in official Model Studio scope.
        return Ok(None);
    }

    #[cfg(target_os = "macos")]
    {
        migrate_default_profile_key(app, &account, expected_scope)
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Windows has no supported plaintext or old-Qwen source. Persist only
        // a non-secret probe marker so later reads do not inspect legacy paths.
        write_migration_marker(app, DEFAULT_PROFILE_ID)?;
        Ok(None)
    }
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
        if !profile.api_key_required {
            return Ok(CredentialStatus { saved: false });
        }
        let scope = resolve_profile(&profile)?.credential_scope;
        credential_saved_without_decryption(&app, &profile_id, &scope)
            .map(|saved| CredentialStatus { saved })
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
        let _guard = credential_guard(&app)?;
        let account = profile_account(&profile_id)?;
        let normalized = api_key.trim();
        if normalized.is_empty() {
            return Err("API Key 不能为空。".to_string());
        }
        let profile = load_ai_profile(&app, &profile_id)?;
        let scope = resolve_profile(&profile)?.credential_scope;

        let generation = next_credential_generation();
        write_credential_scope_marker(&app, &profile_id, &scope, &generation, true)?;
        write_scoped_entry(&account, &scope, &generation, normalized)?;
        delete_deletion_tombstone(&profile_id)?;
        if profile_id == DEFAULT_PROFILE_ID && legacy_migration_enabled() {
            remove_legacy_dev_key_if_present(&app)?;
            write_migration_marker(&app, &profile_id)?;
        }
        let marker = write_credential_scope_marker(&app, &profile_id, &scope, &generation, false)?;
        cache_profile_api_key(&profile_id, &scope, &marker.generation, normalized)?;
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
        let _guard = credential_guard(&app)?;
        let account = profile_account(&profile_id)?;
        // Deletion intent takes precedence over every later failure. Never let
        // a failed legacy cleanup leave a usable process-local copy behind.
        evict_cached_profile_api_key(&profile_id)?;
        write_deletion_tombstone(&profile_id)?;
        if profile_id == DEFAULT_PROFILE_ID && legacy_migration_enabled() {
            // 先落 marker 再删除；marker 失败时保留新 Key，避免下一次读取
            // 又从 qwen.v3/v2 或开发文件把用户删除的凭据恢复回来。
            write_migration_marker(&app, &profile_id)?;
            remove_legacy_dev_key_if_present(&app)?;
            remove_legacy_keychain_entries()?;
        }
        delete_entry(PROFILE_KEYCHAIN_SERVICE, &account)?;
        if let Err(error) = remove_credential_scope_marker(&app, &profile_id) {
            crate::debug_log(
                &app,
                &format!("credential scope marker removal failed: {error}"),
            );
        }
        Ok(CredentialStatus { saved: false })
    })
    .await
}

fn credential_guard(app: &AppHandle) -> Result<CredentialGuard, String> {
    let process_guard = CREDENTIAL_LOCK
        .lock()
        .map_err(|_| "凭据操作锁已损坏，请重新启动 Satori。".to_string())?;
    let app_data = crate::platform_paths::non_secret_data_dir(app)?;
    fs::create_dir_all(&app_data).map_err(|error| format!("无法创建应用数据目录：{error}"))?;
    let lock_file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(app_data.join(CREDENTIAL_LOCK_FILE))
        .map_err(|error| format!("无法打开凭据操作锁：{error}"))?;
    FileExt::lock_exclusive(&lock_file).map_err(|error| format!("无法锁定凭据操作：{error}"))?;
    Ok(CredentialGuard {
        _process_guard: process_guard,
        lock_file,
    })
}

fn credential_cache_guard() -> Result<MutexGuard<'static, HashMap<String, CachedCredential>>, String>
{
    CREDENTIAL_CACHE
        .lock()
        .map_err(|_| "凭据会话缓存已损坏，请重新启动 Satori。".to_string())
}

fn cached_profile_api_key(
    profile_id: &str,
    expected_scope: &str,
    expected_generation: &str,
) -> Result<Option<String>, String> {
    let mut cache = credential_cache_guard()?;
    let matches = cache.get(profile_id).is_some_and(|credential| {
        credential.scope == expected_scope && credential.generation == expected_generation
    });
    if matches {
        return Ok(cache
            .get(profile_id)
            .map(|credential| credential.secret.as_str().to_string()));
    }
    cache.remove(profile_id);
    Ok(None)
}

fn cached_profile_api_key_if_current(
    app: &AppHandle,
    profile_id: &str,
    expected_scope: &str,
) -> Result<Option<String>, String> {
    if deletion_tombstone_exists(profile_id)?
        || !entry_exists(PROFILE_KEYCHAIN_SERVICE, &profile_account(profile_id)?)?
    {
        evict_cached_profile_api_key(profile_id)?;
        return Ok(None);
    }

    let marker = match read_credential_scope_marker(app, profile_id) {
        Ok(Some(marker)) => marker,
        Ok(None) => {
            evict_cached_profile_api_key(profile_id)?;
            return Ok(None);
        }
        Err(error) => {
            // The sidecar contains no secret and is never authoritative. A
            // damaged/future marker forces a controlled Keychain read, which
            // can then repair it from the scoped envelope.
            crate::debug_log(app, &format!("credential scope marker ignored: {error}"));
            evict_cached_profile_api_key(profile_id)?;
            return Ok(None);
        }
    };
    if marker.pending || marker.scope != expected_scope {
        evict_cached_profile_api_key(profile_id)?;
        return Ok(None);
    }

    cached_profile_api_key(profile_id, expected_scope, &marker.generation)
}

fn cache_profile_api_key(
    profile_id: &str,
    scope: &str,
    generation: &str,
    secret: &str,
) -> Result<(), String> {
    credential_cache_guard()?.insert(
        profile_id.to_string(),
        CachedCredential {
            scope: scope.to_string(),
            generation: generation.to_string(),
            secret: Zeroizing::new(secret.to_string()),
        },
    );
    Ok(())
}

fn evict_cached_profile_api_key(profile_id: &str) -> Result<(), String> {
    credential_cache_guard()?.remove(profile_id);
    Ok(())
}

async fn run_blocking<T, F>(task: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(task)
        .await
        .map_err(|error| format!("系统凭据任务失败：{error}"))?
}

fn profile_account(profile_id: &str) -> Result<String, String> {
    validate_profile_id(profile_id)?;
    Ok(format!("profile:{profile_id}:api-key"))
}

fn credential_saved_without_decryption(
    app: &AppHandle,
    profile_id: &str,
    expected_scope: &str,
) -> Result<bool, String> {
    let account = profile_account(profile_id)?;
    let tombstone_exists = deletion_tombstone_exists(profile_id)?;
    let current_entry_exists = entry_exists(PROFILE_KEYCHAIN_SERVICE, &account)?;
    let migration_complete = if profile_id == DEFAULT_PROFILE_ID {
        migration_marker_exists(app, profile_id)?
    } else {
        false
    };
    let uses_official_default_scope =
        profile_id == DEFAULT_PROFILE_ID && expected_scope == default_profile_scope()?;

    if profile_id == DEFAULT_PROFILE_ID
        && legacy_migration_enabled()
        && (tombstone_exists
            || current_entry_exists
            || migration_complete
            || !uses_official_default_scope)
    {
        remove_legacy_dev_key_best_effort(app);
    }

    if tombstone_exists {
        return Ok(false);
    }

    match read_credential_scope_marker(app, profile_id) {
        Ok(Some(marker)) if marker.scope != expected_scope => return Ok(false),
        Ok(_) => {}
        Err(error) => {
            // Status queries must remain existence-only and must not make a
            // damaged non-secret sidecar hide an otherwise valid Keychain item.
            crate::debug_log(app, &format!("credential scope marker ignored: {error}"));
        }
    }

    if current_entry_exists {
        return Ok(true);
    }

    if profile_id != DEFAULT_PROFILE_ID || !uses_official_default_scope {
        return Ok(false);
    }

    if migration_complete {
        return Ok(false);
    }

    if !legacy_migration_enabled() {
        return Ok(false);
    }

    #[cfg(target_os = "macos")]
    {
        Ok(
            entry_exists(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?
                || entry_exists(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?
                || legacy_dev_key_file(app)?.is_file(),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(false)
    }
}

#[cfg(any(target_os = "windows", test))]
fn windows_credential_target(service: &str, account: &str) -> String {
    format!("{WINDOWS_CREDENTIAL_TARGET_PREFIX}/{service}/{account}")
}

#[cfg(target_os = "windows")]
fn windows_wide_string(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(any(target_os = "windows", test))]
fn encode_windows_credential_blob(value: &str) -> Result<Zeroizing<Vec<u16>>, String> {
    let encoded = Zeroizing::new(value.encode_utf16().collect::<Vec<_>>());
    let byte_length = encoded
        .len()
        .checked_mul(std::mem::size_of::<u16>())
        .ok_or_else(|| "系统凭据过大，无法安全保存。".to_string())?;
    if byte_length > WINDOWS_CREDENTIAL_BLOB_MAX_BYTES {
        return Err("系统凭据过大，无法安全保存。".to_string());
    }
    Ok(encoded)
}

#[cfg(any(target_os = "windows", test))]
fn decode_windows_credential_blob(blob: &[u8]) -> Result<String, String> {
    if blob.len() & 1 != 0 {
        return Err("Windows 凭据条目编码无效，请移除后重新保存。".to_string());
    }
    let mut encoded = Zeroizing::new(Vec::with_capacity(blob.len() / 2));
    for index in (0..blob.len()).step_by(2) {
        encoded.push(u16::from_le_bytes([blob[index], blob[index + 1]]));
    }
    String::from_utf16(&encoded)
        .map_err(|_| "Windows 凭据条目编码无效，请移除后重新保存。".to_string())
}

#[cfg(target_os = "windows")]
struct WindowsCredentialBuffer(*mut CREDENTIALW);

#[cfg(target_os = "windows")]
impl WindowsCredentialBuffer {
    fn credential(&self) -> &CREDENTIALW {
        // SAFETY: the constructor is used only after CredReadW succeeds with a
        // non-null pointer, and this allocation remains owned until Drop.
        unsafe { &*self.0 }
    }
}

#[cfg(target_os = "windows")]
impl Drop for WindowsCredentialBuffer {
    fn drop(&mut self) {
        // SAFETY: CredReadW owns this allocation. Windows documents the blob as
        // writable; erase it before releasing the complete allocation.
        unsafe {
            let credential = &mut *self.0;
            if !credential.CredentialBlob.is_null() && credential.CredentialBlobSize > 0 {
                std::ptr::write_bytes(
                    credential.CredentialBlob,
                    0,
                    credential.CredentialBlobSize as usize,
                );
            }
            CredFree(self.0.cast());
        }
    }
}

#[cfg(target_os = "windows")]
fn windows_api_error(action: &str, code: u32) -> String {
    let detail = std::io::Error::from_raw_os_error(code as i32);
    format!("{action}失败（Windows 错误 {code}：{detail}）。")
}

#[cfg(target_os = "windows")]
fn read_windows_credential(target: &str) -> Result<Option<WindowsCredentialBuffer>, String> {
    let target = windows_wide_string(target);
    let mut credential = std::ptr::null_mut();
    // SAFETY: target is NUL-terminated and credential points to writable output
    // storage. A successful allocation is released by WindowsCredentialBuffer.
    let result = unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) };
    if result == 0 {
        // SAFETY: GetLastError is called immediately after the failed Win32 API.
        let code = unsafe { GetLastError() };
        return if code == ERROR_NOT_FOUND {
            Ok(None)
        } else {
            Err(windows_api_error("读取系统凭据", code))
        };
    }
    if credential.is_null() {
        return Err("读取系统凭据失败：Windows 返回了空条目。".to_string());
    }
    Ok(Some(WindowsCredentialBuffer(credential)))
}

/// Match only the service/account identity and ask Security.framework to
/// return no attributes, reference or data. The OSStatus alone tells us
/// whether an item exists without evaluating its decrypt ACL.
#[cfg(target_os = "macos")]
fn entry_exists(service: &str, account: &str) -> Result<bool, String> {
    // keyring's apple-native backend stores in the User domain. Search the
    // exact same domain even if the user's generic default keychain differs.
    let keychain = SecKeychain::default_for_domain(SecPreferencesDomain::User)
        .map_err(|error| format!("无法访问用户钥匙串：{error}"))?;
    let keychains = [keychain];
    let mut search = ItemSearchOptions::new();
    match search
        .keychains(&keychains)
        .class(ItemClass::generic_password())
        .service(service)
        .account(account)
        .limit(1)
        .search()
    {
        Ok(_) => Ok(true),
        Err(error) if error.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(false),
        Err(error) => Err(format!("无法查询钥匙串条目状态：{error}")),
    }
}

#[cfg(target_os = "windows")]
fn entry_exists(service: &str, account: &str) -> Result<bool, String> {
    let target = windows_credential_target(service, account);
    read_windows_credential(&target).map(|credential| credential.is_some())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn entry_exists(_service: &str, _account: &str) -> Result<bool, String> {
    Err("当前平台不支持安全凭据存储。".to_string())
}

fn deletion_tombstone_account(profile_id: &str) -> Result<String, String> {
    validate_profile_id(profile_id)?;
    Ok(format!("profile:{profile_id}:api-key-deleted"))
}

fn deletion_tombstone_exists(profile_id: &str) -> Result<bool, String> {
    let account = deletion_tombstone_account(profile_id)?;
    entry_exists(PROFILE_KEYCHAIN_SERVICE, &account)
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
    let directory =
        crate::platform_paths::non_secret_data_dir(app)?.join(MIGRATION_MARKER_DIRECTORY);
    Ok(directory.join(migration_marker_name(profile_id)?))
}

fn credential_scope_marker_file(app: &AppHandle, profile_id: &str) -> Result<PathBuf, String> {
    validate_profile_id(profile_id)?;
    let directory =
        crate::platform_paths::non_secret_data_dir(app)?.join(CREDENTIAL_SCOPE_DIRECTORY);
    Ok(directory.join(format!("profile-{profile_id}-scope-v1")))
}

fn read_credential_scope_marker(
    app: &AppHandle,
    profile_id: &str,
) -> Result<Option<CredentialScopeMarker>, String> {
    let path = credential_scope_marker_file(app, profile_id)?;
    match fs::read_to_string(path) {
        Ok(raw) => match serde_json::from_str::<CredentialScopeMarker>(&raw) {
            Ok(marker) if marker.version == CREDENTIAL_SCOPE_MARKER_VERSION => Ok(Some(marker)),
            Ok(_) => Err("凭据范围标记版本不受支持。".to_string()),
            Err(_) if !raw.trim_start().starts_with('{') => Ok(Some(CredentialScopeMarker {
                // Upgrade markers written by the first multi-provider build.
                version: CREDENTIAL_SCOPE_MARKER_VERSION,
                scope: raw,
                generation: "legacy".to_string(),
                pending: false,
            })),
            Err(error) => Err(format!("凭据范围标记格式无效：{error}")),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取凭据范围标记：{error}")),
    }
}

fn write_credential_scope_marker(
    app: &AppHandle,
    profile_id: &str,
    scope: &str,
    generation: &str,
    pending: bool,
) -> Result<CredentialScopeMarker, String> {
    let path = credential_scope_marker_file(app, profile_id)?;
    if let Some(directory) = path.parent() {
        fs::create_dir_all(directory).map_err(|error| format!("无法创建凭据范围目录：{error}"))?;
    }
    let marker = CredentialScopeMarker {
        version: CREDENTIAL_SCOPE_MARKER_VERSION,
        scope: scope.to_string(),
        generation: generation.to_string(),
        pending,
    };
    let encoded =
        serde_json::to_vec(&marker).map_err(|error| format!("无法编码凭据范围标记：{error}"))?;
    let temporary = path.with_extension(format!("tmp-{}", marker.generation));
    crate::atomic_file::write_atomically(&path, &temporary, &encoded)
        .map_err(|error| format!("无法更新凭据范围标记：{error}"))?;
    Ok(marker)
}

fn bind_credential_scope_marker(
    app: &AppHandle,
    profile_id: &str,
    scope: &str,
    generation: &str,
) -> Result<CredentialScopeMarker, String> {
    match read_credential_scope_marker(app, profile_id) {
        Ok(Some(marker))
            if !marker.pending && marker.scope == scope && marker.generation == generation =>
        {
            Ok(marker)
        }
        Ok(_) => write_credential_scope_marker(app, profile_id, scope, generation, false),
        Err(error) => {
            crate::debug_log(
                app,
                &format!("credential scope marker repair required: {error}"),
            );
            write_credential_scope_marker(app, profile_id, scope, generation, false)
        }
    }
}

fn next_credential_generation() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = CREDENTIAL_MARKER_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{:x}-{timestamp:x}-{sequence:x}", std::process::id())
}

fn remove_credential_scope_marker(app: &AppHandle, profile_id: &str) -> Result<(), String> {
    let path = credential_scope_marker_file(app, profile_id)?;
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除凭据范围标记：{error}")),
    }
}

#[cfg(target_os = "macos")]
fn legacy_dev_key_file(app: &AppHandle) -> Result<PathBuf, String> {
    let base = crate::platform_paths::non_secret_data_dir(app)?;
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

#[cfg(target_os = "macos")]
enum LegacyCredential {
    Keychain(String),
    DevFile(String),
}

#[cfg(target_os = "macos")]
impl LegacyCredential {
    fn value(&self) -> &str {
        match self {
            Self::Keychain(value) | Self::DevFile(value) => value,
        }
    }
}

#[cfg(target_os = "macos")]
fn migrate_default_profile_key(
    app: &AppHandle,
    destination_account: &str,
    expected_scope: &str,
) -> Result<Option<LoadedCredential>, String> {
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
    let generation = next_credential_generation();
    write_credential_scope_marker(app, DEFAULT_PROFILE_ID, expected_scope, &generation, true)?;
    write_scoped_entry(destination_account, expected_scope, &generation, &value)?;

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
    Ok(Some(LoadedCredential {
        generation,
        secret: value,
    }))
}

#[cfg(target_os = "macos")]
fn find_legacy_credential(app: &AppHandle) -> Result<Option<LegacyCredential>, String> {
    if let Some(value) = read_entry(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)? {
        return Ok(Some(LegacyCredential::Keychain(value)));
    }
    if let Some(value) = read_entry(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)? {
        return Ok(Some(LegacyCredential::Keychain(value)));
    }
    read_legacy_dev_key(app).map(|value| value.map(LegacyCredential::DevFile))
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn remove_legacy_dev_key_if_present(app: &AppHandle) -> Result<(), String> {
    let path = legacy_dev_key_file(app)?;
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除旧开发 Key 文件：{error}")),
    }
}

#[cfg(not(target_os = "macos"))]
fn remove_legacy_dev_key_if_present(_app: &AppHandle) -> Result<(), String> {
    Ok(())
}

fn remove_legacy_dev_key_best_effort(app: &AppHandle) {
    if let Err(error) = remove_legacy_dev_key_if_present(app) {
        crate::debug_log(
            app,
            &format!("legacy plaintext credential cleanup failed: {error}"),
        );
    }
}

#[cfg(target_os = "macos")]
fn remove_legacy_keychain_entries() -> Result<(), String> {
    delete_entry(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?;
    delete_entry(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)
}

#[cfg(not(target_os = "macos"))]
fn remove_legacy_keychain_entries() -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn read_entry(service: &str, account: &str) -> Result<Option<String>, String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    match entry.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(error) => Err(format!("无法读取钥匙串条目：{error}")),
    }
}

#[cfg(target_os = "windows")]
fn read_entry(service: &str, account: &str) -> Result<Option<String>, String> {
    let target = windows_credential_target(service, account);
    let Some(credential) = read_windows_credential(&target)? else {
        return Ok(None);
    };
    let credential = credential.credential();
    let blob_length = credential.CredentialBlobSize as usize;
    if blob_length > WINDOWS_CREDENTIAL_BLOB_MAX_BYTES {
        return Err("Windows 凭据条目过大，请移除后重新保存。".to_string());
    }
    if blob_length == 0 {
        return Ok(Some(String::new()));
    }
    if credential.CredentialBlob.is_null() {
        return Err("Windows 凭据条目编码无效，请移除后重新保存。".to_string());
    }
    // SAFETY: the blob pointer and size belong to the live CredReadW result.
    // WindowsCredentialBuffer erases and frees them after this decode returns.
    let blob = unsafe { std::slice::from_raw_parts(credential.CredentialBlob, blob_length) };
    decode_windows_credential_blob(blob).map(Some)
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn read_entry(_service: &str, _account: &str) -> Result<Option<String>, String> {
    Err("当前平台不支持安全凭据存储。".to_string())
}

fn decode_stored_credential(raw: &str) -> StoredCredential {
    match serde_json::from_str::<CredentialEnvelope>(raw) {
        Ok(envelope)
            if (envelope.version == CREDENTIAL_ENVELOPE_VERSION
                && !envelope.generation.is_empty())
                || (envelope.version == LEGACY_CREDENTIAL_ENVELOPE_VERSION
                    && envelope.generation.is_empty()) =>
        {
            StoredCredential::Bound(envelope)
        }
        Ok(_) => StoredCredential::Malformed,
        Err(_) if raw.trim_start().starts_with('{') => StoredCredential::Malformed,
        Err(_) => StoredCredential::LegacyRaw(raw.to_string()),
    }
}

fn write_scoped_entry(
    account: &str,
    scope: &str,
    generation: &str,
    secret: &str,
) -> Result<(), String> {
    let envelope = CredentialEnvelope {
        version: CREDENTIAL_ENVELOPE_VERSION,
        scope: scope.to_string(),
        generation: generation.to_string(),
        secret: secret.to_string(),
    };
    let encoded = serde_json::to_string(&envelope)
        .map_err(|error| format!("无法封装系统安全凭据：{error}"))?;
    write_entry(PROFILE_KEYCHAIN_SERVICE, account, &encoded)?;

    let verified = read_entry(PROFILE_KEYCHAIN_SERVICE, account)?
        .ok_or_else(|| "系统安全凭据写入后无法读回。".to_string())?;
    match decode_stored_credential(&verified) {
        StoredCredential::Bound(stored)
            if stored.scope == scope
                && stored.generation == generation
                && stored.secret == secret =>
        {
            Ok(())
        }
        _ => Err("系统安全凭据写入校验失败。".to_string()),
    }
}

#[cfg(target_os = "macos")]
fn write_entry(service: &str, account: &str, value: &str) -> Result<(), String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    entry
        .set_password(value)
        .map_err(|error| format!("无法写入钥匙串：{error}"))
}

#[cfg(target_os = "windows")]
fn write_entry(service: &str, account: &str, value: &str) -> Result<(), String> {
    debug_assert_eq!(
        WINDOWS_CREDENTIAL_BLOB_MAX_BYTES,
        CRED_MAX_CREDENTIAL_BLOB_SIZE as usize
    );
    let mut target = windows_wide_string(&windows_credential_target(service, account));
    let mut username = windows_wide_string(account);
    let mut blob = encode_windows_credential_blob(value)?;
    let byte_length = blob.len() * std::mem::size_of::<u16>();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: byte_length as u32,
        CredentialBlob: blob.as_mut_ptr().cast(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: username.as_mut_ptr(),
        ..Default::default()
    };
    // SAFETY: all pointers reference live buffers for the duration of the call;
    // CredWriteW copies the credential before returning.
    if unsafe { CredWriteW(&credential, 0) } == 0 {
        // SAFETY: GetLastError is called immediately after the failed Win32 API.
        let code = unsafe { GetLastError() };
        return Err(windows_api_error("写入系统凭据", code));
    }
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn write_entry(_service: &str, _account: &str, _value: &str) -> Result<(), String> {
    Err("当前平台不支持安全凭据存储。".to_string())
}

#[cfg(target_os = "macos")]
fn delete_entry(service: &str, account: &str) -> Result<(), String> {
    let entry = Entry::new(service, account).map_err(|error| format!("无法访问钥匙串：{error}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
        Err(error) => Err(format!("无法删除钥匙串条目：{error}")),
    }
}

#[cfg(target_os = "windows")]
fn delete_entry(service: &str, account: &str) -> Result<(), String> {
    let target = windows_wide_string(&windows_credential_target(service, account));
    // SAFETY: target is a live NUL-terminated UTF-16 string.
    if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } != 0 {
        return Ok(());
    }
    // SAFETY: GetLastError is called immediately after the failed Win32 API.
    let code = unsafe { GetLastError() };
    if code == ERROR_NOT_FOUND {
        Ok(())
    } else {
        Err(windows_api_error("删除系统凭据", code))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn delete_entry(_service: &str, _account: &str) -> Result<(), String> {
    Err("当前平台不支持安全凭据存储。".to_string())
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
    fn legacy_plaintext_and_qwen_migration_is_macos_only() {
        assert_eq!(
            legacy_migration_policy_for("macos"),
            LegacyMigrationPolicy::MacOsKeychainAndDevFile
        );
        assert_eq!(
            legacy_migration_policy_for("windows"),
            LegacyMigrationPolicy::Disabled
        );
    }

    #[test]
    fn windows_target_name_is_stable_and_profile_scoped() {
        assert_eq!(
            windows_credential_target(
                PROFILE_KEYCHAIN_SERVICE,
                "profile:model-studio-default:api-key"
            ),
            "Satori/com.yuxino.satori.ai.v1/profile:model-studio-default:api-key"
        );
    }

    #[test]
    fn windows_credential_blob_round_trips_utf16_without_a_secret_copy_in_errors() {
        let secret = "sk-test-密钥";
        let encoded = encode_windows_credential_blob(secret).expect("fixture should fit");
        let bytes = unsafe {
            std::slice::from_raw_parts(
                encoded.as_ptr().cast::<u8>(),
                encoded.len() * std::mem::size_of::<u16>(),
            )
        };
        assert_eq!(decode_windows_credential_blob(bytes).unwrap(), secret);

        let error =
            decode_windows_credential_blob(b"sk-").expect_err("odd byte length must be rejected");
        assert!(!error.contains("sk-"));
    }

    #[test]
    fn windows_credential_blob_enforces_the_native_size_limit() {
        let oversized = "a".repeat(WINDOWS_CREDENTIAL_BLOB_MAX_BYTES / 2 + 1);
        assert!(encode_windows_credential_blob(&oversized).is_err());
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
            generation: "generation-a".to_string(),
            secret: "test-secret".to_string(),
        })
        .unwrap();

        match decode_stored_credential(&encoded) {
            StoredCredential::Bound(envelope) => {
                assert_eq!(envelope.secret, "test-secret");
                assert_eq!(envelope.generation, "generation-a");
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

        let missing_generation = serde_json::json!({
            "version": CREDENTIAL_ENVELOPE_VERSION,
            "scope": "scope-a",
            "secret": "test-secret"
        });
        assert!(matches!(
            decode_stored_credential(&missing_generation.to_string()),
            StoredCredential::Malformed
        ));

        let v1 = serde_json::json!({
            "version": LEGACY_CREDENTIAL_ENVELOPE_VERSION,
            "scope": "scope-a",
            "secret": "test-secret"
        });
        assert!(matches!(
            decode_stored_credential(&v1.to_string()),
            StoredCredential::Bound(_)
        ));
    }

    #[test]
    fn session_cache_is_scope_bound_and_evictable() {
        let profile_id = "test-session-cache";
        cache_profile_api_key(profile_id, "scope-a", "generation-a", "test-secret").unwrap();
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-a", "generation-a").unwrap(),
            Some("test-secret".to_string())
        );

        // Another process saving a replacement Key changes the public marker
        // generation even when provider and endpoint stay the same.
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-a", "generation-b").unwrap(),
            None
        );
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-a", "generation-a").unwrap(),
            None
        );

        // A changed provider/endpoint/auth scope must not inherit the old Key.
        cache_profile_api_key(profile_id, "scope-a", "generation-a", "test-secret").unwrap();
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-b", "generation-a").unwrap(),
            None
        );
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-a", "generation-a").unwrap(),
            None
        );

        cache_profile_api_key(profile_id, "scope-a", "generation-a", "test-secret").unwrap();
        evict_cached_profile_api_key(profile_id).unwrap();
        assert_eq!(
            cached_profile_api_key(profile_id, "scope-a", "generation-a").unwrap(),
            None
        );
    }
}
