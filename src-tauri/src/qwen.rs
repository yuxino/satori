//! 百炼 Qwen 视觉理解客户端。页面图像直接作为证据发送，
//! 不做 OCR。使用 Model Studio 北京共享地址 + OpenAI 兼容接口，
//! 流式返回，`store: false` 不保存对话内容。

use crate::AppState;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tauri::{Emitter, State};

const API_BASE: &str = "https://dashscope.aliyuncs.com/compatible-mode/v1";
const CHAT_PATH: &str = "/chat/completions";

#[derive(Debug, Clone, Serialize)]
struct ChatMessageContentPart {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
    image_url: Option<ImageURL>,
}

#[derive(Debug, Clone, Serialize)]
struct ImageURL {
    url: String,
}

#[derive(Debug, Clone, Serialize)]
struct ChatMessage {
    role: String,
    content: Vec<ChatMessageContentPart>,
}

#[derive(Debug, Clone, Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<ChatMessage>,
    stream: bool,
    store: bool,
    max_tokens: u32,
}

#[derive(Debug, Deserialize)]
struct ChatChunk {
    choices: Vec<ChunkChoice>,
}

#[derive(Debug, Deserialize)]
struct ChunkChoice {
    delta: Delta,
}

#[derive(Debug, Deserialize, Default)]
struct Delta {
    #[serde(default)]
    content: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ChatErrorBody {
    error: Option<ApiError>,
}

#[derive(Debug, Deserialize)]
struct ApiError {
    message: Option<String>,
}

/// 一次提问的入参：问题 + 页面图像证据（可多页，每页标注页码）。
/// 图像是本次请求的临时上下文，不落盘。
#[derive(Debug, Deserialize)]
pub struct AskVisualRequest {
    pub model: String,
    pub question: String,
    /// 证据页：页码 + 该页渲染成的 JPEG base64（不含 data: 前缀）。
    pub evidence: Vec<EvidencePage>,
    /// 简短的历史轮次（角色 + 文本），用于追问；不含图像。
    pub history: Vec<HistoryTurn>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EvidencePage {
    pub page: usize,
    pub jpeg: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HistoryTurn {
    pub role: String,
    pub content: String,
}

/// 老师讲法：默认 3–6 句、先主线后术语、必须引用页面图像、不猜。
const TEACHER_SYSTEM: &str = "你是一位耐心、讲人话的读书老师，正在陪一个底子一般的学生读教材。\
规则：\
1. 默认回答 3–6 句：先一句主线，再用大白话解释，然后把教材术语对上（书上叫 X，就是我们刚说的 Y），最后一句「所以」。\
2. 学生说「还是不懂」时，换一个角度重新讲，不要增加篇幅。\
3. 必须依据提供的页面图像；图像里看不清的内容，明确说「这页图我看不清」，绝不猜测。\
4. 如果提供了多页图像，说明内容跨页：优先看当前页，需要时对照相邻页，但回答仍要短。\
5. 不堆术语、不评判学生、不写小作文、不输出任何代码块或 Markdown 标题。";

#[tauri::command]
pub async fn ask_visual(
    state: State<'_, AppState>,
    app: tauri::AppHandle,
    api_key: String,
    request: AskVisualRequest,
) -> Result<String, String> {
    let mut messages = vec![ChatMessage {
        role: "system".to_string(),
        content: vec![ChatMessageContentPart {
            kind: "text".to_string(),
            text: Some(TEACHER_SYSTEM.to_string()),
            image_url: None,
        }],
    }];

    // 简短的追问历史（纯文本）。
    for turn in request.history.iter().take(6) {
        messages.push(ChatMessage {
            role: turn.role.clone(),
            content: vec![ChatMessageContentPart {
                kind: "text".to_string(),
                text: Some(turn.content.clone()),
                image_url: None,
            }],
        });
    }

    // 用户提问 + 页面图像证据。多页时按页码排序并标注，让模型知道
    // 每张图对应书里哪一页，跨页内容可以跨图对照。
    let mut evidence = request.evidence.clone();
    evidence.sort_by_key(|e| e.page);

    let mut user_parts = Vec::new();
    for page_evidence in &evidence {
        // 图片先于页码文字到达模型，顺序与页码一致。
        user_parts.push(ChatMessageContentPart {
            kind: "image_url".to_string(),
            text: None,
            image_url: Some(ImageURL {
                url: format!("data:image/jpeg;base64,{}", page_evidence.jpeg),
            }),
        });
        user_parts.push(ChatMessageContentPart {
            kind: "text".to_string(),
            text: Some(format!("（这是书内第 {} 页）", page_evidence.page)),
            image_url: None,
        });
    }
    user_parts.push(ChatMessageContentPart {
        kind: "text".to_string(),
        text: Some(request.question.clone()),
        image_url: None,
    });
    messages.push(ChatMessage {
        role: "user".to_string(),
        content: user_parts,
    });

    let body = ChatRequest {
        model: request.model,
        messages,
        stream: true,
        store: false,
        max_tokens: 900,
    };

    let url = format!("{API_BASE}{CHAT_PATH}");
    let response = state
        .client
        .post(&url)
        .header("Authorization", format!("Bearer {api_key}"))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("连接百炼失败：{e}"))?;

    let status = response.status();
    if !status.is_success() {
        let status_text = status.as_u16();
        // 尝试解析错误体里的 message，方便用户诊断。
        let body = response.text().await.unwrap_or_default();
        let detail = serde_json::from_str::<ChatErrorBody>(&body)
            .ok()
            .and_then(|b| b.error)
            .and_then(|e| e.message)
            .unwrap_or_default();
        return Err(format!("百炼返回 {status_text}：{detail}"));
    }

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut full_text = String::new();
    let mut done = false;

    'outer: while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("读取响应失败：{e}"))?;
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        // SSE 行以 \n 分隔；逐行解析 data: JSON。
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            if !line.starts_with("data:") {
                continue;
            }
            let payload = line[5..].trim();
            if payload == "[DONE]" {
                done = true;
                break;
            }
            if let Ok(parsed) = serde_json::from_str::<ChatChunk>(payload) {
                if let Some(content) = parsed.choices.first().and_then(|c| c.delta.content.clone()) {
                    full_text.push_str(&content);
                    // 每段增量发给前端，形成流式输出。
                    let _ = app.emit("qwen://chunk", content);
                }
            }
        }
        if done {
            break 'outer;
        }
    }

    let _ = app.emit("qwen://done", &full_text);
    Ok(full_text)
}

// ---- 扫描书目录恢复：让 Qwen 读目录页，返回结构化 JSON ----

/// 扫描书目录提取入参：目录页图片（前若干页）。
#[derive(Debug, Deserialize)]
pub struct ExtractOutlineRequest {
    pub model: String,
    /// 目录页图片（JPEG base64），带 PDF 页码。
    pub pages: Vec<EvidencePage>,
}

/// 返回的目录条目（Qwen 解析后）。
#[derive(Debug, Serialize)]
pub struct OutlineResult {
    pub title: String,
    /// 书内印刷页码（目录里写的那种页码）。序列化为 `page`，
    /// 与前端 OutlineEntry 字段对齐（否则前端读到 undefined → NaN）。
    #[serde(rename = "page", alias = "printed_page")]
    pub printed_page: usize,
    pub depth: usize,
}

/// 系统提示：让模型输出纯 JSON 目录数组。
const OUTLINE_SYSTEM: &str = "你正在读取一本中文教材的目录页图片。\
请把目录整理成 JSON 数组输出，数组元素格式：\
{\"title\": \"章节标题\", \"printed_page\": 目录中标注的印刷页码数字, \"depth\": 0 或 1}。\
规则：\
1. depth=0 表示章（如 第一章），depth=1 表示章下的小节；三级及以下归为 1。\
2. printed_page 必须是目录里印刷的页码数字，不要换算、不要猜测缺失的数字。\
3. 只输出 JSON 数组本身，不要 Markdown 代码块、不要任何解释文字。\
4. 看不清的条目跳过，宁缺毋滥。";

#[tauri::command]
pub async fn extract_outline(
    state: State<'_, AppState>,
    api_key: String,
    request: ExtractOutlineRequest,
) -> Result<Vec<OutlineResult>, String> {
    let mut user_parts = Vec::new();
    // 目录页可能跨多页，按顺序给模型，并标注每张图的 PDF 页码。
    let mut pages = request.pages.clone();
    pages.sort_by_key(|p| p.page);
    for p in &pages {
        user_parts.push(ChatMessageContentPart {
            kind: "image_url".to_string(),
            text: None,
            image_url: Some(ImageURL {
                url: format!("data:image/jpeg;base64,{}", p.jpeg),
            }),
        });
        user_parts.push(ChatMessageContentPart {
            kind: "text".to_string(),
            text: Some(format!("（这是 PDF 第 {} 页）", p.page)),
            image_url: None,
        });
    }
    user_parts.push(ChatMessageContentPart {
        kind: "text".to_string(),
        text: Some("请读取这些目录页并输出 JSON 数组目录。".to_string()),
        image_url: None,
    });

    let body = ChatRequest {
        model: request.model,
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: vec![ChatMessageContentPart {
                    kind: "text".to_string(),
                    text: Some(OUTLINE_SYSTEM.to_string()),
                    image_url: None,
                }],
            },
            ChatMessage {
                role: "user".to_string(),
                content: user_parts,
            },
        ],
        stream: false,
        store: false,
        max_tokens: 3000,
    };

    let url = format!("{API_BASE}{CHAT_PATH}");
    let response = state
        .client
        .post(&url)
        .header("Authorization", format!("Bearer {api_key}"))
        .json(&body)
        .send()
        .await
        .map_err(|e| {
            crate::debug_log(&format!("extract_outline send failed: {e}"));
            format!("连接百炼失败：{e}")
        })?;

    let status = response.status();
    if !status.is_success() {
        let status_text = status.as_u16();
        let body = response.text().await.unwrap_or_default();
        crate::debug_log(&format!("extract_outline HTTP {status_text}: {}", &body[..body.len().min(200)]));
        let detail = serde_json::from_str::<ChatErrorBody>(&body)
            .ok()
            .and_then(|b| b.error)
            .and_then(|e| e.message)
            .unwrap_or_default();
        return Err(format!("百炼返回 {status_text}：{detail}"));
    }

    // 非流式：直接解析返回的完整 JSON。
    let body = response
        .json::<serde_json::Value>()
        .await
        .map_err(|e| {
            crate::debug_log(&format!("extract_outline json parse failed: {e}"));
            format!("解析响应失败：{e}")
        })?;
    let content = body
        .pointer("/choices/0/message/content")
        .and_then(|c| c.as_str())
        .unwrap_or_default();

    // 模型可能包了 ```json 代码块，剥掉。
    let cleaned = content
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    let parsed: serde_json::Value = serde_json::from_str(cleaned).map_err(|e| {
        crate::debug_log(&format!(
            "extract_outline JSON parse failed: {e}; cleaned head: {}",
            &cleaned[..cleaned.len().min(500)]
        ));
        format!("模型未返回有效 JSON：{content}")
    })?;
    let array = parsed.as_array().ok_or("目录不是 JSON 数组")?;

    let mut out = Vec::new();
    for item in array {
        let title = item.get("title").and_then(|t| t.as_str()).unwrap_or("").trim().to_string();
        let printed = item.get("printed_page").and_then(|p| p.as_u64()).unwrap_or(0) as usize;
        let depth = item.get("depth").and_then(|d| d.as_u64()).unwrap_or(0) as usize;
        if !title.is_empty() && printed > 0 {
            out.push(OutlineResult { title, printed_page: printed, depth: depth.min(1) });
        }
    }
    Ok(out)
}

/// 在候选正文页里定位某个章节标题，返回它首次出现的 PDF 页码。
/// 用于把目录里的印刷页码换算成 PDF 页码（校正前置页偏移）。
#[derive(Debug, Deserialize)]
pub struct FindPageRequest {
    pub model: String,
    /// 章节标题（如「第一章 软件工程概述」）。
    pub title: String,
    /// 候选正文页图片（JPEG base64，带 PDF 页码）。
    pub pages: Vec<EvidencePage>,
}

const FIND_PAGE_SYSTEM: &str = "你在翻阅一本书的正文页面图片。\
给你一个章节标题，以及若干候选页（每张图标注了它是 PDF 第几页）。\
请判断该章节标题（可能是「第一章」「第1章」或带标题）在哪个 PDF 页码**首次**出现。\
只输出一个数字（PDF 页码），不要任何其他文字。\
如果这些页里都没有出现该章节标题，输出 0。";

#[tauri::command]
pub async fn find_page_by_title(
    state: State<'_, AppState>,
    api_key: String,
    request: FindPageRequest,
) -> Result<usize, String> {
    let mut user_parts = Vec::new();
    let mut pages = request.pages.clone();
    pages.sort_by_key(|p| p.page);
    for p in &pages {
        user_parts.push(ChatMessageContentPart {
            kind: "image_url".to_string(),
            text: None,
            image_url: Some(ImageURL {
                url: format!("data:image/jpeg;base64,{}", p.jpeg),
            }),
        });
        user_parts.push(ChatMessageContentPart {
            kind: "text".to_string(),
            text: Some(format!("（这是 PDF 第 {} 页）", p.page)),
            image_url: None,
        });
    }
    user_parts.push(ChatMessageContentPart {
        kind: "text".to_string(),
        text: Some(format!("章节标题：{}。它首次出现在哪个 PDF 页码？只输出数字。", request.title)),
        image_url: None,
    });

    let body = ChatRequest {
        model: request.model,
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: vec![ChatMessageContentPart {
                    kind: "text".to_string(),
                    text: Some(FIND_PAGE_SYSTEM.to_string()),
                    image_url: None,
                }],
            },
            ChatMessage {
                role: "user".to_string(),
                content: user_parts,
            },
        ],
        stream: false,
        store: false,
        max_tokens: 200,
    };

    let url = format!("{API_BASE}{CHAT_PATH}");
    let response = state
        .client
        .post(&url)
        .header("Authorization", format!("Bearer {api_key}"))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("连接百炼失败：{e}"))?;
    let status = response.status();
    if !status.is_success() {
        let status_text = status.as_u16();
        let body = response.text().await.unwrap_or_default();
        let detail = serde_json::from_str::<ChatErrorBody>(&body)
            .ok()
            .and_then(|b| b.error)
            .and_then(|e| e.message)
            .unwrap_or_default();
        return Err(format!("百炼返回 {status_text}：{detail}"));
    }

    let body = response
        .json::<serde_json::Value>()
        .await
        .map_err(|e| format!("解析响应失败：{e}"))?;
    let content = body
        .pointer("/choices/0/message/content")
        .and_then(|c| c.as_str())
        .unwrap_or_default();
    let num: usize = content
        .trim()
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0);
    Ok(num)
}
