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
    #[serde(default)]
    assets: Vec<GitHubReleaseAsset>,
}

#[derive(Debug, Deserialize)]
struct GitHubReleaseAsset {
    name: String,
}

#[derive(Debug, PartialEq, Serialize)]
pub struct AppUpdateInfo {
    current_version: String,
    latest_version: String,
    release_available: bool,
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

fn installer_matches_platform(name: &str, version: &str, os: &str, arch: &str) -> bool {
    let expected = match (os, arch) {
        ("windows", "x86_64") => format!("Satori_{version}_x64-setup.exe"),
        ("windows", "aarch64") => format!("Satori_{version}_arm64-setup.exe"),
        ("macos", "aarch64") => format!("Satori-v{version}-macos-arm64.zip"),
        _ => return false,
    };
    name == expected
}

fn update_info(
    current: &str,
    latest_tag: &str,
    assets: &[GitHubReleaseAsset],
    os: &str,
    arch: &str,
) -> Result<AppUpdateInfo, String> {
    let current_version = normalized_version(current)?;
    let latest_version = normalized_version(latest_tag)?;
    if !latest_version.pre.is_empty() {
        return Err(format!("最新 Release 不是正式版本：{latest_tag}"));
    }
    let latest_version_label = latest_version.to_string();
    let release_available = latest_version.cmp_precedence(&current_version).is_gt();
    let available = release_available
        && assets
            .iter()
            .any(|asset| installer_matches_platform(&asset.name, &latest_version_label, os, arch));

    Ok(AppUpdateInfo {
        current_version: current_version.to_string(),
        latest_version: latest_version_label,
        release_available,
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

    update_info(
        &current_version,
        &release.tag_name,
        &release.assets,
        std::env::consts::OS,
        std::env::consts::ARCH,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(name: &str) -> GitHubReleaseAsset {
        GitHubReleaseAsset {
            name: name.to_string(),
        }
    }

    fn mac_arm_asset(version: &str) -> Vec<GitHubReleaseAsset> {
        vec![asset(&format!("Satori-v{version}-macos-arm64.zip"))]
    }

    #[test]
    fn compares_stable_release_versions_semantically() {
        assert!(
            update_info(
                "3.3.1",
                "v3.3.2",
                &mac_arm_asset("3.3.2"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
        assert!(
            update_info(
                "3.9.9",
                "3.10.0",
                &mac_arm_asset("3.10.0"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
        assert!(
            update_info(
                "3.3.1",
                "v4.0.0",
                &mac_arm_asset("4.0.0"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
        assert!(
            !update_info(
                "3.3.1",
                "v3.3.1",
                &mac_arm_asset("3.3.1"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
        assert!(
            !update_info(
                "3.3.1",
                "v3.2.9",
                &mac_arm_asset("3.2.9"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
    }

    #[test]
    fn ignores_build_metadata_and_rejects_prereleases() {
        assert!(
            !update_info(
                "3.3.1+local",
                "v3.3.1+release",
                &mac_arm_asset("3.3.1"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
        assert!(update_info(
            "3.3.1",
            "v3.4.0-beta.1",
            &mac_arm_asset("3.4.0-beta.1"),
            "macos",
            "aarch64",
        )
        .is_err());
        assert!(
            update_info(
                "3.4.0-beta.1",
                "v3.4.0",
                &mac_arm_asset("3.4.0"),
                "macos",
                "aarch64",
            )
            .unwrap()
            .available
        );
    }

    #[test]
    fn rejects_invalid_release_tags() {
        for tag in ["latest", "3.4", "3.04.0", ""] {
            assert!(
                update_info("3.3.1", tag, &[], "macos", "aarch64",).is_err(),
                "tag {tag:?}"
            );
        }
    }

    #[test]
    fn matches_only_installers_for_the_current_platform_and_architecture() {
        assert!(installer_matches_platform(
            "Satori_3.4.0_x64-setup.exe",
            "3.4.0",
            "windows",
            "x86_64"
        ));
        assert!(installer_matches_platform(
            "Satori_3.4.0_arm64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(installer_matches_platform(
            "Satori-v3.4.0-macos-arm64.zip",
            "3.4.0",
            "macos",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "Satori_3.4.0_x64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "Satori_3.4.0_arm64-setup.exe",
            "3.4.0",
            "windows",
            "x86_64"
        ));
        assert!(!installer_matches_platform(
            "Satori-v3.4.0-macos-arm64.zip",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "satori-v3.4.0-macos-arm64.zip.sha256",
            "3.4.0",
            "macos",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "satori_arm64.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "unrelated_arm64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "Satori_debug_arm64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "Satori_3.3.2_arm64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "satori_3.4.0_arm64-setup.exe",
            "3.4.0",
            "windows",
            "aarch64"
        ));
        assert!(!installer_matches_platform(
            "SATORI-V3.4.0-MACOS-ARM64.ZIP",
            "3.4.0",
            "macos",
            "aarch64"
        ));
    }

    #[test]
    fn newer_release_without_matching_windows_installer_is_not_downloadable() {
        let mac_only = vec![asset("Satori-v3.4.0-macos-arm64.zip")];
        let info = update_info("3.3.2", "v3.4.0", &mac_only, "windows", "aarch64").unwrap();
        assert!(info.release_available);
        assert!(!info.available);
    }
}
