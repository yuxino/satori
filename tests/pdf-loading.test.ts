import assert from "node:assert/strict";
import test from "node:test";

import { monitorPDFDocument } from "../src/pdf-loading.ts";

test("keeps a successful loading task alive for the document wrapper", async () => {
  let destroyCalls = 0;
  const document = { pages: 1 };
  const result = await monitorPDFDocument({
    promise: Promise.resolve(document),
    destroy: async () => {
      destroyCalls += 1;
    },
  }).promise;

  assert.equal(result, document);
  assert.equal(destroyCalls, 0);
});

test("destroys a failed loading task and preserves the original error", async () => {
  let destroyCalls = 0;
  const failure = new Error("damaged PDF");
  await assert.rejects(
    monitorPDFDocument({
      promise: Promise.reject(failure),
      destroy: async () => {
        destroyCalls += 1;
      },
    }).promise,
    (error) => error === failure,
  );
  assert.equal(destroyCalls, 1);
});

test("preserves the load error even if cleanup also fails", async () => {
  const failure = new Error("damaged PDF");
  await assert.rejects(
    monitorPDFDocument({
      promise: Promise.reject(failure),
      destroy: async () => {
        throw new Error("cleanup failed");
      },
    }).promise,
    (error) => error === failure,
  );
});

test("cancels and destroys a loading task without waiting for its parser", async () => {
  let destroyCalls = 0;
  const controller = new AbortController();
  const monitored = monitorPDFDocument(
    {
      promise: new Promise(() => undefined),
      destroy: async () => { destroyCalls += 1; },
    },
    { signal: controller.signal },
  );
  controller.abort();
  await assert.rejects(monitored.promise, { name: "PDFLoadCancelledError" });
  assert.equal(destroyCalls, 1);
});

test("an already-cancelled open never starts waiting for the parser", async () => {
  let destroyCalls = 0;
  const controller = new AbortController();
  controller.abort();
  const monitored = monitorPDFDocument(
    {
      promise: new Promise(() => undefined),
      destroy: async () => { destroyCalls += 1; },
    },
    { signal: controller.signal },
  );
  await assert.rejects(monitored.promise, { name: "PDFLoadCancelledError" });
  assert.equal(destroyCalls, 1);
});

test("stops a stalled loading task but progress extends its deadline", async () => {
  let destroyCalls = 0;
  const monitored = monitorPDFDocument(
    {
      promise: new Promise(() => undefined),
      destroy: async () => { destroyCalls += 1; },
    },
    { stallTimeoutMs: 25 },
  );
  await new Promise((resolve) => setTimeout(resolve, 15));
  monitored.heartbeat();
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(destroyCalls, 0);
  await assert.rejects(monitored.promise, { name: "PDFLoadStalledError" });
  assert.equal(destroyCalls, 1);
});
