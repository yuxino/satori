mod atomic_file;
mod keychain;
mod pdf_file;
mod platform_paths;
mod provider;
mod qwen;
mod store;
mod thumbs;

use fs2::FileExt;
use tauri::{Emitter, Manager};

struct InstanceLock {
    _file: std::fs::File,
}

fn acquire_exclusive_lock(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)?;
    FileExt::try_lock_exclusive(&file)?;
    Ok(file)
}

fn acquire_single_instance_startup_gate() -> std::io::Result<std::fs::File> {
    let path = std::env::temp_dir().join("com.yuxino.satori-single-instance-startup.lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)?;
    FileExt::lock_exclusive(&file)?;
    Ok(file)
}

fn acquire_instance_lock(app: &tauri::AppHandle) -> Result<std::fs::File, String> {
    let data_dir = platform_paths::non_secret_data_dir(app)?;
    std::fs::create_dir_all(&data_dir).map_err(|error| format!("无法创建应用数据目录：{error}"))?;
    acquire_exclusive_lock(&data_dir.join("instance.lock"))
        .map_err(|error| format!("无法获取应用单实例锁：{error}"))
}

fn exit_before_renderer(app: &tauri::AppHandle, error: &str) -> ! {
    debug_log(app, &format!("single instance rejected: {error}"));
    app.cleanup_before_exit();
    std::process::exit(0);
}

fn instance_lock_plugin(startup_gate: std::fs::File) -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri::plugin::Builder::new("instance-lock")
        .setup(move |app, _api| {
            let instance_lock = match acquire_instance_lock(app) {
                Ok(file) => file,
                Err(error) => exit_before_renderer(app, &error),
            };
            app.manage(InstanceLock {
                _file: instance_lock,
            });
            if let Err(error) = FileExt::unlock(&startup_gate) {
                exit_before_renderer(app, &format!("无法释放应用启动锁：{error}"));
            }
            Ok(())
        })
        .build()
}

#[derive(Debug, PartialEq, Eq)]
enum AppMenuAction {
    OpenSettings,
    CloseWindow,
    Ignore,
}

fn app_menu_action(id: &str) -> AppMenuAction {
    match id {
        "settings" => AppMenuAction::OpenSettings,
        "quit" => AppMenuAction::CloseWindow,
        _ => AppMenuAction::Ignore,
    }
}

#[cfg(any(feature = "dev-live", test))]
fn dev_asset_relative_path(uri_path: &str) -> Option<std::path::PathBuf> {
    use std::path::{Component, Path, PathBuf};

    let raw = uri_path.strip_prefix('/').unwrap_or(uri_path);
    if raw.starts_with('/') {
        return None;
    }
    let decoded = urlencoding::decode(raw).ok()?;
    if decoded.is_empty() {
        return Some(PathBuf::from("index.html"));
    }
    let relative = Path::new(decoded.as_ref());
    if !relative
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
    {
        return None;
    }
    Some(relative.to_path_buf())
}

#[cfg(feature = "dev-live")]
fn dev_asset_mime(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js" | "mjs") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("wasm") => "application/wasm",
        _ => "application/octet-stream",
    }
}

#[cfg(feature = "dev-live")]
fn dev_asset_response(request: tauri::http::Request<Vec<u8>>) -> tauri::http::Response<Vec<u8>> {
    use tauri::http::{header, Response, StatusCode};

    let response = |status, content_type, body| {
        Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::CACHE_CONTROL, "no-store")
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "tauri://localhost")
            .body(body)
            .expect("static development asset response headers must be valid")
    };

    let Some(relative) = dev_asset_relative_path(request.uri().path()) else {
        return response(
            StatusCode::FORBIDDEN,
            "text/plain; charset=utf-8",
            b"forbidden development asset path".to_vec(),
        );
    };
    let dist = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../dist");
    let Ok(dist) = dist.canonicalize() else {
        return response(
            StatusCode::SERVICE_UNAVAILABLE,
            "text/plain; charset=utf-8",
            b"development assets are not built".to_vec(),
        );
    };
    let path = dist.join(relative);
    let Ok(path) = path.canonicalize() else {
        return response(
            StatusCode::NOT_FOUND,
            "text/plain; charset=utf-8",
            b"development asset not found".to_vec(),
        );
    };
    if !path.starts_with(&dist) || !path.is_file() {
        return response(
            StatusCode::FORBIDDEN,
            "text/plain; charset=utf-8",
            b"forbidden development asset".to_vec(),
        );
    }
    match std::fs::read(&path) {
        Ok(body) => response(StatusCode::OK, dev_asset_mime(&path), body),
        Err(_) => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            b"failed to read development asset".to_vec(),
        ),
    }
}

/// 临时调试日志：追加到 App 数据目录的 debug.log（release 下 stdout 不可见）。
pub fn debug_log(app: &tauri::AppHandle, msg: &str) {
    use std::io::Write;
    if let Ok(dir) = platform_paths::non_secret_data_dir(app) {
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("debug.log");
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let _ = writeln!(f, "[{ts}] {msg}");
        }
    }
}

pub struct AppState {
    pub client: reqwest::Client,
    pub direct_client: reqwest::Client,
}

impl AppState {
    pub(crate) fn ai_client(&self, is_local: bool) -> &reqwest::Client {
        if is_local {
            &self.direct_client
        } else {
            &self.client
        }
    }
}

fn build_http_client(direct: bool) -> reqwest::Client {
    let builder = reqwest::Client::builder()
        // API requests must never forward credentials or page images to a
        // redirect target. Users configure the final endpoint.
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(std::time::Duration::from_secs(20))
        .timeout(std::time::Duration::from_secs(120));
    let builder = if direct { builder.no_proxy() } else { builder };
    builder.build().expect("failed to build http client")
}

trait ActivatableWindow {
    fn restore_for_activation(&self);
    fn show_for_activation(&self);
    fn focus_for_activation(&self);
}

impl<R: tauri::Runtime> ActivatableWindow for tauri::WebviewWindow<R> {
    fn restore_for_activation(&self) {
        let _ = self.unminimize();
    }

    fn show_for_activation(&self) {
        let _ = self.show();
    }

    fn focus_for_activation(&self) {
        let _ = self.set_focus();
    }
}

fn activate_window(window: &impl ActivatableWindow) {
    window.restore_for_activation();
    window.show_for_activation();
    window.focus_for_activation();
}

fn activate_existing_main_window<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    #[cfg(target_os = "macos")]
    let _ = app.show();
    if let Some(window) = app.get_webview_window("main") {
        activate_window(&window);
    }
}

#[tauri::command]
fn complete_app_exit(app: tauri::AppHandle) {
    app.exit(0);
}

pub fn run() {
    // The official plugin creates its Windows mutex before its activation
    // window. Serialize that short setup interval so a concurrent launch
    // cannot slip through the gap and become a second Store writer.
    let startup_gate = match acquire_single_instance_startup_gate() {
        Ok(file) => file,
        Err(error) => {
            eprintln!("Satori could not acquire its startup lock: {error}");
            return;
        }
    };
    let builder = tauri::Builder::default()
        // This must stay first: a secondary process must exit before any
        // plugin or renderer can load and later overwrite the shared Store.
        .plugin(tauri_plugin_single_instance::init(
            |app, _arguments, _working_directory| {
                activate_existing_main_window(app);
            },
        ))
        // Acquire the process-lifetime data lock before Tauri creates the
        // configured WebView. This plugin must stay ahead of dialog/opener.
        .plugin(instance_lock_plugin(startup_gate))
        .plugin(tauri_plugin_dialog::init())
        // Only the explicit, capability-scoped update action uses opener.
        // Do not intercept every `_blank` link rendered in AI answers.
        .plugin(
            tauri_plugin_opener::Builder::new()
                .open_js_links_on_click(false)
                .build(),
        )
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState {
            client: build_http_client(false),
            // Loopback AI services are a local privacy boundary. Never let
            // HTTP_PROXY or other ambient proxy settings intercept them.
            direct_client: build_http_client(true),
        });
    // A feature-gated development shell serves the latest Vite build from
    // disk without embedding it into each native rebuild. Production builds
    // keep Tauri's normal embedded `tauri://` asset handler.
    #[cfg(feature = "dev-live")]
    let builder = builder
        .register_uri_scheme_protocol("tauri", |_context, request| dev_asset_response(request));

    builder
        .setup(|app| {
            use tauri::menu::{Menu, MenuItemBuilder, SubmenuBuilder};

            let app_menu = SubmenuBuilder::new(app, "Satori");
            #[cfg(feature = "dev-live")]
            let app_menu = app_menu.item(
                &MenuItemBuilder::with_id("toggle-devtools", "打开调试工具")
                    .accelerator("CmdOrCtrl+Option+I")
                    .build(app)?,
            );
            let app_menu = app_menu
                .item(
                    &MenuItemBuilder::with_id("settings", "设置…")
                        .accelerator("CmdOrCtrl+,")
                        .build(app)?,
                )
                .separator()
                .item(
                    &MenuItemBuilder::with_id("quit", "退出 Satori")
                        .accelerator("CmdOrCtrl+Q")
                        .build(app)?,
                )
                .build()?;
            let menu = Menu::with_items(app, &[&app_menu])?;
            app.set_menu(menu)?;

            Ok(())
        })
        .on_menu_event(|app, event| {
            #[cfg(feature = "dev-live")]
            if event.id().as_ref() == "toggle-devtools" {
                // 手动打开 WebView 调试工具（用户决定何时查看，不自动打开）。
                if let Some(window) = app.get_webview_window("main") {
                    window.open_devtools();
                }
                return;
            }

            match app_menu_action(event.id().as_ref()) {
                AppMenuAction::OpenSettings => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.emit("open-settings", ());
                    }
                }
                AppMenuAction::CloseWindow => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.close();
                    } else {
                        // No renderer means there is no pending WebView state to flush.
                        app.exit(0);
                    }
                }
                AppMenuAction::Ignore => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            keychain::credential_status,
            keychain::save_profile_api_key,
            keychain::delete_profile_api_key,
            store::load_store,
            store::save_store,
            store::resolve_book_path,
            pdf_file::inspect_pdf_file,
            complete_app_exit,
            thumbs::load_thumb,
            thumbs::save_thumb,
            qwen::ask_visual,
            qwen::test_ai_profile,
            qwen::extract_outline,
            qwen::find_page_by_title,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod dev_asset_tests {
    use super::{
        acquire_exclusive_lock, activate_window, app_menu_action, build_http_client,
        dev_asset_relative_path, ActivatableWindow, AppMenuAction, AppState,
    };
    use fs2::FileExt;
    use std::cell::RefCell;
    use std::path::PathBuf;

    #[derive(Debug, PartialEq, Eq)]
    enum ActivationAction {
        Restore,
        Show,
        Focus,
    }

    #[derive(Default)]
    struct RecordingWindow {
        actions: RefCell<Vec<ActivationAction>>,
    }

    impl ActivatableWindow for RecordingWindow {
        fn restore_for_activation(&self) {
            self.actions.borrow_mut().push(ActivationAction::Restore);
        }

        fn show_for_activation(&self) {
            self.actions.borrow_mut().push(ActivationAction::Show);
        }

        fn focus_for_activation(&self) {
            self.actions.borrow_mut().push(ActivationAction::Focus);
        }
    }

    #[test]
    fn dev_asset_root_resolves_to_index() {
        assert_eq!(
            dev_asset_relative_path("/"),
            Some(PathBuf::from("index.html"))
        );
    }

    #[test]
    fn dev_asset_allows_normal_static_paths() {
        assert_eq!(
            dev_asset_relative_path("/assets/app.js"),
            Some(PathBuf::from("assets/app.js"))
        );
    }

    #[test]
    fn dev_asset_rejects_plain_and_encoded_parent_segments() {
        assert_eq!(dev_asset_relative_path("/../store.json"), None);
        assert_eq!(dev_asset_relative_path("/%2e%2e/store.json"), None);
    }

    #[test]
    fn local_ai_requests_select_the_no_proxy_client() {
        let state = AppState {
            client: build_http_client(false),
            direct_client: build_http_client(true),
        };
        assert!(std::ptr::eq(state.ai_client(false), &state.client));
        assert!(std::ptr::eq(state.ai_client(true), &state.direct_client));
    }

    #[test]
    fn quit_menu_closes_the_window_instead_of_exiting_immediately() {
        assert_eq!(app_menu_action("quit"), AppMenuAction::CloseWindow);
        assert_eq!(app_menu_action("settings"), AppMenuAction::OpenSettings);
        assert_eq!(app_menu_action("unknown"), AppMenuAction::Ignore);
    }

    #[test]
    fn secondary_launch_restores_shows_and_focuses_the_existing_window() {
        let window = RecordingWindow::default();

        activate_window(&window);

        assert_eq!(
            *window.actions.borrow(),
            [
                ActivationAction::Restore,
                ActivationAction::Show,
                ActivationAction::Focus,
            ]
        );
    }

    #[test]
    fn process_lock_rejects_a_competing_store_writer() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("the test clock must be after the Unix epoch")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "satori-instance-lock-test-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).expect("test lock directory must be creatable");
        let path = directory.join("instance.lock");

        let first = acquire_exclusive_lock(&path).expect("the first writer must acquire the lock");
        assert!(
            acquire_exclusive_lock(&path).is_err(),
            "a second writer must fail closed while the first process owns the lock"
        );

        FileExt::unlock(&first).expect("the test lock must be releasable");
        drop(first);
        std::fs::remove_dir_all(directory).expect("the test lock directory must be removable");
    }
}
