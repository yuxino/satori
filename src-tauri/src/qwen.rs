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
