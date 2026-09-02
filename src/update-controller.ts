import type { DesktopPlatform } from "./platform";

export type AppUpdatePhase =
  | "idle"
  | "checking"
  | "current"
  | "available"
  | "downloading"
  | "verifying"
  | "downloaded"
  | "installing"
  | "restart-ready"
  | "cancelled"
  | "error";

export type AppUpdateErrorStage = "check" | "download" | "install" | "restart" | "release" | "";

export interface AppUpdateSnapshot {
  phase: AppUpdatePhase;
  currentVersion: string;
  latestVersion: string;
  releaseNotes: string;
  downloadedBytes: number;
  totalBytes: number | null;
  errorMessage: string;
  errorStage: AppUpdateErrorStage;
  platform: DesktopPlatform;
}

export type UpdateDownloadEvent =
  | { event: "Started"; data: { contentLength?: number } }
  | { event: "Progress"; data: { chunkLength: number } }
  | { event: "Finished" };

export interface UpdateHandle {
  currentVersion: string;
  version: string;
  body?: string;
  download(onEvent?: (event: UpdateDownloadEvent) => void, options?: { timeout?: number }): Promise<void>;
  install(options?: { restartAfterInstall?: boolean }): Promise<void>;
  close(): Promise<void>;
}

export interface UpdateDependencies {
  getVersion(): Promise<string>;
  check(): Promise<UpdateHandle | null>;
  relaunch(): Promise<void>;
  openRelease(): Promise<void>;
  prepareInstall?(): Promise<void>;
  platform: DesktopPlatform;
}

type UpdateListener = (snapshot: AppUpdateSnapshot) => void;

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function initialSnapshot(platform: DesktopPlatform): AppUpdateSnapshot {
  return {
    phase: "idle",
    currentVersion: "",
    latestVersion: "",
    releaseNotes: "",
    downloadedBytes: 0,
    totalBytes: null,
    errorMessage: "",
    errorStage: "",
    platform,
  };
}

export interface AppUpdateController {
  snapshot(): AppUpdateSnapshot;
  subscribe(listener: UpdateListener): () => void;
  loadCurrentVersion(): Promise<void>;
  check(manual: boolean): Promise<void>;
  download(): Promise<void>;
  install(): Promise<void>;
  restart(): Promise<void>;
  cancel(): Promise<void>;
  retry(): Promise<void>;
  openRecoveryRelease(): Promise<void>;
  busy(): boolean;
}

export function createAppUpdateController(dependencies: UpdateDependencies): AppUpdateController {
  let state = initialSnapshot(dependencies.platform);
  let pendingUpdate: UpdateHandle | null = null;
  let actionInFlight: Promise<void> | null = null;
  let manualCheckRequested = false;
  const listeners = new Set<UpdateListener>();

  const snapshot = (): AppUpdateSnapshot => ({ ...state });
  const publish = (next: AppUpdateSnapshot): void => {
    state = next;
    const value = snapshot();
    for (const listener of listeners) listener(value);
  };
  const runOnce = (operation: () => Promise<void>): Promise<void> => {
    if (actionInFlight) return actionInFlight;
    actionInFlight = operation().finally(() => {
      actionInFlight = null;
    });
    return actionInFlight;
  };
  const closePending = async (): Promise<void> => {
    const update = pendingUpdate;
    pendingUpdate = null;
    if (update) await update.close();
  };
  const fail = (stage: AppUpdateErrorStage, error: unknown): void => {
    publish({ ...state, phase: "error", errorStage: stage, errorMessage: errorText(error) });
  };

  const controller: AppUpdateController = {
    snapshot,
    subscribe(listener) {
      listeners.add(listener);
      listener(snapshot());
      return () => listeners.delete(listener);
    },
    async loadCurrentVersion() {
      try {
        publish({ ...state, currentVersion: await dependencies.getVersion() });
      } catch {
        // A failed version label must not block reading or a later updater check.
      }
    },
    check(manual) {
      manualCheckRequested ||= manual;
      return runOnce(async () => {
        publish({ ...state, phase: "checking", errorMessage: "", errorStage: "" });
        try {
          await closePending();
          const update = await dependencies.check();
          pendingUpdate = update;
          if (!update) {
            publish({
              ...state,
              phase: "current",
              latestVersion: "",
              releaseNotes: "",
              downloadedBytes: 0,
              totalBytes: null,
              errorMessage: "",
              errorStage: "",
            });
            return;
          }
          publish({
            ...state,
            phase: "available",
            currentVersion: update.currentVersion || state.currentVersion,
            latestVersion: update.version,
            releaseNotes: update.body?.trim() ?? "",
            downloadedBytes: 0,
            totalBytes: null,
            errorMessage: "",
            errorStage: "",
          });
        } catch (error) {
          if (manualCheckRequested) fail("check", error);
          else publish({ ...state, phase: "idle", errorMessage: "", errorStage: "" });
        } finally {
          manualCheckRequested = false;
        }
      });
    },
    download() {
      const canRetryDownload = state.phase === "error" && state.errorStage === "download";
      if (!pendingUpdate || (state.phase !== "available" && !canRetryDownload)) return Promise.resolve();
      return runOnce(async () => {
        publish({ ...state, phase: "downloading", downloadedBytes: 0, totalBytes: null, errorMessage: "", errorStage: "" });
        try {
          await pendingUpdate?.download(
            (event) => {
              if (event.event === "Started") {
                publish({ ...state, totalBytes: event.data.contentLength ?? null });
              } else if (event.event === "Progress") {
                publish({ ...state, downloadedBytes: state.downloadedBytes + event.data.chunkLength });
              } else {
                // Finished is emitted before framework signature verification.
                publish({ ...state, phase: "verifying" });
              }
            },
            { timeout: 15 * 60_000 },
          );
          publish({ ...state, phase: "downloaded", errorMessage: "", errorStage: "" });
        } catch (error) {
          fail("download", error);
        }
      });
    },
    install() {
      if (!pendingUpdate || state.phase !== "downloaded") return Promise.resolve();
      return runOnce(async () => {
        publish({ ...state, phase: "installing", errorMessage: "", errorStage: "" });
        try {
          await dependencies.prepareInstall?.();
          await pendingUpdate?.install({ restartAfterInstall: false });
          if (dependencies.platform !== "windows") publish({ ...state, phase: "restart-ready" });
          // On Windows the plugin exits Satori after launching the visible installer.
        } catch (error) {
          fail("install", error);
        }
      });
    },
    restart() {
      if (state.phase !== "restart-ready") return Promise.resolve();
      return runOnce(async () => {
        try {
          await dependencies.relaunch();
        } catch (error) {
          fail("restart", error);
        }
      });
    },
    cancel() {
      if (actionInFlight || !["available", "downloaded", "error"].includes(state.phase)) return Promise.resolve();
      return runOnce(async () => {
        try {
          await closePending();
          publish({
            ...state,
            phase: "cancelled",
            latestVersion: "",
            releaseNotes: "",
            downloadedBytes: 0,
            totalBytes: null,
            errorMessage: "",
            errorStage: "",
          });
        } catch (error) {
          fail("download", error);
        }
      });
    },
    retry() {
      if (state.phase !== "error") return Promise.resolve();
      if (state.errorStage === "download" && pendingUpdate) return controller.download();
      if (state.errorStage === "install" && pendingUpdate) {
        publish({ ...state, phase: "downloaded", errorMessage: "", errorStage: "" });
        return controller.install();
      }
      if (state.errorStage === "restart") {
        publish({ ...state, phase: "restart-ready", errorMessage: "", errorStage: "" });
        return controller.restart();
      }
      return controller.check(true);
    },
    openRecoveryRelease() {
      if (state.phase !== "error") return Promise.resolve();
      return runOnce(async () => {
        try {
          await dependencies.openRelease();
        } catch (error) {
          fail("release", error);
        }
      });
    },
    busy() {
      return actionInFlight !== null;
    },
  };
  return controller;
}
