//! Provider-neutral OpenAI-compatible visual client.
//!
//! Satori sends page images only for an explicit learning request. Provider
//! profiles contain no secret: credentials are resolved from macOS Keychain
//! immediately before the request is sent.

#[cfg(test)]
use crate::provider::normalize_chat_url;
use crate::provider::{resolve_profile, ProviderPolicy, ResolvedProfile};
use crate::store::load_ai_profile;
#[cfg(test)]
use crate::store::{AIProfile, AIProviderKind};
use crate::AppState;
use futures_util::StreamExt;
use reqwest::{Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{Emitter, State};

const MAX_ERROR_BODY_BYTES: usize = 32 * 1024;
const MAX_NON_STREAM_BODY_BYTES: usize = 2 * 1024 * 1024;
const MAX_STREAM_BODY_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
struct ChatMessageContentPart {
    #[serde(rename = "type")]
    kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    image_url: Option<ImageUrl>,
}

impl ChatMessageContentPart {
    fn text(text: impl Into<String>) -> Self {
        Self {
            kind: "text".to_string(),
            text: Some(text.into()),
            image_url: None,
        }
    }

    fn jpeg(jpeg: &str) -> Self {
        Self {
            kind: "image_url".to_string(),
            text: None,
            image_url: Some(ImageUrl {
                url: format!("data:image/jpeg;base64,{jpeg}"),
            }),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ImageUrl {
    url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
enum MessageContent {
    Text(String),
    Parts(Vec<ChatMessageContentPart>),
}

#[derive(Debug, Clone, Serialize)]
struct ChatMessage {
    role: String,
    content: MessageContent,
}

impl ChatMessage {
    fn text(role: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            role: role.into(),
            content: MessageContent::Text(text.into()),
        }
    }

    fn parts(role: impl Into<String>, parts: Vec<ChatMessageContentPart>) -> Self {
        Self {
            role: role.into(),
            content: MessageContent::Parts(parts),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    store: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_completion_tokens: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
struct AIChunkEvent {
    request_id: String,
    text: String,
}

/// One question plus ephemeral page-image evidence.
#[derive(Debug, Deserialize)]
pub struct AskVisualRequest {
    pub question: String,
    pub evidence: Vec<EvidencePage>,
    /// Bounded text-only history for follow-up questions.
    pub history: Vec<HistoryTurn>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EvidencePage {
    pub page: usize,
    /// JPEG base64 without the `data:` prefix.
    pub jpeg: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HistoryTurn {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct ExtractOutlineRequest {
    pub pages: Vec<EvidencePage>,
}

#[derive(Debug, Serialize)]
pub struct OutlineResult {
    pub title: String,
    /// Keep the frontend's existing `page` contract.
    #[serde(rename = "page", alias = "printed_page")]
    pub printed_page: usize,
    pub depth: usize,
}

#[derive(Debug, Deserialize)]
pub struct FindPageRequest {
    pub title: String,
    pub pages: Vec<EvidencePage>,
}

const TEACHER_SYSTEM: &str = "你是一位耐心、讲人话的读书老师，正在陪一个底子一般的学生读教材。\
规则：\
1. 默认回答 3–6 句：先一句主线，再用大白话解释，然后把教材术语对上（书上叫 X，就是我们刚说的 Y），最后一句「所以」。\
2. 学生说「还是不懂」时，换一个角度重新讲，不要增加篇幅。\
3. 必须依据提供的页面图像；图像里看不清的内容，明确说「这页图我看不清」，绝不猜测。\
4. 如果提供了多页图像，说明内容跨页：优先看当前页，需要时对照相邻页，但回答仍要短。\
5. 不堆术语、不评判学生、不写小作文、不输出任何代码块或 Markdown 标题。";

const OUTLINE_SYSTEM: &str = "你正在读取一本中文教材的目录页图片。\
请把目录整理成 JSON 数组输出，数组元素格式：\
{\"title\": \"章节标题\", \"printed_page\": 目录中标注的印刷页码数字, \"depth\": 0 或 1}。\
规则：\
1. depth=0 表示章（如 第一章），depth=1 表示章下的小节；三级及以下归为 1。\
2. printed_page 必须是目录里印刷的页码数字，不要换算、不要猜测缺失的数字。\
3. 只输出 JSON 数组本身，不要 Markdown 代码块、不要任何解释文字。\
4. 看不清的条目跳过，宁缺毋滥。";

const FIND_PAGE_SYSTEM: &str = "你在翻阅一本书的正文页面图片。\
给你一个章节标题，以及若干候选页（每张图标注了它是 PDF 第几页）。\
请判断该章节标题（可能是「第一章」「第1章」或带标题）在哪个 PDF 页码**首次**出现。\
只输出一个数字（PDF 页码），不要任何其他文字。\
如果这些页里都没有出现该章节标题，输出 0。";

fn build_chat_request(
    profile: &ResolvedProfile,
    messages: Vec<ChatMessage>,
    stream: bool,
    token_limit: u32,
) -> ChatRequest {
    let uses_openai_tokens = profile.policy == ProviderPolicy::OpenAi;
    ChatRequest {
        model: profile.model_id.clone(),
        messages,
        stream,
        store: profile.sends_store_flag().then_some(false),
        max_tokens: (!uses_openai_tokens).then_some(token_limit),
        max_completion_tokens: uses_openai_tokens.then_some(token_limit),
    }
}

fn instruction_message(profile: &ResolvedProfile, text: &str) -> ChatMessage {
    ChatMessage::text(profile.instruction_role(), text)
}

fn evidence_parts(mut evidence: Vec<EvidencePage>, label: &str) -> Vec<ChatMessageContentPart> {
    evidence.sort_by_key(|item| item.page);
    let mut parts = Vec::with_capacity(evidence.len() * 2 + 1);
    for item in evidence {
        parts.push(ChatMessageContentPart::jpeg(&item.jpeg));
        parts.push(ChatMessageContentPart::text(format!(
            "（这是{label}第 {} 页）",
            item.page
        )));
    }
    parts
}

fn normalized_history_role(role: &str) -> &'static str {
    if role.eq_ignore_ascii_case("assistant") {
        "assistant"
    } else {
        "user"
    }
}

async fn read_api_key(
    app: &tauri::AppHandle,
    profile: &ResolvedProfile,
    allow_keychain_interaction: bool,
) -> Result<Option<String>, String> {
    if !profile.api_key_required {
        return Ok(None);
    }
    let app = app.clone();
    let profile_id = profile.id.clone();
    let expected_scope = profile.credential_scope.clone();
    let saved = tokio::task::spawn_blocking(move || {
        crate::keychain::read_profile_api_key(
            &app,
            &profile_id,
            &expected_scope,
            allow_keychain_interaction,
        )
    })
    .await
    .map_err(|error| format!("读取「{}」的 API Key 时任务失败：{error}", profile.name))?
    .map_err(|error| format!("无法读取「{}」的 API Key：{error}", profile.name))?
    .map(|key| key.trim().to_string())
    .filter(|key| !key.is_empty());
    if profile.api_key_required && saved.is_none() {
        return Err(format!("「{}」尚未配置 API Key。", profile.name));
    }
    Ok(saved)
}

async fn send_chat_request(
    client: &reqwest::Client,
    app: &tauri::AppHandle,
    profile: &ResolvedProfile,
    body: &ChatRequest,
    allow_keychain_interaction: bool,
) -> Result<Response, String> {
    let api_key = read_api_key(app, profile, allow_keychain_interaction).await?;
    let mut request = client.post(profile.chat_url.clone()).json(body);
    if let Some(api_key) = api_key.as_deref() {
        request = request.bearer_auth(api_key);
    }
    let response = request
        .send()
        .await
        .map_err(|error| format!("连接「{}」失败：{error}", profile.name))?;
    ensure_success(response, &profile.name, api_key.as_deref()).await
}

async fn ensure_success(
    response: Response,
    profile_name: &str,
    api_key: Option<&str>,
) -> Result<Response, String> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    let body = read_limited_body(response, MAX_ERROR_BODY_BYTES)
        .await
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_default();
    Err(http_error_message(profile_name, status, &body, api_key))
}

async fn read_limited_body(response: Response, limit: usize) -> Result<Vec<u8>, String> {
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("读取 AI 响应失败：{error}"))?;
        if body.len().saturating_add(chunk.len()) > limit {
            return Err("AI 响应过大，已停止读取。".to_string());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn http_error_message(
    profile_name: &str,
    status: StatusCode,
    body: &str,
    api_key: Option<&str>,
) -> String {
    let detail = extract_error_message(body, api_key)
        .unwrap_or_else(|| status.canonical_reason().unwrap_or("请求失败").to_string());
    format!("「{profile_name}」返回 HTTP {}：{detail}", status.as_u16())
}

fn extract_error_message(body: &str, api_key: Option<&str>) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    let candidate = value
        .pointer("/error/message")
        .or_else(|| value.get("message"))
        .or_else(|| value.get("detail"))
        .or_else(|| value.get("error"))?
        .as_str()?;
    sanitize_server_message(candidate, api_key)
}

fn sanitize_server_message(message: &str, api_key: Option<&str>) -> Option<String> {
    let redacted = api_key.filter(|secret| !secret.is_empty()).map_or_else(
        || message.to_string(),
        |secret| message.replace(secret, "[已隐藏]"),
    );
    let mut cleaned = String::new();
    let mut previous_was_space = false;
    for character in redacted.chars() {
        let normalized = if character.is_control() {
            ' '
        } else {
            character
        };
        if normalized.is_whitespace() {
            if !previous_was_space {
                cleaned.push(' ');
            }
            previous_was_space = true;
        } else {
            cleaned.push(normalized);
            previous_was_space = false;
        }
        if cleaned.chars().count() >= 240 {
            break;
        }
    }
    let cleaned = cleaned.trim();
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

fn content_value_to_text(content: &Value) -> Option<String> {
    match content {
        Value::String(text) => (!text.is_empty()).then(|| text.clone()),
        Value::Array(parts) => {
            let text = parts
                .iter()
                .filter_map(|part| match part {
                    Value::String(text) => Some(text.as_str()),
                    Value::Object(object) => object.get("text").and_then(Value::as_str),
                    _ => None,
                })
                .collect::<String>();
            (!text.is_empty()).then_some(text)
        }
        _ => None,
    }
}

fn extract_delta_text(payload: &str) -> Option<String> {
    let value: Value = serde_json::from_str(payload).ok()?;
    content_value_to_text(value.pointer("/choices/0/delta/content")?)
}

fn extract_non_stream_content(value: &Value) -> Option<String> {
    value
        .pointer("/choices/0/message/content")
        .and_then(content_value_to_text)
        .or_else(|| {
            value
                .pointer("/choices/0/text")
                .and_then(content_value_to_text)
        })
}

#[derive(Debug, Default)]
struct SseDecoder {
    buffer: Vec<u8>,
    event_data: Vec<String>,
    done: bool,
}

impl SseDecoder {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>, String> {
        if self.done {
            return Ok(Vec::new());
        }
        self.buffer.extend_from_slice(bytes);
        let mut output = Vec::new();
        while let Some(newline) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=newline).collect();
            output.extend(self.parse_line(&line)?);
            if self.done {
                self.buffer.clear();
                self.event_data.clear();
                break;
            }
        }
        Ok(output)
    }

    fn finish(&mut self) -> Result<Vec<String>, String> {
        if self.done {
            return Ok(Vec::new());
        }
        let mut output = Vec::new();
        if !self.buffer.is_empty() {
            let tail = std::mem::take(&mut self.buffer);
            output.extend(self.parse_line(&tail)?);
        }
        output.extend(self.flush_event());
        Ok(output)
    }

    fn parse_line(&mut self, line: &[u8]) -> Result<Vec<String>, String> {
        let line = std::str::from_utf8(line)
            .map_err(|_| "AI 响应包含无效的 UTF-8 文本。".to_string())?
            .trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            return Ok(self.flush_event());
        }
        let Some(payload) = line.strip_prefix("data:") else {
            return Ok(Vec::new());
        };
        let payload = payload.strip_prefix(' ').unwrap_or(payload);

        let mut output = Vec::new();
        // Some compatible servers omit the blank SSE event separator but send
        // one complete JSON object per data line. Preserve compatibility while
        // still supporting standards-compliant multiline data events.
        if self.pending_event_is_complete() {
            output.extend(self.flush_event());
        }
        self.event_data.push(payload.to_string());
        Ok(output)
    }

    fn pending_event_is_complete(&self) -> bool {
        if self.event_data.is_empty() {
            return false;
        }
        let payload = self.event_data.join("\n");
        payload.trim() == "[DONE]" || serde_json::from_str::<Value>(&payload).is_ok()
    }

    fn flush_event(&mut self) -> Vec<String> {
        if self.event_data.is_empty() {
            return Vec::new();
        }
        let payload = std::mem::take(&mut self.event_data).join("\n");
        let payload = payload.trim();
        if payload == "[DONE]" {
            self.done = true;
            return Vec::new();
        }
        extract_delta_text(payload).into_iter().collect()
    }
}

async fn collect_stream(
    response: Response,
    app: &tauri::AppHandle,
    request_id: &str,
) -> Result<String, String> {
    let mut response_stream = response.bytes_stream();
    let mut decoder = SseDecoder::default();
    let mut full_text = String::new();
    let mut received_bytes = 0usize;

    while let Some(chunk) = response_stream.next().await {
        let chunk = chunk.map_err(|error| format!("读取 AI 响应失败：{error}"))?;
        received_bytes = received_bytes.saturating_add(chunk.len());
        if received_bytes > MAX_STREAM_BODY_BYTES {
            return Err("AI 流式响应过大，已停止读取。".to_string());
        }
        for text in decoder.push(&chunk)? {
            full_text.push_str(&text);
            let _ = app.emit(
                "ai://chunk",
                AIChunkEvent {
                    request_id: request_id.to_string(),
                    text,
                },
            );
        }
        if decoder.done {
            break;
        }
    }
    for text in decoder.finish()? {
        full_text.push_str(&text);
        let _ = app.emit(
            "ai://chunk",
            AIChunkEvent {
                request_id: request_id.to_string(),
                text,
            },
        );
    }

    if full_text.trim().is_empty() {
        Err("AI 没有返回可显示的内容。".to_string())
    } else {
        Ok(full_text)
    }
}

async fn parse_non_stream_response(response: Response) -> Result<String, String> {
    let body = read_limited_body(response, MAX_NON_STREAM_BODY_BYTES).await?;
    let value =
        serde_json::from_slice::<Value>(&body).map_err(|_| "无法解析 AI 响应。".to_string())?;
    extract_non_stream_content(&value)
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| "AI 没有返回可显示的内容。".to_string())
}

#[tauri::command]
pub async fn ask_visual(
    state: State<'_, AppState>,
    app: tauri::AppHandle,
    profile_id: String,
    request_id: String,
    request: AskVisualRequest,
) -> Result<String, String> {
    let profile = load_ai_profile(&app, &profile_id)?;
    let profile = resolve_profile(&profile)?;
    let mut messages = vec![instruction_message(&profile, TEACHER_SYSTEM)];

    for turn in request.history.iter().take(6) {
        messages.push(ChatMessage::text(
            normalized_history_role(&turn.role),
            turn.content.clone(),
        ));
    }

    let mut user_parts = evidence_parts(request.evidence, "书内");
    user_parts.push(ChatMessageContentPart::text(request.question));
    messages.push(ChatMessage::parts("user", user_parts));

    let body = build_chat_request(&profile, messages, true, 900);
    let response = send_chat_request(
        state.ai_client(profile.is_local),
        &app,
        &profile,
        &body,
        true,
    )
    .await?;
    collect_stream(response, &app, &request_id).await
}

#[tauri::command]
pub async fn extract_outline(
    state: State<'_, AppState>,
    app: tauri::AppHandle,
    profile_id: String,
    request: ExtractOutlineRequest,
) -> Result<Vec<OutlineResult>, String> {
    let profile = load_ai_profile(&app, &profile_id)?;
    let profile = resolve_profile(&profile)?;
    let mut user_parts = evidence_parts(request.pages, "PDF ");
    user_parts.push(ChatMessageContentPart::text(
        "请读取这些目录页并输出 JSON 数组目录。",
    ));
    let messages = vec![
        instruction_message(&profile, OUTLINE_SYSTEM),
        ChatMessage::parts("user", user_parts),
    ];
    let body = build_chat_request(&profile, messages, false, 3000);
    let response = send_chat_request(
        state.ai_client(profile.is_local),
        &app,
        &profile,
        &body,
        false,
    )
    .await?;
    let content = parse_non_stream_response(response).await?;
    parse_outline_content(&content)
}

#[tauri::command]
pub async fn find_page_by_title(
    state: State<'_, AppState>,
    app: tauri::AppHandle,
    profile_id: String,
    request: FindPageRequest,
) -> Result<usize, String> {
    let profile = load_ai_profile(&app, &profile_id)?;
    let profile = resolve_profile(&profile)?;
    let mut user_parts = evidence_parts(request.pages, "PDF ");
    user_parts.push(ChatMessageContentPart::text(format!(
        "章节标题：{}。它首次出现在哪个 PDF 页码？只输出数字。",
        request.title
    )));
    let messages = vec![
        instruction_message(&profile, FIND_PAGE_SYSTEM),
        ChatMessage::parts("user", user_parts),
    ];
    let body = build_chat_request(&profile, messages, false, 200);
    let response = send_chat_request(
        state.ai_client(profile.is_local),
        &app,
        &profile,
        &body,
        false,
    )
    .await?;
    let content = parse_non_stream_response(response).await?;
    Ok(parse_page_number(&content))
}

/// Test credentials, endpoint, model and image input with a built-in 1 × 1
/// JPEG. No book page or learning history is included.
#[tauri::command]
pub async fn test_ai_profile(
    state: State<'_, AppState>,
    app: tauri::AppHandle,
    profile_id: String,
) -> Result<String, String> {
    let profile = load_ai_profile(&app, &profile_id)?;
    let profile = resolve_profile(&profile)?;
    let messages = vec![
        instruction_message(
            &profile,
            "你正在验证一个 AI 连接。请严格按用户要求简短回复。",
        ),
        ChatMessage::parts(
            "user",
            vec![
                // 1 × 1 white JPEG. It contains no book or user data and makes
                // the connection test exercise the image-input contract.
                ChatMessageContentPart::jpeg("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EP/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Q/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxB//9k="),
                ChatMessageContentPart::text("这是一张测试图片。只回复 OK。"),
            ],
        ),
    ];
    let body = build_chat_request(&profile, messages, false, 64);
    let response = send_chat_request(
        state.ai_client(profile.is_local),
        &app,
        &profile,
        &body,
        true,
    )
    .await?;
    parse_non_stream_response(response).await
}

fn parse_outline_content(content: &str) -> Result<Vec<OutlineResult>, String> {
    let cleaned = content
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    let parsed: Value =
        serde_json::from_str(cleaned).map_err(|_| "模型未返回有效的目录 JSON。".to_string())?;
    let array = parsed
        .as_array()
        .ok_or_else(|| "目录不是 JSON 数组。".to_string())?;

    let mut output = Vec::new();
    for item in array {
        let title = item
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        let printed_page = item
            .get("printed_page")
            .and_then(Value::as_u64)
            .unwrap_or(0) as usize;
        let depth = item.get("depth").and_then(Value::as_u64).unwrap_or(0) as usize;
        if !title.is_empty() && printed_page > 0 {
            output.push(OutlineResult {
                title,
                printed_page,
                depth: depth.min(1),
            });
        }
    }
    Ok(output)
}

fn parse_page_number(content: &str) -> usize {
    content
        .trim()
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    fn built_in_profiles_force_official_urls() {
        let model_studio = resolve_profile(&profile(
            AIProviderKind::ModelStudio,
            "https://attacker.invalid/v1",
            true,
        ))
        .unwrap();
        assert_eq!(
            model_studio.chat_url.as_str(),
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        );

        let openai = resolve_profile(&profile(
            AIProviderKind::OpenAi,
            "https://attacker.invalid/v1",
            true,
        ))
        .unwrap();
        assert_eq!(
            openai.chat_url.as_str(),
            "https://api.openai.com/v1/chat/completions"
        );
    }

    #[test]
    fn custom_url_is_normalized_without_duplicate_path() {
        let (url, local) = normalize_chat_url("https://example.com/v1/", true).unwrap();
        assert_eq!(url.as_str(), "https://example.com/v1/chat/completions");
        assert!(!local);

        let (url, _) =
            normalize_chat_url("https://example.com/v1/chat/completions/", true).unwrap();
        assert_eq!(url.as_str(), "https://example.com/v1/chat/completions");
    }

    #[test]
    fn custom_url_allows_only_secure_remote_or_loopback_http() {
        for accepted in [
            "https://example.com/v1",
            "http://localhost:11434/v1",
            "http://127.0.0.1:8080/v1",
            "http://[::1]:8080/v1",
        ] {
            assert!(normalize_chat_url(accepted, true).is_ok(), "{accepted}");
        }
        for rejected in [
            "http://example.com/v1",
            "http://127.0.0.2:8080/v1",
            "file:///tmp/model",
            "ftp://example.com/v1",
            "https://user:secret@example.com/v1",
            "https://example.com/v1?key=secret",
            "https://example.com/v1#fragment",
        ] {
            assert!(normalize_chat_url(rejected, true).is_err(), "{rejected}");
        }
    }

    #[test]
    fn request_body_uses_provider_specific_fields() {
        let openai = resolve_profile(&profile(AIProviderKind::OpenAi, "", true)).unwrap();
        let body = build_chat_request(
            &openai,
            vec![instruction_message(&openai, "instruction")],
            false,
            42,
        );
        let value = serde_json::to_value(body).unwrap();
        assert_eq!(value["messages"][0]["role"], "developer");
        assert_eq!(value["store"], false);
        assert_eq!(value["max_completion_tokens"], 42);
        assert!(value.get("max_tokens").is_none());

        let model_studio =
            resolve_profile(&profile(AIProviderKind::ModelStudio, "", true)).unwrap();
        let value = serde_json::to_value(build_chat_request(
            &model_studio,
            vec![instruction_message(&model_studio, "instruction")],
            false,
            43,
        ))
        .unwrap();
        assert_eq!(value["messages"][0]["role"], "system");
        assert_eq!(value["store"], false);
        assert_eq!(value["max_tokens"], 43);
        assert!(value.get("max_completion_tokens").is_none());

        let local = resolve_profile(&profile(
            AIProviderKind::OpenAiCompatible,
            "http://localhost:11434/v1",
            false,
        ))
        .unwrap();
        let value = serde_json::to_value(build_chat_request(
            &local,
            vec![instruction_message(&local, "instruction")],
            false,
            44,
        ))
        .unwrap();
        assert!(value.get("store").is_none());
        assert_eq!(value["max_tokens"], 44);
        assert!(!local.api_key_required);

        let remote = resolve_profile(&profile(
            AIProviderKind::OpenAiCompatible,
            "https://proxy.example/v1",
            false,
        ))
        .unwrap();
        let value = serde_json::to_value(build_chat_request(
            &remote,
            vec![instruction_message(&remote, "instruction")],
            false,
            45,
        ))
        .unwrap();
        assert_eq!(value["store"], false);
        assert!(!remote.api_key_required);
    }

    #[test]
    fn sse_decoder_preserves_split_utf8_and_content_arrays() {
        let wire = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\r\n\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":[{\"type\":\"text\",\"text\":\"世界\"}]}}]}\n\n",
            "data: [DONE]"
        );
        let mut decoder = SseDecoder::default();
        let mut output = Vec::new();
        for byte in wire.as_bytes().chunks(1) {
            output.extend(decoder.push(byte).unwrap());
        }
        output.extend(decoder.finish().unwrap());
        assert_eq!(output.concat(), "你好世界");
        assert!(decoder.done);
    }

    #[test]
    fn sse_decoder_joins_multiline_data_events() {
        let wire = concat!(
            "data: {\"choices\":[{\"delta\":\n",
            "data: {\"content\":\"多行\"}}]}\n\n",
            "data: [DONE]\n\n"
        );
        let mut decoder = SseDecoder::default();
        let output = decoder.push(wire.as_bytes()).unwrap();
        assert_eq!(output.concat(), "多行");
        assert!(decoder.done);
    }

    #[test]
    fn safe_error_and_non_stream_content_parsing() {
        let error = http_error_message(
            "测试连接",
            StatusCode::UNAUTHORIZED,
            r#"{"error":{"message":"bad\ncredential key=test-secret"},"private":"do-not-show"}"#,
            Some("test-secret"),
        );
        assert_eq!(
            error,
            "「测试连接」返回 HTTP 401：bad credential key=[已隐藏]"
        );
        assert!(!error.contains("test-secret"));
        assert!(!error.contains("do-not-show"));

        let fallback = http_error_message(
            "测试连接",
            StatusCode::BAD_GATEWAY,
            "<html>secret upstream body</html>",
            None,
        );
        assert_eq!(fallback, "「测试连接」返回 HTTP 502：Bad Gateway");
        assert!(!fallback.contains("secret upstream body"));

        let string_body = json!({"choices":[{"message":{"content":"OK"}}]});
        assert_eq!(
            extract_non_stream_content(&string_body).as_deref(),
            Some("OK")
        );
        let array_body = json!({
            "choices":[{"message":{"content":[
                {"type":"text","text":"你"},
                {"type":"text","text":"好"}
            ]}}]
        });
        assert_eq!(
            extract_non_stream_content(&array_body).as_deref(),
            Some("你好")
        );
    }

    #[test]
    fn outline_cleanup_preserves_existing_behavior() {
        let content = r#"```json
        [
          {"title":" 第一章 绪论 ","printed_page":3,"depth":0},
          {"title":"1.1 背景","printed_page":4,"depth":8},
          {"title":"","printed_page":5,"depth":0},
          {"title":"没有页码","printed_page":0,"depth":0}
        ]
        ```"#;
        let outline = parse_outline_content(content).unwrap();
        assert_eq!(outline.len(), 2);
        assert_eq!(outline[0].title, "第一章 绪论");
        assert_eq!(outline[0].printed_page, 3);
        assert_eq!(outline[0].depth, 0);
        assert_eq!(outline[1].depth, 1);

        let serialized = serde_json::to_value(&outline[0]).unwrap();
        assert_eq!(serialized["page"], 3);
        assert!(serialized.get("printed_page").is_none());
    }
}
