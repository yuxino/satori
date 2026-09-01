export function formatUnknownError(error: unknown): string {
  if (error instanceof Error && error.message.trim()) return error.message.trim();
  if (typeof error === "string" && error.trim()) return error.trim();
  try {
    const serialized = JSON.stringify(error);
    return serialized && serialized !== "{}" ? serialized : "未知错误";
  } catch {
    return "未知错误";
  }
}

/** Keep provider errors actionable while preserving safe server detail. */
export function actionableConnectionError(error: unknown): string {
  const message = formatUnknownError(error);
  const lower = message.toLowerCase();
  if (lower.includes("401") || lower.includes("unauthorized") || lower.includes("api key")) {
    return "鉴权失败。请检查 API Key 是否正确，并确认它属于当前服务。";
  }
  if (lower.includes("403") || lower.includes("forbidden")) {
    return "服务拒绝了请求。请检查 Key 权限、账户额度和模型访问权限。";
  }
  if (lower.includes("429") || lower.includes("rate limit")) {
    return "请求过于频繁或额度不足。请稍后重试，并检查服务账户额度。";
  }
  if (lower.includes("404") || lower.includes("model") && lower.includes("not")) {
    return "找不到 API 地址或模型。请核对服务地址和模型 ID。";
  }
  if (lower.includes("certificate") || lower.includes("tls") || lower.includes("ssl")) {
    return "安全连接验证失败。请检查系统时间、系统证书和服务地址。";
  }
  if (lower.includes("dns") || lower.includes("name resolution") || lower.includes("failed to lookup")) {
    return "无法解析服务地址。请检查网络和 DNS 后重试。";
  }
  if (lower.includes("proxy")) {
    return "代理连接失败。请检查系统代理设置，或改用可直接访问的服务地址。";
  }
  if (lower.includes("connection refused") || lower.includes("actively refused")) {
    return "服务拒绝连接。请确认服务正在运行、地址和端口正确。";
  }
  if (lower.includes("timeout") || lower.includes("timed out") || message.includes("超时")) {
    return "连接超时。请检查网络、服务地址，或稍后重试。";
  }
  return message;
}
