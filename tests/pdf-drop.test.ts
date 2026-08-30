import assert from "node:assert/strict";
import test from "node:test";

import { decidePdfDrop } from "../src/pdf-drop.ts";

test("accepts one PDF from Windows or macOS drag paths", () => {
  assert.deepEqual(decidePdfDrop(["C:\\Users\\Gavin\\Desktop\\教材.PDF"]), {
    accepted: true,
    path: "C:\\Users\\Gavin\\Desktop\\教材.PDF",
  });
  assert.equal(decidePdfDrop(["/Users/gavin/Book.pdf"]).accepted, true);
});

test("rejects folders, non-PDF files, and ambiguous multi-file drops", () => {
  assert.match(decidePdfDrop(["C:\\Books"]).message, /PDF/);
  assert.match(decidePdfDrop(["notes.txt"]).message, /PDF/);
  assert.match(decidePdfDrop(["one.pdf", "two.pdf"]).message, /一次/);
});
