import assert from "node:assert/strict";
import test from "node:test";

import { apiBaseURLError, isValidAPIBaseURL } from "../src/provider-url-policy.ts";

test("accepts HTTPS and loopback HTTP provider addresses", () => {
  for (const url of [
    "https://example.com/v1",
    "http://localhost:8080/v1",
    "http://127.0.0.1:11434/v1",
    "http://[::1]:8080/v1",
  ]) {
    assert.equal(apiBaseURLError(url), null, url);
    assert.equal(isValidAPIBaseURL(url), true, url);
  }
});

test("rejects remote plaintext HTTP and non-loopback addresses", () => {
  for (const url of [
    "http://example.com/v1",
    "http://127.0.0.2:8080/v1",
    "http://192.168.1.20:8080/v1",
  ]) {
    assert.equal(apiBaseURLError(url), "远程 API 地址必须使用 HTTPS。", url);
    assert.equal(isValidAPIBaseURL(url), false, url);
  }
});

test("rejects credentials, query parameters, fragments, and non-web schemes", () => {
  assert.equal(
    apiBaseURLError("https://user:secret@example.com/v1"),
    "不要把账号或密钥写进 API 地址。",
  );
  assert.equal(
    apiBaseURLError("https://example.com/v1?key=secret"),
    "API 地址不能包含查询参数或片段。",
  );
  assert.equal(
    apiBaseURLError("https://example.com/v1#models"),
    "API 地址不能包含查询参数或片段。",
  );
  assert.equal(apiBaseURLError("https://example.com/v1?"), "API 地址不能包含查询参数或片段。");
  assert.equal(apiBaseURLError("https://example.com/v1#"), "API 地址不能包含查询参数或片段。");
  assert.equal(
    apiBaseURLError("file:///Users/example/provider"),
    "API 地址必须包含主机名。",
  );
});
