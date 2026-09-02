import assert from "node:assert/strict";
import test from "node:test";

import { createAppUpdateController, type AppUpdateSnapshot } from "../src/update-controller.ts";

type DownloadCallback = (event: { event: "Started"; data: { contentLength?: number } } | { event: "Progress"; data: { chunkLength: number } } | { event: "Finished" }) => void;

function fixture(options: {
  checkError?: Error;
  downloadError?: Error;
  installError?: Error;
  prepareError?: Error;
  total?: number;
  platform?: "macos" | "windows";
  noUpdate?: boolean;
} = {}) {
  let checks = 0;
  let downloads = 0;
  let installs = 0;
  let closes = 0;
  let restarts = 0;
  let releases = 0;
  let preparations = 0;
  let unblockCheck: (() => void) | null = null;
  const checkGate = new Promise<void>((resolve) => {
    unblockCheck = resolve;
  });
  let gateChecks = false;
  const update = {
    currentVersion: "3.4.3",
    version: "3.4.4",
    body: "签名更新说明",
    async download(onEvent?: DownloadCallback) {
      downloads += 1;
      onEvent?.({ event: "Started", data: { contentLength: options.total } });
      onEvent?.({ event: "Progress", data: { chunkLength: 512 } });
      onEvent?.({ event: "Finished" });
      if (options.downloadError) throw options.downloadError;
    },
    async install(received?: { restartAfterInstall?: boolean }) {
      installs += 1;
      assert.equal(received?.restartAfterInstall, false);
      if (options.installError) throw options.installError;
    },
    async close() {
      closes += 1;
    },
  };
  const controller = createAppUpdateController({
    getVersion: async () => "3.4.3",
    check: async () => {
      checks += 1;
      if (gateChecks) await checkGate;
      if (options.checkError) throw options.checkError;
      return options.noUpdate ? null : update;
    },
    relaunch: async () => {
      restarts += 1;
    },
    openRelease: async () => {
      releases += 1;
    },
    prepareInstall: async () => {
      preparations += 1;
      if (options.prepareError) throw options.prepareError;
    },
    platform: options.platform ?? "macos",
  });
  return {
    controller,
    counts: () => ({ checks, downloads, installs, closes, restarts, releases, preparations }),
    gateChecks: () => {
      gateChecks = true;
    },
    unblockCheck: () => unblockCheck?.(),
  };
}

test("no update reports current and keeps download unavailable", async () => {
  const { controller, counts } = fixture({ noUpdate: true });
  await controller.check(true);
  assert.equal(controller.snapshot().phase, "current");
  await controller.download();
  assert.equal(counts().downloads, 0);
});

test("available update exposes version and release notes without downloading", async () => {
  const { controller, counts } = fixture();
  await controller.check(true);
  assert.deepEqual(
    { phase: controller.snapshot().phase, version: controller.snapshot().latestVersion, notes: controller.snapshot().releaseNotes },
    { phase: "available", version: "3.4.4", notes: "签名更新说明" },
  );
  assert.equal(counts().downloads, 0);
});

test("repeated checks share one in-flight native request", async () => {
  const { controller, counts, gateChecks, unblockCheck } = fixture();
  gateChecks();
  const first = controller.check(false);
  const second = controller.check(true);
  assert.equal(first, second);
  await Promise.resolve();
  assert.equal(counts().checks, 1);
  unblockCheck();
  await first;
});

test("download is installable only after framework verification resolves", async () => {
  const { controller } = fixture({ total: 1024 });
  const phases: AppUpdateSnapshot["phase"][] = [];
  controller.subscribe((snapshot) => phases.push(snapshot.phase));
  await controller.check(true);
  await controller.download();
  assert.deepEqual(
    { phase: controller.snapshot().phase, downloaded: controller.snapshot().downloadedBytes, total: controller.snapshot().totalBytes },
    { phase: "downloaded", downloaded: 512, total: 1024 },
  );
  assert.ok(phases.includes("verifying"));
  assert.equal(phases.at(-1), "downloaded");
});

test("unknown content length remains explicit and indeterminate", async () => {
  const { controller } = fixture();
  await controller.check(true);
  await controller.download();
  assert.equal(controller.snapshot().totalBytes, null);
  assert.equal(controller.snapshot().downloadedBytes, 512);
});

test("signature or network download failure never becomes ready and can retry", async () => {
  const signature = fixture({ downloadError: new Error("signature verification failed") });
  await signature.controller.check(true);
  await signature.controller.download();
  assert.deepEqual(
    { phase: signature.controller.snapshot().phase, stage: signature.controller.snapshot().errorStage },
    { phase: "error", stage: "download" },
  );
  await signature.controller.retry();
  assert.equal(signature.counts().downloads, 2);

  const network = fixture({ checkError: new Error("network unavailable") });
  await network.controller.check(true);
  assert.equal(network.controller.snapshot().phase, "error");
  assert.equal(network.controller.snapshot().errorStage, "check");
  await network.controller.retry();
  assert.equal(network.counts().checks, 2);
});

test("cancelling an available or verified update releases native resources", async () => {
  const available = fixture();
  await available.controller.check(true);
  await available.controller.cancel();
  assert.equal(available.controller.snapshot().phase, "cancelled");
  assert.equal(available.counts().closes, 1);

  const downloaded = fixture();
  await downloaded.controller.check(true);
  await downloaded.controller.download();
  await downloaded.controller.cancel();
  assert.equal(downloaded.controller.snapshot().phase, "cancelled");
  assert.equal(downloaded.counts().closes, 1);
});

test("macOS waits for an explicit restart after install", async () => {
  const { controller, counts } = fixture({ platform: "macos" });
  await controller.check(true);
  await controller.download();
  await controller.install();
  assert.equal(controller.snapshot().phase, "restart-ready");
  assert.equal(counts().preparations, 1);
  assert.equal(counts().restarts, 0);
  await controller.restart();
  assert.equal(counts().restarts, 1);
});

test("Windows starts its installer without claiming restart readiness", async () => {
  const { controller, counts } = fixture({ platform: "windows" });
  await controller.check(true);
  await controller.download();
  await controller.install();
  assert.equal(controller.snapshot().phase, "installing");
  assert.equal(counts().installs, 1);
  assert.equal(counts().restarts, 0);
});

test("a failed persistence checkpoint prevents installation and remains retryable", async () => {
  const { controller, counts } = fixture({ prepareError: new Error("could not save reading position") });
  await controller.check(true);
  await controller.download();
  await controller.install();
  assert.deepEqual(
    { phase: controller.snapshot().phase, stage: controller.snapshot().errorStage },
    { phase: "error", stage: "install" },
  );
  assert.equal(counts().preparations, 1);
  assert.equal(counts().installs, 0);
  await controller.retry();
  assert.equal(counts().preparations, 2);
  assert.equal(counts().installs, 0);
});

test("GitHub Releases is available only as error recovery", async () => {
  const healthy = fixture();
  await healthy.controller.openRecoveryRelease();
  assert.equal(healthy.counts().releases, 0);

  const failed = fixture({ checkError: new Error("offline") });
  await failed.controller.check(true);
  await failed.controller.openRecoveryRelease();
  assert.equal(failed.counts().releases, 1);
});
