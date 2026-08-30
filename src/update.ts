import { getVersion } from "@tauri-apps/api/app";
import { openUrl } from "@tauri-apps/plugin-opener";
import { checkForUpdate } from "./api";
import type { ReleaseUpdatePhase } from "./platform";

const RELEASES_URL = "https://github.com/yuxino/satori/releases/latest";

export type AppUpdatePhase = ReleaseUpdatePhase;

export interface AppUpdateSnapshot {
  phase: AppUpdatePhase;
  currentVersion: string;
  latestVersion: string;
  errorMessage: string;
}

type UpdateListener = (snapshot: AppUpdateSnapshot) => void;

let snapshot: AppUpdateSnapshot = {
  phase: "idle",
  currentVersion: "",
  latestVersion: "",
  errorMessage: "",
};
let checkInFlight: Promise<void> | null = null;
let manualCheckRequested = false;
let initialized = false;
let automaticCheckTimer: number | null = null;
const listeners = new Set<UpdateListener>();

export function versionLabel(version: string): string {
  const normalized = version.trim().replace(/^[vV]/, "");
  return normalized ? `v${normalized}` : "";
}

export function getAppUpdateSnapshot(): AppUpdateSnapshot {
  return { ...snapshot };
}

export function subscribeToAppUpdates(listener: UpdateListener): () => void {
  listeners.add(listener);
  listener(getAppUpdateSnapshot());
  return () => listeners.delete(listener);
}

function publish(next: AppUpdateSnapshot): void {
  snapshot = next;
  const value = getAppUpdateSnapshot();
  for (const listener of listeners) listener(value);
}

async function loadCurrentVersion(): Promise<void> {
  try {
    const currentVersion = await getVersion();
    publish({ ...snapshot, currentVersion });
  } catch {
    // Native update results also include the current version. Failure here
    // must not block the rest of the app or turn into a false update result.
  }
}

export function checkForAppUpdate(manual: boolean): Promise<void> {
  manualCheckRequested ||= manual;
  if (manual && automaticCheckTimer !== null) {
    window.clearTimeout(automaticCheckTimer);
    automaticCheckTimer = null;
  }
  if (checkInFlight) return checkInFlight;

  publish({ ...snapshot, phase: "checking", errorMessage: "" });
  checkInFlight = (async () => {
    try {
      const info = await checkForUpdate();
      publish({
        phase: info.available ? "available" : info.release_available ? "release-only" : "current",
        currentVersion: info.current_version,
        latestVersion: info.latest_version,
        errorMessage: "",
      });
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      publish({
        ...snapshot,
        phase: manualCheckRequested ? "error" : "idle",
        errorMessage: manualCheckRequested ? errorMessage : "",
      });
    }
  })().finally(() => {
    checkInFlight = null;
    manualCheckRequested = false;
  });

  return checkInFlight;
}

export function initializeAppUpdateCheck(): void {
  if (initialized) return;
  initialized = true;
  void loadCurrentVersion();
  automaticCheckTimer = window.setTimeout(() => {
    automaticCheckTimer = null;
    if (snapshot.phase === "idle") void checkForAppUpdate(false);
  }, 1400);
}

export function openLatestRelease(): Promise<void> {
  return openUrl(RELEASES_URL);
}
