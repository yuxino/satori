function isLoopbackHost(hostname: string): boolean {
  const host = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

/** Mirrors the native provider boundary before a profile can be saved or activated. */
export function apiBaseURLError(value: string): string | null {
  const input = value.trim();
  if (!input) return "请输入 API 地址。";

  let url: URL;
  try {
    url = new URL(input);
  } catch {
    return "请输入有效的 API 地址。";
  }

  if (url.username || url.password) return "不要把账号或密钥写进 API 地址。";
  if (input.includes("?") || input.includes("#")) return "API 地址不能包含查询参数或片段。";
  if (!url.hostname) return "API 地址必须包含主机名。";
  if (url.protocol === "https:") return null;
  if (url.protocol === "http:" && isLoopbackHost(url.hostname)) return null;
  if (url.protocol === "http:") return "远程 API 地址必须使用 HTTPS。";
  return "API 地址只支持 HTTPS；本机服务可使用 HTTP。";
}

export function isValidAPIBaseURL(value: string): boolean {
  return apiBaseURLError(value) === null;
}
