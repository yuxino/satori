import assert from "node:assert/strict";
import test from "node:test";

import { safeExternalHref } from "../src/link-policy.ts";

test("allows explicit HTTP and HTTPS links", () => {
  assert.equal(safeExternalHref("https://example.com/guide?q=1"), "https://example.com/guide?q=1");
  assert.equal(safeExternalHref("http://localhost:8080/docs"), "http://localhost:8080/docs");
});

test("rejects executable and local-resource schemes", () => {
  assert.equal(safeExternalHref("javascript:alert(1)"), null);
  assert.equal(safeExternalHref("data:text/html,<script>alert(1)</script>"), null);
  assert.equal(safeExternalHref("file:///Users/example/private.txt"), null);
});

test("rejects relative and credential-bearing links", () => {
  assert.equal(safeExternalHref("/internal/path"), null);
  assert.equal(safeExternalHref("https://user:secret@example.com/"), null);
});
