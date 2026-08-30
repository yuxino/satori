import assert from "node:assert/strict";
import test from "node:test";

import {
  updatePresentation,
  type ReleaseUpdatePhase,
  type ReleaseUpdatePresentationInput,
} from "../src/platform.ts";

function snapshot(phase: ReleaseUpdatePhase): ReleaseUpdatePresentationInput {
  return {
    phase,
    latestVersion: "3.4.0",
  };
}

test("downloadable updates use platform-neutral download wording", () => {
  assert.deepEqual(updatePresentation(snapshot("available")), {
    status: "发现适用的新版本",
    action: "下载 v3.4.0",
    title: "在浏览器中打开 Satori v3.4.0 下载页",
  });
});

test("a release without a matching installer never claims a download", () => {
  const presentation = updatePresentation(snapshot("release-only"));
  assert.deepEqual(presentation, {
    status: "新版本暂无适用安装包",
    action: "查看 Releases",
    title: "查看 Satori v3.4.0 官方 Release",
  });
  assert.doesNotMatch(`${presentation.status} ${presentation.action} ${presentation.title}`, /下载/);
});
