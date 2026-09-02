import assert from "node:assert/strict";
import test from "node:test";

import {
  desktopPlatformFromNavigator,
  downloadProgressPresentation,
  fileNameFromPath,
  hasPrimaryModifier,
  shouldHandlePageFlipWheel,
  versionLabel,
} from "../src/platform.ts";

test("extracts PDF display names from POSIX and Windows paths", () => {
  assert.equal(fileNameFromPath("/Users/gavin/Books/Linear Algebra.pdf"), "Linear Algebra.pdf");
  assert.equal(fileNameFromPath("C:\\Users\\Gavin\\Books\\线性代数.pdf"), "线性代数.pdf");
  assert.equal(fileNameFromPath("D:/学习资料/ 概率论讲义 .pdf"), " 概率论讲义 .pdf");
  assert.equal(fileNameFromPath("just-a-book.pdf"), "just-a-book.pdf");
});

test("detects the desktop platform exposed by each native webview", () => {
  assert.equal(desktopPlatformFromNavigator("MacIntel"), "macos");
  assert.equal(desktopPlatformFromNavigator("Win32"), "windows");
  assert.equal(desktopPlatformFromNavigator("Linux x86_64"), "other");
});

test("uses only Command on macOS and only Control on Windows", () => {
  assert.equal(hasPrimaryModifier({ metaKey: true, ctrlKey: false }, "macos"), true);
  assert.equal(hasPrimaryModifier({ metaKey: false, ctrlKey: true }, "macos"), false);
  assert.equal(hasPrimaryModifier({ metaKey: false, ctrlKey: true }, "windows"), true);
  assert.equal(hasPrimaryModifier({ metaKey: true, ctrlKey: false }, "windows"), false);
  assert.equal(hasPrimaryModifier({ metaKey: false, ctrlKey: false }, "windows"), false);
});

test("reserves Ctrl+wheel for zoom instead of page flipping", () => {
  assert.equal(shouldHandlePageFlipWheel({ ctrlKey: true }), false);
  assert.equal(shouldHandlePageFlipWheel({ ctrlKey: false }), true);
});

test("formats release versions once for every update surface", () => {
  assert.equal(versionLabel("v3.4.1"), "v3.4.1");
  assert.equal(versionLabel("3.4.1"), "v3.4.1");
});

test("known update sizes produce a real bounded percentage", () => {
  assert.deepEqual(downloadProgressPresentation(512, 1024), {
    label: "已下载 512 B / 1.0 KB",
    percent: 50,
  });
  assert.equal(downloadProgressPresentation(2048, 1024).percent, 100);
});

test("unknown update sizes stay indeterminate without a fake percentage", () => {
  assert.deepEqual(downloadProgressPresentation(1536, null), {
    label: "已下载 1.5 KB",
    percent: null,
  });
});
