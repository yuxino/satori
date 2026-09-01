function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "";
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error ?? "未知错误").replace(/^Error:\s*/i, "");
}

/** Convert PDF.js/native failures into a bounded recovery message. */
export function pdfOpenErrorMessage(error: unknown): string {
  const name = errorName(error);
  const message = errorMessage(error).trim();
  if (name === "PDFLoadCancelledError") return "已取消打开 PDF。";
  if (name === "PDFLoadStalledError") return message;
  if (/PasswordException/i.test(name) || /password/i.test(message)) {
    return "这份 PDF 需要密码，Satori 暂时无法打开加密文件。";
  }
  if (/InvalidPDFException/i.test(name) || /invalid pdf|format error/i.test(message)) {
    return "PDF 已损坏或复制不完整。请重新复制原文件后再试。";
  }
  if (/MissingPDFException|UnexpectedResponseException/i.test(name) || /failed to fetch|networkerror/i.test(message)) {
    return "系统无法读取这份 PDF。请确认复制已完成，文件仍在原位置，然后重试。";
  }
  const safe = message || "未知错误";
  return safe.length > 280 ? `${safe.slice(0, 280)}…` : safe;
}

export function fileSizeLabel(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  const mib = bytes / (1024 * 1024);
  return mib >= 10 ? `${Math.round(mib)} MB` : `${mib.toFixed(1)} MB`;
}
