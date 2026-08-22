mod keychain;
mod provider;
mod qwen;
mod store;
mod thumbs;

use tauri::{Emitter, Manager};

/// 临时调试日志：追加到 App 数据目录的 debug.log（release 下 stdout 不可见）。
pub fn debug_log(msg: &str) {
    use std::io::Write;
    if let Ok(dir) = std::env::var("HOME") {
        let path = format!("{dir}/Library/Application Support/com.yuxino.satori/debug.log");
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
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            client: reqwest::Client::builder()
                // API requests must never forward credentials or page images
                // to a redirect target. Users configure the final endpoint.
                .redirect(reqwest::redirect::Policy::none())
                .timeout(std::time::Duration::from_secs(120))
                .build()
                .expect("failed to build http client"),
        })
        .setup(|app| {
            use tauri::menu::{Menu, MenuItemBuilder, SubmenuBuilder};

            // 应用菜单（macOS 菜单栏）。调试工具不默认打开，由用户手动触发。
            let menu = Menu::with_items(
                app,
                &[&SubmenuBuilder::new(app, "satori")
                    .item(
                        &MenuItemBuilder::with_id("toggle-devtools", "打开调试工具")
                            .accelerator("CmdOrCtrl+Option+I")
                            .build(app)?,
                    )
                    .item(
                        &MenuItemBuilder::with_id("settings", "设置…")
                            .accelerator("CmdOrCtrl+,")
                            .build(app)?,
                    )
                    .separator()
                    .item(
                        &MenuItemBuilder::with_id("quit", "退出 satori")
                            .accelerator("CmdOrCtrl+Q")
                            .build(app)?,
                    )
                    .build()?],
            )?;
            app.set_menu(menu)?;

            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
