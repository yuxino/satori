export type PdfDropDecision =
  | { accepted: true; path: string }
  | { accepted: false; message: string };

export function decidePdfDrop(paths: string[]): PdfDropDecision {
  if (paths.length !== 1) {
    return { accepted: false, message: "一次只拖入一份 PDF。" };
  }
  const path = paths[0]?.trim() ?? "";
  if (!/\.pdf$/i.test(path)) {
    return { accepted: false, message: "这里只接收 PDF 文件。" };
  }
  return { accepted: true, path };
}
