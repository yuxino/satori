import assert from "node:assert/strict";
import test from "node:test";

import { RequestGate } from "../src/request-gate.ts";

test("allows only one active request", () => {
  const gate = new RequestGate();
  const token = gate.begin();

  assert.equal(typeof token, "number");
  assert.equal(gate.busy, true);
  assert.equal(gate.begin(), null);
});

test("invalidation makes an existing token stale", () => {
  const gate = new RequestGate();
  const token = gate.begin();
  assert.notEqual(token, null);

  gate.invalidate();

  assert.equal(gate.busy, false);
  assert.equal(gate.isCurrent(token!), false);
});

test("an old completion cannot clear a newer request", () => {
  const gate = new RequestGate();
  const oldToken = gate.begin();
  assert.notEqual(oldToken, null);
  gate.invalidate();
  const newToken = gate.begin();
  assert.notEqual(newToken, null);

  gate.finish(oldToken!);

  assert.equal(gate.busy, true);
  assert.equal(gate.isCurrent(newToken!), true);
  gate.finish(newToken!);
  assert.equal(gate.busy, false);
});
