import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Match the host's Git Bash/MSYS, Cygwin and WSL drive-path conversion.
export function normalizeWindowsShellPath(filePath: string): string {
  if (!filePath.startsWith("/") || filePath.startsWith("//") || filePath.includes("\\")) return filePath;
  const match = filePath.match(/^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/(.*))?$/i);
  if (!match) return filePath;
  const suffix = match[2]?.replaceAll("/", "\\");
  return `${match[1].toUpperCase()}:\\${suffix ?? ""}`;
}

// Pi's getPackageDir uses normalizePath with defaults (no trimming or cleanup).
function normalizeHostPackageDir(input: string, homeDir = homedir()): string {
  const normalized = process.platform === "win32" ? normalizeWindowsShellPath(input) : input;
  if (normalized === "~") return homeDir;
  if (normalized.startsWith("~/") || (process.platform === "win32" && normalized.startsWith("~\\"))) {
    return join(homeDir, normalized.slice(2));
  }
  return /^file:\/\//.test(normalized) ? fileURLToPath(normalized) : normalized;
}

/** Resolve the host package, never the extension's potentially private SDK copy. */
export function detectHostPiVersion(argv1: string | undefined, packageDir?: string, homeDir?: string): string | undefined {
  try {
    if (packageDir) {
      const dir = normalizeHostPackageDir(packageDir, homeDir);
      const pkg: { version?: unknown } | null = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
      return typeof pkg?.version === "string" ? pkg.version : undefined;
    }
    if (!argv1) return undefined;
    let dir = dirname(realpathSync(argv1));
    for (let depth = 0; depth < 8; depth++) {
      let pkg: { name?: unknown; version?: unknown } | null | undefined;
      try {
        pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
      } catch (error) {
        // Missing manifests are normal on the walk; other failures are unknown.
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") return undefined;
      }
      if (pkg?.name === "@earendil-works/pi-coding-agent" || pkg?.name === "@mariozechner/pi-coding-agent") {
        return typeof pkg.version === "string" ? pkg.version : undefined;
      }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch {
    // Unreadable overrides/entrypoints and non-Node hosts fail closed.
  }
  return undefined;
}

// Resolve once per module load, including an unknown result.
export const HOST_PI_VERSION = detectHostPiVersion(process.argv[1], process.env.PI_PACKAGE_DIR);

// Unknown/dev versions must never send a literal slash prompt to an old host.
export function supportsSessionControlDispatch(version: unknown): boolean {
  if (typeof version !== "string") return false;
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(version);
  if (!match) return false;
  const [major, minor, patch] = match.slice(1, 4).map(Number);
  const prerelease = match[4];
  if (![major, minor, patch].every(Number.isSafeInteger)) return false;
  if (prerelease?.split(".").some(part => /^0\d+$/.test(part))) return false;
  return major! > 0 || minor! > 84 || (minor === 84 && (patch! > 2 || (patch === 2 && !prerelease)));
}
