import assert from "node:assert/strict";
import test from "node:test";

import { awaitPDFDocument } from "../src/pdf-loading.ts";

test("keeps a successful loading task alive for the document wrapper", async () => {
  let destroyCalls = 0;
  const document = { pages: 1 };
  const result = await awaitPDFDocument({
    promise: Promise.resolve(document),
    destroy: async () => {
      destroyCalls += 1;
    },
  });

  assert.equal(result, document);
  assert.equal(destroyCalls, 0);
});

test("destroys a failed loading task and preserves the original error", async () => {
  let destroyCalls = 0;
  const failure = new Error("damaged PDF");
  await assert.rejects(
    awaitPDFDocument({
      promise: Promise.reject(failure),
      destroy: async () => {
        destroyCalls += 1;
      },
    }),
    (error) => error === failure,
  );
  assert.equal(destroyCalls, 1);
});

test("preserves the load error even if cleanup also fails", async () => {
  const failure = new Error("damaged PDF");
  await assert.rejects(
    awaitPDFDocument({
      promise: Promise.reject(failure),
      destroy: async () => {
        throw new Error("cleanup failed");
      },
    }),
    (error) => error === failure,
  );
});
