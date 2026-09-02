interface PrimaryModifierState {
  metaKey: boolean;
  ctrlKey: boolean;
}

interface WheelModifierState {
  ctrlKey: boolean;
}

export type DesktopPlatform = "macos" | "windows" | "other";

export function desktopPlatformFromNavigator(platform: string): DesktopPlatform {
  if (/^mac/i.test(platform)) return "macos";
  if (/^win/i.test(platform)) return "windows";
  return "other";
}

export function currentDesktopPlatform(): DesktopPlatform {
  const platform = typeof navigator === "undefined" ? "" : navigator.platform;
  return desktopPlatformFromNavigator(platform);
}

/** Return the final path component for both POSIX and Windows file paths. */
export function fileNameFromPath(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] || path;
}

/** Command is primary on macOS and Control is primary on Windows. */
export function hasPrimaryModifier(
  event: PrimaryModifierState,
  platform: DesktopPlatform = currentDesktopPlatform(),
): boolean {
  return platform === "macos" ? event.metaKey : event.ctrlKey;
}

/** Ctrl+wheel belongs exclusively to zoom and must never reach page flipping. */
export function shouldHandlePageFlipWheel(event: WheelModifierState): boolean {
  return !event.ctrlKey;
}

export function versionLabel(version: string): string {
  const normalized = version.trim().replace(/^[vV]/, "");
  return normalized ? `v${normalized}` : "";
}

export interface DownloadProgressPresentation {
  label: string;
  percent: number | null;
}

export function downloadProgressPresentation(downloadedBytes: number, totalBytes: number | null): DownloadProgressPresentation {
  const downloaded = Math.max(0, downloadedBytes);
  if (!totalBytes || totalBytes <= 0) {
    return { label: `已下载 ${formatBytes(downloaded)}`, percent: null };
  }
  const bounded = Math.min(downloaded, totalBytes);
  return {
    label: `已下载 ${formatBytes(bounded)} / ${formatBytes(totalBytes)}`,
    percent: Math.min(100, Math.round((bounded / totalBytes) * 100)),
  };
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
