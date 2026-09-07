import assert from "node:assert/strict";
import test from "node:test";

import { scaleWithinCanvasBudget } from "../src/reader-budget.ts";

test("keeps ordinary reader canvases at the requested scale", () => {
  assert.equal(scaleWithinCanvasBudget(612, 792, 2), 2);
});

test("caps zoomed canvases by area and maximum side", () => {
  const scale = scaleWithinCanvasBudget(4000, 6000, 3);
  assert.ok(4000 * scale <= 8192);
  assert.ok(6000 * scale <= 8192);
  assert.ok(4000 * scale * 6000 * scale <= 12_000_000.001);
});

// Exercise the same render entry used by reader, thumbnails, and AI evidence.
import { renderPDFPage } from "../src/reader-budget.ts";

function rendererFixture(t: { after: (fn: () => void) => void }, width = 600, height = 800) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "document");
  const canvases: Array<{ width: number; height: number; getContext: () => object }> = [];
  Object.defineProperty(globalThis, "document", { configurable: true, value: {
    createElement: () => {
      const canvas = { width: 0, height: 0, getContext: () => ({}) };
      canvases.push(canvas);
      return canvas;
    },
  } });
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "document", previous);
    else Reflect.deleteProperty(globalThis, "document");
  });
  const calls: Array<{ viewport: { scale: number }; transform?: number[] }> = [];
  let cancel = () => {};
  let promise: Promise<void> = Promise.resolve();
  const page = {
    getViewport: ({ scale }: { scale: number }) => ({ width: width * scale, height: height * scale, scale }),
    render: (options: typeof calls[number]) => {
      calls.push(options);
      return { promise, cancel: () => cancel() };
    },
  };
  return {
    page: page as unknown as Parameters<typeof renderPDFPage>[0], calls, canvases,
    pending: (value: Promise<void>, onCancel = () => {}) => { promise = value; cancel = onCancel; },
  };
}

test("region origin maps to zero and its far edge fills the crop at exactly one scale", async (t) => {
  const fixture = rendererFixture(t);
  const rect = { x: 80, y: 120, width: 100, height: 60 };
  const { canvas } = await renderPDFPage(fixture.page, 3, { region: rect });
  const { viewport, transform } = fixture.calls[0];
  const [a, , , d, tx, ty] = transform!;
  const map = (x: number, y: number) => [a * x * viewport.scale + tx, d * y * viewport.scale + ty];
  assert.deepEqual(map(rect.x, rect.y), [0, 0]);
  assert.deepEqual(map(rect.x + rect.width, rect.y + rect.height), [canvas.width, canvas.height]);
  assert.equal(canvas.width, 300);
  assert.equal(canvas.height, 180);
});

test("large page evidence is bounded before its only canvas allocation", async (t) => {
  const fixture = rendererFixture(t, 10000, 14000);
  const { canvas } = await renderPDFPage(fixture.page, 1.5, { maxSide: 1800 });
  assert.equal(fixture.canvases.length, 1);
  assert.ok(canvas.width <= 1800 && canvas.height <= 1800);
  assert.ok(canvas.width * canvas.height <= 1800 * 1800);
});

test("extremely tall thumbnail and large region also obey canvas budgets", async (t) => {
  const fixture = rendererFixture(t, 1, 100000);
  const thumb = await renderPDFPage(fixture.page, 60);
  assert.equal(thumb.canvas.width, 1);
  assert.ok(thumb.canvas.height <= 8192);
  const region = await renderPDFPage(fixture.page, 3, {
    region: { x: 10, y: 20, width: 10000, height: 14000 }, maxSide: 1800,
  });
  assert.ok(region.canvas.width <= 1800 && region.canvas.height <= 1800);
});

test("invalid dimensions fail before canvas allocation", async (t) => {
  const fixture = rendererFixture(t, NaN);
  await assert.rejects(renderPDFPage(fixture.page, 1), /尺寸/);
  assert.equal(fixture.canvases.length, 0);
  assert.throws(() => scaleWithinCanvasBudget(100, 100, Infinity), /尺寸/);
});

test("already cancelled work never allocates or renders", async (t) => {
  const fixture = rendererFixture(t);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(renderPDFPage(fixture.page, 1, { signal: controller.signal }), { name: "PDFLoadCancelledError" });
  assert.equal(fixture.canvases.length, 0);
  assert.equal(fixture.calls.length, 0);
});

test("cancellation interrupts the render and frees the backing canvas", async (t) => {
  const fixture = rendererFixture(t);
  const controller = new AbortController();
  let cancelled = 0;
  let reject!: (error: Error) => void;
  fixture.pending(new Promise<void>((_resolve, fail) => { reject = fail; }), () => {
    cancelled++;
    reject(new Error("PDF.js render cancelled"));
  });
  const rendering = renderPDFPage(fixture.page, 2, { signal: controller.signal });
  controller.abort();
  await assert.rejects(rendering, { name: "PDFLoadCancelledError" });
  assert.equal(cancelled, 1);
  assert.equal(fixture.canvases[0].width, 0);
  assert.equal(fixture.canvases[0].height, 0);
});

test("render failures release the canvas and preserve the original error", async (t) => {
  const fixture = rendererFixture(t);
  const error = new Error("broken page");
  fixture.pending(Promise.reject(error));
  await assert.rejects(renderPDFPage(fixture.page, 1), (value) => value === error);
  assert.equal(fixture.canvases[0].width, 0);
  assert.equal(fixture.canvases[0].height, 0);
});
