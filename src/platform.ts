export interface PrimaryModifierState {
  metaKey: boolean;
  ctrlKey: boolean;
}

export interface WheelModifierState {
  ctrlKey: boolean;
}

export type DesktopPlatform = "macos" | "windows" | "other";

export function desktopPlatformFromNavigator(platform: string): DesktopPlatform {
  if (/^mac/i.test(platform)) return "macos";
  if (/^win/i.test(platform)) return "windows";
  return "other";
}

function currentDesktopPlatform(): DesktopPlatform {
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

export type ReleaseUpdatePhase = "idle" | "checking" | "current" | "available" | "release-only" | "error";

export interface ReleaseUpdatePresentationInput {
  phase: ReleaseUpdatePhase;
  latestVersion: string;
}

export interface ReleaseUpdatePresentation {
  status: string;
  action: string;
  title: string;
}

function releaseVersionLabel(version: string): string {
  const normalized = version.trim().replace(/^[vV]/, "");
  return normalized ? `v${normalized}` : "";
}

/** Copy shared by macOS and Windows update controls. */
export function updatePresentation(input: ReleaseUpdatePresentationInput): ReleaseUpdatePresentation | null {
  const latest = releaseVersionLabel(input.latestVersion);
  if (input.phase === "available") {
    return {
      status: "发现适用的新版本",
      action: `下载 ${latest}`,
      title: `在浏览器中打开 Satori ${latest} 下载页`,
    };
  }
  if (input.phase === "release-only") {
    return {
      status: "新版本暂无适用安装包",
      action: "查看 Releases",
      title: `查看 Satori ${latest} 官方 Release`,
    };
  }
  return null;
}
