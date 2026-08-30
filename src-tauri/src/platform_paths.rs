//! Platform-specific roots for non-secret application data.
//!
//! macOS keeps the established Application Support location. Windows uses
//! LocalAppData so books, history, thumbnails and credential sidecars never
//! roam to another machine with the user profile.

use std::path::PathBuf;
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DataRoot {
    AppData,
    AppLocalData,
}

fn data_root_for(target_os: &str) -> DataRoot {
    if target_os == "windows" {
        DataRoot::AppLocalData
    } else {
        DataRoot::AppData
    }
}

pub(crate) fn non_secret_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    match data_root_for(std::env::consts::OS) {
        DataRoot::AppData => app.path().app_data_dir(),
        DataRoot::AppLocalData => app.path().app_local_data_dir(),
    }
    .map_err(|error| format!("无法定位应用数据目录：{error}"))
}

#[cfg(test)]
mod tests {
    use super::{data_root_for, DataRoot};

    #[test]
    fn windows_non_secret_data_does_not_roam() {
        assert_eq!(data_root_for("windows"), DataRoot::AppLocalData);
    }

    #[test]
    fn macos_keeps_the_existing_application_support_root() {
        assert_eq!(data_root_for("macos"), DataRoot::AppData);
    }
}
