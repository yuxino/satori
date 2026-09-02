import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

export function releaseAssetNames(version) {
  return [
    "Satori.app.tar.gz",
    "Satori.app.tar.gz.sig",
    `Satori-v${version}-macos-arm64.zip`,
    `Satori-v${version}-macos-arm64-SHA256SUMS.txt`,
    `Satori_${version}_x64-setup.exe`,
    `Satori_${version}_x64-setup.exe.sig`,
    `Satori_${version}_x64-SHA256SUMS.txt`,
    `Satori_${version}_arm64-setup.exe`,
    `Satori_${version}_arm64-setup.exe.sig`,
    `Satori_${version}_arm64-SHA256SUMS.txt`,
    "latest.json",
  ];
}

export function createUpdaterManifest({ version, notes, pubDate, baseUrl, signatures }) {
  const cleanBase = baseUrl.replace(/\/$/, "");
  return {
    version,
    notes,
    pub_date: pubDate,
    platforms: {
      "darwin-aarch64": {
        signature: signatures["darwin-aarch64"],
        url: `${cleanBase}/Satori.app.tar.gz`,
      },
      "windows-x86_64": {
        signature: signatures["windows-x86_64"],
        url: `${cleanBase}/Satori_${version}_x64-setup.exe`,
      },
      "windows-aarch64": {
        signature: signatures["windows-aarch64"],
        url: `${cleanBase}/Satori_${version}_arm64-setup.exe`,
      },
    },
  };
}

function assertSignature(signature, target) {
  if (typeof signature !== "string" || signature.trim().length < 32 || !/^[A-Za-z0-9+/=\r\n]+$/.test(signature.trim())) {
    throw new Error(`Invalid updater signature for ${target}.`);
  }
}

export function validateUpdaterManifest(manifest, { version, baseUrl }) {
  if (manifest.version !== version) throw new Error(`Manifest version ${manifest.version} does not match ${version}.`);
  if (Number.isNaN(Date.parse(manifest.pub_date))) throw new Error("Manifest pub_date is not RFC 3339 compatible.");
  if (typeof manifest.notes !== "string" || !manifest.notes.trim()) throw new Error("Manifest release notes are empty.");
  const expected = createUpdaterManifest({
    version,
    notes: manifest.notes,
    pubDate: manifest.pub_date,
    baseUrl,
    signatures: Object.fromEntries(
      Object.entries(manifest.platforms ?? {}).map(([target, value]) => [target, value?.signature]),
    ),
  });
  const actualTargets = Object.keys(manifest.platforms ?? {}).sort();
  const expectedTargets = Object.keys(expected.platforms).sort();
  if (JSON.stringify(actualTargets) !== JSON.stringify(expectedTargets)) {
    throw new Error(`Manifest targets must be exactly: ${expectedTargets.join(", ")}.`);
  }
  for (const target of expectedTargets) {
    const actual = manifest.platforms[target];
    const wanted = expected.platforms[target];
    assertSignature(actual.signature, target);
    if (actual.url !== wanted.url) throw new Error(`Wrong updater URL for ${target}: ${actual.url}`);
  }
}

export function validateUniqueAssetNames(names, version) {
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  if (duplicates.length) throw new Error(`Duplicate release assets: ${[...new Set(duplicates)].join(", ")}`);
  const expected = releaseAssetNames(version);
  const missing = expected.filter((name) => !names.includes(name));
  if (missing.length) throw new Error(`Missing release assets: ${missing.join(", ")}`);
}

async function sha256(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function verifyChecksum(directory, manifestName, assetName) {
  const manifest = await readFile(join(directory, manifestName), "utf8");
  const escaped = assetName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = manifest.match(new RegExp(`^([a-fA-F0-9]{64})\\s+\\*?${escaped}$`, "m"));
  if (!match) throw new Error(`${manifestName} has no SHA-256 entry for ${assetName}.`);
  const actual = await sha256(join(directory, assetName));
  if (match[1].toLowerCase() !== actual) throw new Error(`SHA-256 mismatch for ${assetName}.`);
}

export async function verifyReleaseDirectory(directory, version, baseUrl) {
  const names = await readdir(directory);
  validateUniqueAssetNames(names, version);
  const manifest = JSON.parse(await readFile(join(directory, "latest.json"), "utf8"));
  validateUpdaterManifest(manifest, { version, baseUrl });
  await Promise.all([
    verifyChecksum(directory, `Satori-v${version}-macos-arm64-SHA256SUMS.txt`, `Satori-v${version}-macos-arm64.zip`),
    verifyChecksum(directory, `Satori_${version}_x64-SHA256SUMS.txt`, `Satori_${version}_x64-setup.exe`),
    verifyChecksum(directory, `Satori_${version}_arm64-SHA256SUMS.txt`, `Satori_${version}_arm64-setup.exe`),
  ]);
}

async function main() {
  const argumentsMap = new Map();
  for (let index = 2; index < process.argv.length; index += 2) argumentsMap.set(process.argv[index], process.argv[index + 1]);
  const directory = argumentsMap.get("--dir");
  const version = argumentsMap.get("--version");
  const baseUrl = argumentsMap.get("--base-url");
  const notes = argumentsMap.get("--notes");
  const pubDate = argumentsMap.get("--pub-date");
  if (!directory || !version || !baseUrl || !notes || !pubDate) {
    throw new Error("Usage: updater-release.mjs --dir DIR --version VERSION --base-url URL --notes TEXT --pub-date RFC3339");
  }
  const signatures = {
    "darwin-aarch64": (await readFile(join(directory, "Satori.app.tar.gz.sig"), "utf8")).trim(),
    "windows-x86_64": (await readFile(join(directory, `Satori_${version}_x64-setup.exe.sig`), "utf8")).trim(),
    "windows-aarch64": (await readFile(join(directory, `Satori_${version}_arm64-setup.exe.sig`), "utf8")).trim(),
  };
  const manifest = createUpdaterManifest({ version, notes, pubDate, baseUrl, signatures });
  await writeFile(join(directory, "latest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  await verifyReleaseDirectory(directory, version, baseUrl);
  process.stdout.write(`Verified updater release assets for v${version} in ${basename(directory)}.\n`);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
