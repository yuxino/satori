import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import { check } from "@tauri-apps/plugin-updater";
import { openUrl } from "@tauri-apps/plugin-opener";
import { currentDesktopPlatform } from "./platform";
import {
  createAppUpdateController,
  type AppUpdateSnapshot,
  type UpdateHandle,
} from "./update-controller";

export type { AppUpdateSnapshot } from "./update-controller";

const RELEASES_URL = "https://github.com/yuxino/satori/releases/latest";
let prepareInstall: () => Promise<void> = async () => undefined;
const controller = createAppUpdateController({
  getVersion,
  check: () => check({ timeout: 12_000 }) as Promise<UpdateHandle | null>,
  relaunch,
  openRelease: () => openUrl(RELEASES_URL),
  prepareInstall: () => prepareInstall(),
  platform: currentDesktopPlatform(),
});

let initialized = false;
let automaticCheckTimer: number | null = null;

export function getAppUpdateSnapshot(): AppUpdateSnapshot {
  return controller.snapshot();
}

export function subscribeToAppUpdates(listener: (snapshot: AppUpdateSnapshot) => void): () => void {
  return controller.subscribe(listener);
}

export function checkForAppUpdate(manual: boolean): Promise<void> {
  if (manual && automaticCheckTimer !== null) {
    window.clearTimeout(automaticCheckTimer);
    automaticCheckTimer = null;
  }
  return controller.check(manual);
}

export const downloadAppUpdate = (): Promise<void> => controller.download();
export const installAppUpdate = (): Promise<void> => controller.install();
export const restartAfterAppUpdate = (): Promise<void> => controller.restart();
export const cancelAppUpdate = (): Promise<void> => controller.cancel();
export const retryAppUpdate = (): Promise<void> => controller.retry();
export const openUpdateRecoveryRelease = (): Promise<void> => controller.openRecoveryRelease();

export function setBeforeAppUpdateInstall(callback: () => Promise<void>): void {
  prepareInstall = callback;
}

export function initializeAppUpdateCheck(): void {
  if (initialized) return;
  initialized = true;
  void controller.loadCurrentVersion();
  automaticCheckTimer = window.setTimeout(() => {
    automaticCheckTimer = null;
    if (controller.snapshot().phase === "idle") void controller.check(false);
  }, 1400);
}
