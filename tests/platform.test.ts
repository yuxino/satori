import assert from "node:assert/strict";
import test from "node:test";

import {
  desktopPlatformFromNavigator,
  fileNameFromPath,
  hasPrimaryModifier,
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
