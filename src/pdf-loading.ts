interface DestroyableLoadingTask<T> {
  promise: Promise<T>;
  destroy(): Promise<void>;
}

/** Release the PDF.js worker when document loading fails before a wrapper owns it. */
export async function awaitPDFDocument<T>(loadingTask: DestroyableLoadingTask<T>): Promise<T> {
  try {
    return await loadingTask.promise;
  } catch (error) {
    await loadingTask.destroy().catch(() => undefined);
    throw error;
  }
}
