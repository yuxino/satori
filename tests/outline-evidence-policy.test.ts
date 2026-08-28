import assert from "node:assert/strict";
import test from "node:test";

import { outlineEvidencePlan } from "../src/outline-evidence-policy.ts";

test("the outline plan fully describes both bounded request stages", () => {
  const plan = outlineEvidencePlan(100);
  assert.deepEqual(plan.outlinePages, [3, 4, 5, 6]);
  assert.deepEqual(plan.chapterProbePages, [20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44]);
});

test("the outline plan stays within short documents", () => {
  assert.deepEqual(outlineEvidencePlan(23), {
    outlinePages: [3, 4, 5, 6],
    chapterProbePages: [20, 22],
  });
  assert.deepEqual(outlineEvidencePlan(4), {
    outlinePages: [3, 4],
    chapterProbePages: [4],
  });
  assert.deepEqual(outlineEvidencePlan(0), {
    outlinePages: [],
    chapterProbePages: [],
  });
});
