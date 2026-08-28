//! AI provider profile validation shared by requests and credential binding.
//!
//! A credential scope is derived only from a persisted profile in Rust. This
//! prevents an untrusted WebView payload from pairing an existing profile ID
//! (and therefore its Keychain secret) with a different endpoint.

use crate::store::{AIProfile, AIProviderKind};
use reqwest::Url;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const MODEL_STUDIO_API_BASE: &str = "https://dashscope.aliyuncs.com/compatible-mode/v1";
const OPENAI_API_BASE: &str = "https://api.openai.com/v1";
const CHAT_COMPLETIONS_PATH: &str = "/chat/completions";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProviderPolicy {
    ModelStudio,
    OpenAi,
    OpenAiCompatible,
}

impl ProviderPolicy {
    fn scope_name(self) -> &'static str {
        match self {
            Self::ModelStudio => "model_studio",
            Self::OpenAi => "open_ai",
            Self::OpenAiCompatible => "open_ai_compatible",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct ResolvedProfile {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) model_id: String,
    pub(crate) chat_url: Url,
    pub(crate) policy: ProviderPolicy,
    pub(crate) is_local: bool,
    pub(crate) api_key_required: bool,
    pub(crate) credential_scope: String,
}

impl ResolvedProfile {
    pub(crate) fn instruction_role(&self) -> &'static str {
        if self.policy == ProviderPolicy::OpenAi {
            "developer"
        } else {
            "system"
        }
    }

    pub(crate) fn sends_store_flag(&self) -> bool {
        !self.is_local
    }
}

pub(crate) fn resolve_profile(profile: &AIProfile) -> Result<ResolvedProfile, String> {
    let id = profile.id.trim();
    if id.is_empty() {
        return Err("连接 ID 不能为空。".to_string());
    }
    let model_id = profile.model_id.trim();
    if model_id.is_empty() {
        return Err("模型 ID 不能为空。".to_string());
    }
    let name = if profile.name.trim().is_empty() {
        "AI 连接"
    } else {
        profile.name.trim()
    };

    let (policy, chat_url, is_local, api_key_required) = match &profile.provider {
        AIProviderKind::ModelStudio => (
            ProviderPolicy::ModelStudio,
            normalize_chat_url(MODEL_STUDIO_API_BASE, false)?.0,
            false,
            true,
        ),
        AIProviderKind::OpenAi => (
            ProviderPolicy::OpenAi,
            normalize_chat_url(OPENAI_API_BASE, false)?.0,
            false,
            true,
        ),
        AIProviderKind::OpenAiCompatible => {
            let (url, local) = normalize_chat_url(profile.base_url.trim(), true)?;
            (
                ProviderPolicy::OpenAiCompatible,
                url,
                local,
                profile.api_key_required,
            )
        }
    };

    // Do not include the model: changing models at the same trusted service
    // should not make the user re-enter the credential. Auth mode is included
    // so toggling Authorization cannot silently reuse an older binding.
    let credential_scope = format!(
        "v1\nprovider={}\nurl={}\nauth={api_key_required}",
        policy.scope_name(),
        chat_url.as_str(),
    );

    Ok(ResolvedProfile {
        id: id.to_string(),
        name: name.to_string(),
        model_id: model_id.to_string(),
        chat_url,
        policy,
        is_local,
        api_key_required,
        credential_scope,
    })
}

pub(crate) fn validate_profile_for_storage(profile: &AIProfile) -> Result<(), String> {
    if profile.name.trim().is_empty() {
        return Err("连接名称不能为空。".to_string());
    }
    resolve_profile(profile)?;
    match profile.provider {
        AIProviderKind::ModelStudio
            if profile.base_url.trim() != MODEL_STUDIO_API_BASE || !profile.api_key_required =>
        {
            Err("阿里云百炼连接必须使用内置地址和 Key 鉴权。".to_string())
        }
        AIProviderKind::OpenAi
            if profile.base_url.trim() != OPENAI_API_BASE || !profile.api_key_required =>
        {
            Err("OpenAI 连接必须使用内置地址和 Key 鉴权。".to_string())
        }
        _ => Ok(()),
    }
}

pub(crate) fn normalize_chat_url(input: &str, user_supplied: bool) -> Result<(Url, bool), String> {
    if input.trim().is_empty() {
        return Err("API 地址不能为空。".to_string());
    }
    let mut url = Url::parse(input.trim()).map_err(|_| "API 地址格式不正确。".to_string())?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("API 地址不能包含用户名或密码。".to_string());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("API 地址不能包含查询参数或片段。".to_string());
    }
    if url.host_str().is_none() {
        return Err("API 地址必须包含主机名。".to_string());
    }

    let is_local = is_loopback_url(&url);
    match url.scheme() {
        "https" => {}
        "http" if user_supplied && is_local => {}
        "http" => return Err("远程 API 地址必须使用 HTTPS。".to_string()),
        _ => return Err("API 地址只支持 HTTPS；本机服务可使用 HTTP。".to_string()),
    }

    let path = url.path().trim_end_matches('/');
    let normalized_path = if path.ends_with(CHAT_COMPLETIONS_PATH) {
        path.to_string()
    } else if path.is_empty() {
        CHAT_COMPLETIONS_PATH.to_string()
    } else {
        format!("{path}{CHAT_COMPLETIONS_PATH}")
    };
    url.set_path(&normalized_path);
    Ok((url, is_local))
}

fn is_loopback_url(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.trim_matches(|character| character == '[' || character == ']');
    host.eq_ignore_ascii_case("localhost")
        || matches!(
            host.parse::<IpAddr>(),
            Ok(IpAddr::V4(address)) if address == Ipv4Addr::LOCALHOST
        )
        || matches!(
            host.parse::<IpAddr>(),
            Ok(IpAddr::V6(address)) if address == Ipv6Addr::LOCALHOST
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(provider: AIProviderKind, base_url: &str, api_key_required: bool) -> AIProfile {
        AIProfile {
            id: "test-profile".to_string(),
            name: "测试连接".to_string(),
            provider,
            base_url: base_url.to_string(),
            model_id: "vision-model".to_string(),
            api_key_required,
        }
    }

    #[test]
    fn credential_scope_uses_canonical_endpoint_and_auth_mode_not_model() {
        let first = resolve_profile(&profile(
            AIProviderKind::OpenAiCompatible,
            "https://EXAMPLE.com/v1/",
            true,
        ))
        .unwrap();
        let mut changed_model = profile(
            AIProviderKind::OpenAiCompatible,
            "https://example.com/v1",
            true,
        );
        changed_model.model_id = "another-model".to_string();
        let second = resolve_profile(&changed_model).unwrap();
        assert_eq!(first.credential_scope, second.credential_scope);

        let no_auth = resolve_profile(&profile(
            AIProviderKind::OpenAiCompatible,
            "https://example.com/v1",
            false,
        ))
        .unwrap();
        assert_ne!(first.credential_scope, no_auth.credential_scope);
    }

    #[test]
    fn custom_remote_can_explicitly_disable_authorization() {
        let resolved = resolve_profile(&profile(
            AIProviderKind::OpenAiCompatible,
            "https://models.example/v1",
            false,
        ))
        .unwrap();
        assert!(!resolved.api_key_required);
        assert!(!resolved.is_local);
    }

    #[test]
    fn stored_profiles_reject_unsafe_or_overridden_endpoints() {
        for base_url in [
            "http://example.com/v1",
            "https://user:secret@example.com/v1",
            "https://example.com/v1?key=secret",
            "https://example.com/v1#models",
        ] {
            assert!(validate_profile_for_storage(&profile(
                AIProviderKind::OpenAiCompatible,
                base_url,
                true,
            ))
            .is_err());
        }

        let mut overridden = profile(AIProviderKind::OpenAi, "https://proxy.example.com/v1", true);
        assert!(validate_profile_for_storage(&overridden)
            .unwrap_err()
            .contains("内置地址"));
        overridden.base_url = OPENAI_API_BASE.to_string();
        overridden.api_key_required = false;
        assert!(validate_profile_for_storage(&overridden)
            .unwrap_err()
            .contains("Key 鉴权"));
    }
}
