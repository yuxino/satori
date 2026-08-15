mod keychain;
mod qwen;
mod store;
mod thumbs;

use tauri::{Emitter, Manager};

/// 可配置的百炼视觉模型清单。默认使用理解能力最强的档位；
/// 用户可以在设置里换成更均衡或更节省的档位。
#[derive(Clone, serde::Serialize)]
pub struct ModelOption {
    pub id: String,
    pub title: String,
    pub explanation: String,
}

pub struct AppState {
    pub client: reqwest::Client,
}

pub fn model_options() -> Vec<ModelOption> {
    vec![
        ModelOption {
            id: "qwen3-vl-plus".to_string(),
            title: "平衡 · Qwen3-VL Plus".to_string(),
            explanation: "理解能力与速度均衡，适合日常阅读解释。".to_string(),
        },
        ModelOption {
            id: "qwen3-vl-flash".to_string(),
            title: "节省 · Qwen3-VL Flash".to_string(),
            explanation: "速度更快、费用更低，适合简单解释。".to_string(),
        },
        ModelOption {
            id: "qwen-vl-max".to_string(),
            title: "最佳 · Qwen-VL Max".to_string(),
            explanation: "理解能力最强，费用最高。".to_string(),
        },
    ]
}

#[tauri::command]
fn list_model_options() -> Vec<ModelOption> {
    model_options()
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            client: reqwest::Client::new(),
        })
        .setup(|app| {
            use tauri::menu::{Menu, MenuItemBuilder, SubmenuBuilder};

            // 应用菜单（macOS 菜单栏）。调试工具不默认打开，由用户手动触发。
            let menu = Menu::with_items(app, &[
                &SubmenuBuilder::new(app, "satori")
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
                    .build()?,
            ])?;
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
            list_model_options,
            keychain::read_api_key,
            keychain::save_api_key,
            keychain::save_dev_key,
            store::load_store,
            store::save_store,
            store::resolve_book_path,
            thumbs::load_thumb,
            thumbs::save_thumb,
            qwen::ask_visual,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
