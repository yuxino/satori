use semver::Version;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tauri::{AppHandle, State};

use crate::AppState;

const LATEST_RELEASE_API: &str = "https://api.github.com/repos/yuxino/satori/releases/latest";

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    draft: bool,
    prerelease: bool,
}

#[derive(Debug, PartialEq, Serialize)]
pub struct AppUpdateInfo {
    current_version: String,
    latest_version: String,
    available: bool,
}

fn normalized_version(value: &str) -> Result<Version, String> {
    let trimmed = value.trim();
    let normalized = trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed);
    Version::parse(normalized).map_err(|_| format!("无法识别版本号：{value}"))
}

fn update_info(current: &str, latest_tag: &str) -> Result<AppUpdateInfo, String> {
    let current_version = normalized_version(current)?;
    let latest_version = normalized_version(latest_tag)?;
    if !latest_version.pre.is_empty() {
        return Err(format!("最新 Release 不是正式版本：{latest_tag}"));
    }
    let available = latest_version.cmp_precedence(&current_version).is_gt();

    Ok(AppUpdateInfo {
        current_version: current_version.to_string(),
        latest_version: latest_version.to_string(),
        available,
    })
}

#[tauri::command]
pub async fn check_for_update(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<AppUpdateInfo, String> {
    let current_version = app.package_info().version.to_string();
    let response = state
        .client
        .get(LATEST_RELEASE_API)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .header(
            reqwest::header::USER_AGENT,
            format!("Satori/{current_version}"),
        )
        .timeout(Duration::from_secs(12))
        .send()
        .await
        .map_err(|error| format!("无法连接更新服务器：{error}"))?;

    let response = response
        .error_for_status()
        .map_err(|error| format!("更新服务器返回错误：{error}"))?;
    let release = response
        .json::<GitHubRelease>()
        .await
        .map_err(|error| format!("更新信息解析失败：{error}"))?;
    if release.draft || release.prerelease {
        return Err("更新服务器返回的不是正式 Release。".to_string());
    }

    update_info(&current_version, &release.tag_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_stable_release_versions_semantically() {
        assert!(update_info("3.3.1", "v3.3.2").unwrap().available);
        assert!(update_info("3.9.9", "3.10.0").unwrap().available);
        assert!(update_info("3.3.1", "v4.0.0").unwrap().available);
        assert!(!update_info("3.3.1", "v3.3.1").unwrap().available);
        assert!(!update_info("3.3.1", "v3.2.9").unwrap().available);
    }

    #[test]
    fn ignores_build_metadata_and_rejects_prereleases() {
        assert!(
            !update_info("3.3.1+local", "v3.3.1+release")
                .unwrap()
                .available
        );
        assert!(update_info("3.3.1", "v3.4.0-beta.1").is_err());
        assert!(update_info("3.4.0-beta.1", "v3.4.0").unwrap().available);
    }

    #[test]
    fn rejects_invalid_release_tags() {
        for tag in ["latest", "3.4", "3.04.0", ""] {
            assert!(update_info("3.3.1", tag).is_err(), "tag {tag:?}");
        }
    }
}
