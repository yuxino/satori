interface DestroyableLoadingTask<T> {
  promise: Promise<T>;
  destroy(): Promise<void>;
}

interface PDFLoadMonitorOptions {
  signal?: AbortSignal;
  /** Time without byte progress before the worker is torn down. Zero disables it. */
  stallTimeoutMs?: number;
}

interface PDFLoadMonitor<T> {
  promise: Promise<T>;
  heartbeat(): void;
}

function interruptedError(reason: "cancelled" | "stalled"): Error {
  const error = new Error(
    reason === "cancelled"
      ? "已取消打开 PDF。"
      : "PDF 长时间没有继续加载，已安全停止。文件可能仍在复制、已损坏，或当前电脑内存不足。",
  );
  error.name = reason === "cancelled" ? "PDFLoadCancelledError" : "PDFLoadStalledError";
  return error;
}

/**
 * Own one PDF.js loading task until success. Cancellation, stalls, and parser
 * failures all destroy the worker before the error is returned.
 */
export function monitorPDFDocument<T>(
  loadingTask: DestroyableLoadingTask<T>,
  options: PDFLoadMonitorOptions = {},
): PDFLoadMonitor<T> {
  const stallTimeoutMs = Math.max(0, options.stallTimeoutMs ?? 0);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let rejectInterruption: ((error: Error) => void) | undefined;
  let settled = false;

  const interruption = new Promise<never>((_resolve, reject) => {
    rejectInterruption = reject;
  });
  const interrupt = (reason: "cancelled" | "stalled") => {
    if (!settled) rejectInterruption?.(interruptedError(reason));
  };
  const heartbeat = () => {
    if (settled || stallTimeoutMs === 0) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => interrupt("stalled"), stallTimeoutMs);
  };
  const onAbort = () => interrupt("cancelled");
  if (options.signal?.aborted) onAbort();
  else options.signal?.addEventListener("abort", onAbort, { once: true });
  heartbeat();

  const promise = (async () => {
    try {
      return await Promise.race([loadingTask.promise, interruption]);
    } catch (error) {
      await loadingTask.destroy().catch(() => undefined);
      throw error;
    } finally {
      settled = true;
      if (timer) clearTimeout(timer);
      options.signal?.removeEventListener("abort", onAbort);
    }
  })();

  return { promise, heartbeat };
}

/** Release the PDF.js worker when document loading fails before a wrapper owns it. */
export async function awaitPDFDocument<T>(loadingTask: DestroyableLoadingTask<T>): Promise<T> {
  return monitorPDFDocument(loadingTask).promise;
}
