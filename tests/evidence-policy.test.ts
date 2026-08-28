import assert from "node:assert/strict";
import test from "node:test";

import { requestedEvidencePages } from "../src/evidence-policy.ts";

test("ordinary explanations and examples stay on the visible page", () => {
  for (const question of [
    "还是不懂，换个说法",
    "请用一个具体的小例子解释",
    "这两个概念有什么关系？",
    "接着讲",
  ]) {
    assert.deepEqual(requestedEvidencePages(8, 20, question), [8], question);
  }
});

test("explicit previous and next page requests include only requested neighbors", () => {
  assert.deepEqual(requestedEvidencePages(8, 20, "结合上一页解释"), [7, 8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "下一页继续讲了什么？"), [8, 9]);
  assert.deepEqual(requestedEvidencePages(8, 20, "结合上文和下一页解释"), [7, 8, 9]);
});

test("explicit neighbor requests stay within document bounds", () => {
  assert.deepEqual(requestedEvidencePages(1, 20, "结合上一页解释"), [1]);
  assert.deepEqual(requestedEvidencePages(20, 20, "下一页讲了什么？"), [20]);
});

test("negated neighbor mentions never expand page evidence", () => {
  assert.deepEqual(requestedEvidencePages(8, 20, "不要看上一页，只解释当前页"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "只看当前页面"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "下一页不用发给模型"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "不是上一页，是当前页"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "勿看上一页"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "我没有要求看上一页"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "上一页无关，只解释这里"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "上一页与这个问题不相关"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "上一页无需作为参考"), [8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "上一页不用作为依据"), [8]);
});

test("a negated clause does not suppress a separate affirmative neighbor", () => {
  assert.deepEqual(requestedEvidencePages(8, 20, "不要结合上文。下一页继续讲了什么？"), [8, 9]);
  assert.deepEqual(requestedEvidencePages(8, 20, "上一页不用看，但下一页要看"), [8, 9]);
  assert.deepEqual(requestedEvidencePages(8, 20, "结合上一页但不要省略公式"), [7, 8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "下一页不要漏掉例题"), [8, 9]);
  assert.deepEqual(requestedEvidencePages(8, 20, "不要省略上一页的推导"), [7, 8]);
  assert.deepEqual(requestedEvidencePages(8, 20, "不是上一页而是下一页"), [8, 9]);
});
