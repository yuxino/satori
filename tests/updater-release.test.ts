import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createUpdaterManifest,
  releaseAssetNames,
  validateUniqueAssetNames,
  validateUpdaterManifest,
  verifyReleaseDirectory,
} from "../scripts/updater-release.mjs";

const version = "3.4.4";
const baseUrl = "https://github.com/yuxino/satori/releases/download/v3.4.4";
const signature = "A".repeat(88);

function validManifest() {
  return createUpdaterManifest({
    version,
    notes: "Signed updater bootstrap",
    pubDate: "2026-09-02T12:00:00Z",
    baseUrl,
    signatures: {
      "darwin-aarch64": signature,
      "windows-x86_64": signature,
      "windows-aarch64": signature,
    },
  });
}

test("static updater manifest covers every supported architecture exactly once", () => {
  const manifest = validManifest();
  assert.doesNotThrow(() => validateUpdaterManifest(manifest, { version, baseUrl }));
  assert.deepEqual(Object.keys(manifest.platforms).sort(), ["darwin-aarch64", "windows-aarch64", "windows-x86_64"]);
});

test("manifest validation fails closed on a missing or malformed signature", () => {
  const missing = validManifest();
  missing.platforms["windows-aarch64"].signature = "";
  assert.throws(() => validateUpdaterManifest(missing, { version, baseUrl }), /signature/);

  const malformed = validManifest();
  malformed.platforms["darwin-aarch64"].signature = "not a minisign signature!";
  assert.throws(() => validateUpdaterManifest(malformed, { version, baseUrl }), /signature/);
});

test("manifest validation rejects architecture swaps and unexpected targets", () => {
  const swapped = validManifest();
  swapped.platforms["windows-aarch64"].url = `${baseUrl}/Satori_${version}_x64-setup.exe`;
  assert.throws(() => validateUpdaterManifest(swapped, { version, baseUrl }), /Wrong updater URL/);

  const extra = validManifest();
  extra.platforms["darwin-x86_64"] = extra.platforms["darwin-aarch64"];
  assert.throws(() => validateUpdaterManifest(extra, { version, baseUrl }), /targets must be exactly/);
});

test("release asset validation rejects missing and duplicate updater artifacts", () => {
  const names = releaseAssetNames(version);
  assert.doesNotThrow(() => validateUniqueAssetNames(names, version));
  assert.throws(() => validateUniqueAssetNames(names.slice(1), version), /Missing release assets/);
  assert.throws(() => validateUniqueAssetNames([...names, names[0]], version), /Duplicate release assets/);
});

async function createReleaseFixture(t: test.TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "satori-updater-release-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const names = releaseAssetNames(version);
  const contents = new Map<string, string>();
  for (const name of names) contents.set(name, name.endsWith(".sig") ? signature : `fixture:${name}`);
  const manifest = validManifest();
  contents.set("latest.json", `${JSON.stringify(manifest, null, 2)}\n`);
  for (const [architecture, asset] of [
    ["macos-arm64", `Satori-v${version}-macos-arm64.zip`],
    ["x64", `Satori_${version}_x64-setup.exe`],
    ["arm64", `Satori_${version}_arm64-setup.exe`],
  ] as const) {
    const hash = createHash("sha256").update(contents.get(asset) ?? "").digest("hex");
    const checksumName = architecture === "macos-arm64"
      ? `Satori-v${version}-macos-arm64-SHA256SUMS.txt`
      : `Satori_${version}_${architecture}-SHA256SUMS.txt`;
    contents.set(checksumName, `${hash}  ${asset}\n`);
  }
  await Promise.all([...contents].map(([name, content]) => writeFile(join(directory, name), content, "utf8")));
  return directory;
}

test("release directory verification accepts matching checksums", async (t) => {
  const directory = await createReleaseFixture(t);
  await assert.doesNotReject(() => verifyReleaseDirectory(directory, version, baseUrl));
});

test("release directory verification rejects a changed installer", async (t) => {
  const directory = await createReleaseFixture(t);
  await writeFile(join(directory, `Satori_${version}_arm64-setup.exe`), "tampered", "utf8");
  await assert.rejects(() => verifyReleaseDirectory(directory, version, baseUrl), /SHA-256 mismatch/);
});
