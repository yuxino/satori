// 轻量 Markdown 渲染：把 AI 回答的 Markdown 转成排版后的 DOM。
// 用 DOM API 构建而非 innerHTML，避免注入风险。
// 支持：标题 / 无序有序列表 / 代码块 / 行内代码 / 粗斜体 / 引用 / 链接 / 段落。

import { safeExternalHref } from "./link-policy";

/** 渲染一段 Markdown 文本，返回可挂载的 DocumentFragment。 */
export function renderMarkdown(text: string): DocumentFragment {
  const frag = document.createDocumentFragment();
  const lines = text.replace(/\r\n/g, "\n").split("\n");

  let listType: "ul" | "ol" | null = null;
  let listEl: HTMLElement | null = null;
  let paraEl: HTMLElement | null = null;
  let inCodeBlock = false;
  let codeBuf: string[] = [];

  function flushPara() {
    if (paraEl) {
      frag.appendChild(paraEl);
      paraEl = null;
    }
  }
  function flushList() {
    if (listEl) {
      frag.appendChild(listEl);
      listEl = null;
      listType = null;
    }
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // 代码块：``` 开头/结束
    if (line.trim().startsWith("```")) {
      if (inCodeBlock) {
        const pre = document.createElement("pre");
        const code = document.createElement("code");
        code.textContent = codeBuf.join("\n");
        pre.appendChild(code);
        frag.appendChild(pre);
        codeBuf = [];
        inCodeBlock = false;
      } else {
        flushPara();
        flushList();
        inCodeBlock = true;
        codeBuf = [];
      }
      continue;
    }
    if (inCodeBlock) {
      codeBuf.push(line);
      continue;
    }

    const trimmed = line.trim();

    // 空行：结束当前段落/列表
    if (trimmed === "") {
      flushPara();
      flushList();
      continue;
    }

    // 标题
    const heading = /^(#{1,3})\s+(.*)$/.exec(trimmed);
    if (heading) {
      flushPara();
      flushList();
      const h = document.createElement(`h${heading[1].length}` as "h1" | "h2" | "h3");
      appendInline(h, heading[2]);
      frag.appendChild(h);
      continue;
    }

    // 引用
    if (trimmed.startsWith(">")) {
      flushPara();
      flushList();
      const blockquote = document.createElement("blockquote");
      appendInline(blockquote, trimmed.replace(/^>\s?/, ""));
      frag.appendChild(blockquote);
      continue;
    }

    // 无序列表
    const ul = /^[-*]\s+(.*)$/.exec(trimmed);
    if (ul) {
      flushPara();
      if (listType !== "ul" || !listEl) {
        flushList();
        listEl = document.createElement("ul");
        listType = "ul";
        frag.appendChild(listEl);
      }
      const li = document.createElement("li");
      appendInline(li, ul[1]);
      listEl.appendChild(li);
      continue;
    }

    // 有序列表
    const ol = /^\d+[.)]\s+(.*)$/.exec(trimmed);
    if (ol) {
      flushPara();
      if (listType !== "ol" || !listEl) {
        flushList();
        listEl = document.createElement("ol");
        listType = "ol";
        frag.appendChild(listEl);
      }
      const li = document.createElement("li");
      appendInline(li, ol[1]);
      listEl.appendChild(li);
      continue;
    }

    // 普通段落（合并连续行）
    flushList();
    if (!paraEl) {
      paraEl = document.createElement("p");
    }
    if (paraEl.childNodes.length > 0) {
      paraEl.appendChild(document.createElement("br"));
    }
    appendInline(paraEl, line);
  }

  if (inCodeBlock && codeBuf.length > 0) {
    const pre = document.createElement("pre");
    const code = document.createElement("code");
    code.textContent = codeBuf.join("\n");
    pre.appendChild(code);
    frag.appendChild(pre);
  }
  flushPara();
  flushList();
  return frag;
}

/** 行内格式：粗体 / 斜体 / 行内代码 / 链接。 */
function appendInline(parent: HTMLElement, text: string): void {
  // 分段处理：行内代码优先切分，避免破坏其他格式。
  const parts = text.split(/(`[^`]+`)/g);
  for (const part of parts) {
    if (part.startsWith("`") && part.endsWith("`") && part.length > 2) {
      const code = document.createElement("code");
      code.className = "inline-code";
      code.textContent = part.slice(1, -1);
      parent.appendChild(code);
      continue;
    }
    // 链接 [文字](url)
    const linkRe = /\[([^\]]+)\]\(([^)\s]+)\)/g;
    let lastIndex = 0;
    let match: RegExpExecArray | null;
    let hasLink = false;
    while ((match = linkRe.exec(part)) !== null) {
      hasLink = true;
      if (match.index > lastIndex) {
        appendBoldItalic(parent, part.slice(lastIndex, match.index));
      }
      const href = safeExternalHref(match[2]);
      if (href) {
        const a = document.createElement("a");
        a.textContent = match[1];
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        parent.appendChild(a);
      } else {
        parent.appendChild(document.createTextNode(match[1]));
      }
      lastIndex = match.index + match[0].length;
    }
    if (!hasLink) {
      appendBoldItalic(parent, part);
    } else if (lastIndex < part.length) {
      appendBoldItalic(parent, part.slice(lastIndex));
    }
  }
}

/** 粗体 / 斜体（可嵌套粗体含斜体）。 */
function appendBoldItalic(parent: HTMLElement, text: string): void {
  const boldRe = /\*\*([^*]+)\*\*/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = boldRe.exec(text)) !== null) {
    if (match.index > lastIndex) {
      appendItalic(parent, text.slice(lastIndex, match.index));
    }
    const strong = document.createElement("strong");
    appendItalic(strong, match[1]);
    parent.appendChild(strong);
    lastIndex = match.index + match[0].length;
  }
  appendItalic(parent, text.slice(lastIndex));
}

function appendItalic(parent: HTMLElement, text: string): void {
  const italicRe = /\*([^*]+)\*/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = italicRe.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parent.appendChild(document.createTextNode(text.slice(lastIndex, match.index)));
    }
    const em = document.createElement("em");
    em.textContent = match[1];
    parent.appendChild(em);
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < text.length) {
    parent.appendChild(document.createTextNode(text.slice(lastIndex)));
  }
}
