const DEFAULT_MAX_CANVAS_PIXELS = 12_000_000;
const DEFAULT_MAX_CANVAS_SIDE = 8192;

/** Clamp a requested PDF.js scale before allocating a canvas. */
export function scaleWithinCanvasBudget(
  logicalWidth: number,
  logicalHeight: number,
  requestedScale: number,
  maxPixels = DEFAULT_MAX_CANVAS_PIXELS,
  maxSide = DEFAULT_MAX_CANVAS_SIDE,
): number {
  if (logicalWidth <= 0 || logicalHeight <= 0 || requestedScale <= 0) return requestedScale;
  const requestedWidth = logicalWidth * requestedScale;
  const requestedHeight = logicalHeight * requestedScale;
  const pixelRatio = Math.sqrt(maxPixels / (requestedWidth * requestedHeight));
  const sideRatio = Math.min(maxSide / requestedWidth, maxSide / requestedHeight);
  return requestedScale * Math.min(1, pixelRatio, sideRatio);
}
