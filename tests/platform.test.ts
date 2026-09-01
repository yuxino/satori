import assert from "node:assert/strict";
import test from "node:test";

import {
  desktopPlatformFromNavigator,
  fileNameFromPath,
  hasPrimaryModifier,
  shouldHandlePageFlipWheel,
  updatePresentation,
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

test("downloadable updates use platform-neutral download wording", () => {
  assert.deepEqual(updatePresentation({ phase: "available", latestVersion: "3.4.0" }), {
    status: "发现适用的新版本",
    action: "下载 v3.4.0",
    title: "在浏览器中打开 Satori v3.4.0 下载页",
  });
});

test("a release without a matching installer never claims a download", () => {
  const presentation = updatePresentation({ phase: "release-only", latestVersion: "3.4.0" });
  assert.deepEqual(presentation, {
    status: "新版本暂无适用安装包",
    action: "查看 Releases",
    title: "查看 Satori v3.4.0 官方 Release",
  });
  assert.doesNotMatch(`${presentation?.status} ${presentation?.action} ${presentation?.title}`, /下载/);
});
