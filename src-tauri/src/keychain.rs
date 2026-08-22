//! 每个 AI 配置使用独立的 macOS Keychain 条目。
//! 旧 Qwen 条目和开发明文文件只作为默认百炼配置的一次性迁移输入。

use crate::provider::resolve_profile;
use crate::store::{load_ai_profile, validate_profile_id, AIProfile, DEFAULT_PROFILE_ID};
use fs2::FileExt;
use keyring::{Entry, Error as KeyringError};
use security_framework::item::{ItemClass, ItemSearchOptions};
use security_framework::os::macos::keychain::{SecKeychain, SecPreferencesDomain};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};
use zeroize::Zeroizing;

const PROFILE_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.ai.v1";
const CURRENT_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v3";
const LEGACY_QWEN_KEYCHAIN_SERVICE: &str = "com.yuxino.satori.qwen.v2";
const LEGACY_QWEN_KEYCHAIN_ACCOUNT: &str = "qwen-api-key";
const MIGRATION_MARKER_DIRECTORY: &str = "credential-migrations";
const CREDENTIAL_SCOPE_DIRECTORY: &str = "credential-scopes";
const CREDENTIAL_SCOPE_MARKER_VERSION: u8 = 1;
const CREDENTIAL_ENVELOPE_VERSION: u8 = 2;
const LEGACY_CREDENTIAL_ENVELOPE_VERSION: u8 = 1;
const CREDENTIAL_LOCK_FILE: &str = "credential-operations-v1.lock";
const DELETION_TOMBSTONE_VALUE: &str = "deleted-v1";
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

static CREDENTIAL_LOCK: Mutex<()> = Mutex::new(());
static CREDENTIAL_CACHE: LazyLock<Mutex<HashMap<String, CachedCredential>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CREDENTIAL_MARKER_COUNTER: AtomicU64 = AtomicU64::new(0);

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
    let _interaction_lock = if allow_interaction {
        None
    } else {
        Some(
            SecKeychain::disable_user_interaction()
                .map_err(|error| format!("无法暂停钥匙串授权界面：{error}"))?,
        )
    };

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
            crate::debug_log(&format!("credential scope marker write failed: {error}"));
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
                if profile_id == DEFAULT_PROFILE_ID {
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
                Err("钥匙串中的 AI 凭据格式无效，请移除后重新保存。".to_string())
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
        if profile_id == DEFAULT_PROFILE_ID {
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
        if profile_id == DEFAULT_PROFILE_ID {
            // 先落 marker 再删除；marker 失败时保留新 Key，避免下一次读取
            // 又从 qwen.v3/v2 或开发文件把用户删除的凭据恢复回来。
            write_migration_marker(&app, &profile_id)?;
            remove_legacy_dev_key_if_present(&app)?;
            remove_legacy_keychain_entries()?;
        }
        delete_entry(PROFILE_KEYCHAIN_SERVICE, &account)?;
        if let Err(error) = remove_credential_scope_marker(&app, &profile_id) {
            crate::debug_log(&format!("credential scope marker removal failed: {error}"));
        }
        Ok(CredentialStatus { saved: false })
    })
    .await
}

fn credential_guard(app: &AppHandle) -> Result<CredentialGuard, String> {
    let process_guard = CREDENTIAL_LOCK
        .lock()
        .map_err(|_| "钥匙串操作锁已损坏，请重新启动 Satori。".to_string())?;
    let app_data = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("无法定位应用数据目录：{error}"))?;
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
            crate::debug_log(&format!("credential scope marker ignored: {error}"));
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
        .map_err(|error| format!("钥匙串任务失败：{error}"))?
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
            crate::debug_log(&format!("credential scope marker ignored: {error}"));
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

    Ok(
        entry_exists(CURRENT_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?
            || entry_exists(LEGACY_QWEN_KEYCHAIN_SERVICE, LEGACY_QWEN_KEYCHAIN_ACCOUNT)?
            || legacy_dev_key_file(app)?.is_file(),
    )
}

/// Match only the service/account identity and ask Security.framework to
/// return no attributes, reference or data. The OSStatus alone tells us
/// whether an item exists without evaluating its decrypt ACL.
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
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("无法定位应用数据目录：{error}"))?
        .join(MIGRATION_MARKER_DIRECTORY);
    Ok(directory.join(migration_marker_name(profile_id)?))
}

fn credential_scope_marker_file(app: &AppHandle, profile_id: &str) -> Result<PathBuf, String> {
    validate_profile_id(profile_id)?;
    let directory = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("无法定位应用数据目录：{error}"))?
        .join(CREDENTIAL_SCOPE_DIRECTORY);
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
    fs::write(&temporary, encoded).map_err(|error| format!("无法写入凭据范围标记：{error}"))?;
    if let Err(error) = fs::rename(&temporary, &path) {
        let _ = fs::remove_file(&temporary);
        return Err(format!("无法更新凭据范围标记：{error}"));
    }
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
            crate::debug_log(&format!("credential scope marker repair required: {error}"));
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

fn remove_legacy_dev_key_best_effort(app: &AppHandle) {
    if let Err(error) = remove_legacy_dev_key_if_present(app) {
        crate::debug_log(&format!(
            "legacy plaintext credential cleanup failed: {error}"
        ));
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
    let encoded =
        serde_json::to_string(&envelope).map_err(|error| format!("无法封装钥匙串凭据：{error}"))?;
    write_entry(PROFILE_KEYCHAIN_SERVICE, account, &encoded)?;

    let verified = read_entry(PROFILE_KEYCHAIN_SERVICE, account)?
        .ok_or_else(|| "钥匙串写入后无法读回凭据。".to_string())?;
    match decode_stored_credential(&verified) {
        StoredCredential::Bound(stored)
            if stored.scope == scope
                && stored.generation == generation
                && stored.secret == secret =>
        {
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
