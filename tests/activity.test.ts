import assert from "node:assert/strict";
import test from "node:test";

import { pageTransitionDelta } from "../src/activity.ts";

test("same-page open, zoom, resize, and scroll callbacks do not count as page turns", () => {
  assert.equal(pageTransitionDelta(5, 5), 0);
});

test("each real page transition counts once", () => {
  assert.equal(pageTransitionDelta(5, 6), 1);
  assert.equal(pageTransitionDelta(6, 6), 0);
  assert.equal(pageTransitionDelta(6, 5), 1);
});
