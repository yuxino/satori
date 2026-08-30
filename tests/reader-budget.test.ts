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
