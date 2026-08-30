import assert from "node:assert/strict";
import test from "node:test";

import { fileSizeLabel, pdfOpenErrorMessage } from "../src/pdf-open-policy.ts";

test("turns parser and Windows read failures into recovery guidance", () => {
  const invalid = new Error("Invalid PDF structure");
  invalid.name = "InvalidPDFException";
  assert.match(pdfOpenErrorMessage(invalid), /重新复制/);

  const fetchFailure = new TypeError("Failed to fetch");
  assert.match(pdfOpenErrorMessage(fetchFailure), /复制已完成/);
});

test("keeps large PDF sizes readable without rejecting them", () => {
  assert.equal(fileSizeLabel(244 * 1024 * 1024), "244 MB");
  assert.equal(fileSizeLabel(32 * 1024 * 1024), "32 MB");
});
