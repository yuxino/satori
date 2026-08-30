mod keychain;
mod platform_paths;
mod provider;
mod qwen;
mod store;
mod thumbs;
mod update;

use tauri::{Emitter, Manager};

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
        .timeout(std::time::Duration::from_secs(120));
    let builder = if direct { builder.no_proxy() } else { builder };
    builder.build().expect("failed to build http client")
}

pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        // Only the explicit, capability-scoped update action uses opener.
        // Do not intercept every `_blank` link rendered in AI answers.
        .plugin(
            tauri_plugin_opener::Builder::new()
                .open_js_links_on_click(false)
                .build(),
        )
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
        .on_menu_event(|app, event| match event.id().as_ref() {
            #[cfg(feature = "dev-live")]
            "toggle-devtools" => {
                // 手动打开 WebView 调试工具（用户决定何时查看，不自动打开）。
                if let Some(window) = app.get_webview_window("main") {
                    window.open_devtools();
                }
            }
            "settings" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.emit("open-settings", ());
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            keychain::credential_status,
            keychain::save_profile_api_key,
            keychain::delete_profile_api_key,
            store::load_store,
            store::save_store,
            store::resolve_book_path,
            thumbs::load_thumb,
            thumbs::save_thumb,
            qwen::ask_visual,
            qwen::test_ai_profile,
            qwen::extract_outline,
            qwen::find_page_by_title,
            update::check_for_update,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod dev_asset_tests {
    use super::{build_http_client, dev_asset_relative_path, AppState};
    use std::path::PathBuf;

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
}
