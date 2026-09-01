import assert from "node:assert/strict";
import test from "node:test";

import { actionableConnectionError } from "../src/connection-error.ts";

test("maps cross-platform network and provider failures to retry guidance", () => {
  const dns = actionableConnectionError("dns name resolution failed");
  const tls = actionableConnectionError("TLS certificate error");
  const proxy = actionableConnectionError("proxy connection failed");
  assert.match(dns, /DNS/);
  assert.match(tls, /系统时间/);
  assert.match(proxy, /系统代理/);
  assert.doesNotMatch(`${dns} ${tls} ${proxy}`, /Windows|macOS/);
  assert.match(actionableConnectionError("actively refused"), /服务正在运行/);
  assert.match(actionableConnectionError("HTTP 429 rate limit"), /稍后重试/);
});

test("never repeats a supplied API key in a generic auth error", () => {
  const message = actionableConnectionError("HTTP 401 invalid api key");
  assert.equal(message, "鉴权失败。请检查 API Key 是否正确，并确认它属于当前服务。");
});
