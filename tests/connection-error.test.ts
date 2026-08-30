import assert from "node:assert/strict";
import test from "node:test";

import { actionableConnectionError } from "../src/connection-error.ts";

test("maps Windows network and provider failures to retry guidance", () => {
  assert.match(actionableConnectionError("dns name resolution failed"), /DNS/);
  assert.match(actionableConnectionError("TLS certificate error"), /Windows 时间/);
  assert.match(actionableConnectionError("actively refused"), /服务正在运行/);
  assert.match(actionableConnectionError("HTTP 429 rate limit"), /稍后重试/);
});

test("never repeats a supplied API key in a generic auth error", () => {
  const message = actionableConnectionError("HTTP 401 invalid api key");
  assert.equal(message, "鉴权失败。请检查 API Key 是否正确，并确认它属于当前服务。");
});
