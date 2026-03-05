import { spawn } from "child_process";
import path from "path";
import os from "os";
import { existsSync } from "fs";
import { mkdir, readFile, writeFile } from "fs/promises";
import type { PreferenceValues } from "./types";

export const DEFAULT_DOMAINS: Record<string, string> = {
  W: "Work",
  P: "Personal",
  L: "Learning",
  O: "Other",
};

export const DEFAULT_SUBFOLDERS = [
  "deliverables",
  "docs",
  "resources",
  "previews",
  "working files",
];

export interface PmPaths {
  activePath: string;
  archivePath: string;
}

/** Get activePath and archivePath from pm config. Single source of truth. */
export async function getPmPaths(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
): Promise<PmPaths> {
  const env = getConfigEnv(prefs.configPath);
  const { stdout } = await runPm(["config", "get"], env, prefs.pmCliPath);
  const config = JSON.parse(stdout.trim()) as {
    activePath?: string;
    archivePath?: string;
  };
  const activePath = config.activePath ?? "";
  const archivePath = config.archivePath ?? "";
  if (!activePath || !archivePath) {
    throw new Error("pm config missing paths. Run: pm config init");
  }
  return {
    activePath: path.normalize(expandPath(activePath)),
    archivePath: path.normalize(expandPath(archivePath)),
  };
}

/** Check if pm config exists and has both paths. Returns null when config is missing or incomplete (for first-run detection).
 * If the pm CLI is unavailable, tries reading config.json directly so the configured view still shows after first-run. */
export async function getPmPathsIfPresent(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
): Promise<PmPaths | null> {
  async function fromConfigJson(): Promise<PmPaths | null> {
    const configPath = path.join(getConfigDir(prefs.configPath), "config.json");
    try {
      const data = await readFile(configPath, "utf-8");
      const config = JSON.parse(data) as { activePath?: string; archivePath?: string };
      const activePath = (config.activePath ?? "").trim();
      const archivePath = (config.archivePath ?? "").trim();
      if (!activePath || !archivePath) return null;
      return {
        activePath: path.normalize(expandPath(activePath)),
        archivePath: path.normalize(expandPath(archivePath)),
      };
    } catch {
      return null;
    }
  }

  try {
    const env = getConfigEnv(prefs.configPath);
    const { stdout, code } = await runPm(
      ["config", "get"],
      env,
      prefs.pmCliPath,
    );
    if (code !== 0) return fromConfigJson();
    const config = JSON.parse(stdout.trim()) as {
      activePath?: string;
      archivePath?: string;
    };
    const activePath = (config.activePath ?? "").trim();
    const archivePath = (config.archivePath ?? "").trim();
    if (!activePath || !archivePath) return null;
    return {
      activePath: path.normalize(expandPath(activePath)),
      archivePath: path.normalize(expandPath(archivePath)),
    };
  } catch {
    return fromConfigJson();
  }
}

export interface WriteInitialConfigOptions {
  activePath: string;
  archivePath: string;
  useObsidianCLI: boolean;
}

/** Create initial pm config (for first-run). Writes config.json; does not create the active/archive directories. */
export async function writeInitialConfig(
  prefs: Pick<PreferenceValues, "configPath">,
  options: WriteInitialConfigOptions,
): Promise<void> {
  const dir = getConfigDir(prefs.configPath);
  await mkdir(dir, { recursive: true });
  const config = {
    activePath: options.activePath.trim(),
    archivePath: options.archivePath.trim(),
    domains: DEFAULT_DOMAINS,
    subfolders: DEFAULT_SUBFOLDERS,
    useObsidianCLI: options.useObsidianCLI,
  };
  const configPath = path.join(dir, "config.json");
  await writeFile(
    configPath,
    JSON.stringify(config, null, 2),
    "utf-8",
  );
}

/** Load domains from pm config. Uses DEFAULT_DOMAINS if config missing or invalid. */
export async function getConfigDomains(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
): Promise<Record<string, string>> {
  const env = getConfigEnv(prefs.configPath);
  try {
    const { stdout } = await runPm(
      ["config", "get", "domains"],
      env,
      prefs.pmCliPath,
    );
    const parsed = JSON.parse(stdout.trim()) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const out: Record<string, string> = {};
      for (const [k, v] of Object.entries(parsed)) {
        if (typeof k === "string" && typeof v === "string") out[k] = v;
      }
      if (Object.keys(out).length > 0) return out;
    }
  } catch {
    // fall through to default
  }
  return { ...DEFAULT_DOMAINS };
}

/** Load subfolders (project structure) from pm config. Uses DEFAULT_SUBFOLDERS if config missing or invalid. */
export async function getConfigSubfolders(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
): Promise<string[]> {
  const env = getConfigEnv(prefs.configPath);
  try {
    const { stdout } = await runPm(
      ["config", "get", "subfolders"],
      env,
      prefs.pmCliPath,
    );
    const parsed = JSON.parse(stdout.trim()) as unknown;
    if (Array.isArray(parsed)) {
      const out = parsed.filter(
        (v): v is string => typeof v === "string" && v.trim().length > 0,
      );
      if (out.length > 0) return out;
    }
  } catch {
    // fall through to default
  }
  return [...DEFAULT_SUBFOLDERS];
}

const HOMEBREW_PM_PATHS = ["/opt/homebrew/bin/pm", "/usr/local/bin/pm"];

function resolvePmPath(cliPathOverride?: string): string {
  const raw = cliPathOverride?.trim();
  if (raw) return path.normalize(expandPath(raw));
  for (const p of HOMEBREW_PM_PATHS) {
    if (existsSync(p)) return p;
  }
  throw new Error(
    "pm not found. Install via Homebrew: brew install pm. Or set pmCliPath in preferences.",
  );
}

function expandPath(p: string): string {
  return p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

export function getConfigDir(configPathOverride?: string): string {
  const raw = configPathOverride?.trim();
  if (raw) return path.normalize(expandPath(raw));
  const xdg = process.env.XDG_CONFIG_HOME;
  if (xdg) return path.join(xdg, "pm");
  return path.join(os.homedir(), ".config", "pm");
}

export function getConfigEnv(
  configPathOverride?: string,
): Record<string, string> {
  const raw = configPathOverride?.trim();
  if (!raw) return {};
  return { PM_CONFIG_HOME: getConfigDir(configPathOverride) };
}

export function buildEnv(
  prefs: Pick<PreferenceValues, "configPath">,
): Record<string, string> {
  return getConfigEnv(prefs.configPath);
}

type PrefsForNotes = Pick<
  PreferenceValues,
  "configPath" | "pmCliPath" | "useObsidianCLI" | "obsidianVault" | "obsidianVaultRoot"
>;

/** Sync Obsidian CLI preferences from extension to pm config so pm uses them for notes read/write.
 * When useObsidianCLI is true, throws on failure so notes commands don't silently use direct I/O.
 * When useObsidianCLI is false, best-effort (swallows errors). */
export async function syncObsidianPrefsToPmConfig(
  prefs: PrefsForNotes,
): Promise<void> {
  const env = buildEnv(prefs);
  const pmPath = prefs.pmCliPath;
  const requireSync = !!prefs.useObsidianCLI;
  try {
    await runPm(
      ["config", "set", "useObsidianCLI", prefs.useObsidianCLI ? "true" : "false"],
      env,
      pmPath,
    );
    const vault = prefs.obsidianVault?.trim() ?? "";
    const vaultPath = prefs.obsidianVaultRoot?.trim() ?? "";
    await runPm(["config", "set", "obsidianVault", vault], env, pmPath);
    await runPm(["config", "set", "obsidianVaultPath", vaultPath], env, pmPath);
  } catch (err) {
    if (requireSync) throw err;
    // useObsidianCLI off: pm config may not exist yet; let the actual notes command fail or use defaults
  }
}

/** Run pm with extension prefs. Uses pm config only; no path overrides. When running a notes command, syncs Obsidian CLI prefs to pm config first. */
export async function runPmWithPrefs(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath"> & Partial<Pick<PreferenceValues, "useObsidianCLI" | "obsidianVault" | "obsidianVaultRoot">>,
  args: string[],
): Promise<{ stdout: string; stderr: string; code: number | null }> {
  if (args[0] === "notes" && ("useObsidianCLI" in prefs || "obsidianVault" in prefs || "obsidianVaultRoot" in prefs)) {
    await syncObsidianPrefsToPmConfig(prefs as PrefsForNotes);
  }
  return runPm(args, buildEnv(prefs), prefs.pmCliPath);
}

export async function runPm(
  args: string[],
  env: Record<string, string> = {},
  cliPathOverride?: string,
): Promise<{ stdout: string; stderr: string; code: number | null }> {
  const fullEnv = { ...process.env, ...env };
  const pmPath = resolvePmPath(cliPathOverride);
  return new Promise((resolve, reject) => {
    const child = spawn(pmPath, args, {
      env: fullEnv,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    child.stdout?.on("data", (c) => stdoutChunks.push(c));
    child.stderr?.on("data", (c) => stderrChunks.push(c));
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        stdout: Buffer.concat(stdoutChunks).toString("utf-8"),
        stderr: Buffer.concat(stderrChunks).toString("utf-8"),
        code: code ?? null,
      });
    });
  });
}

const PM_STDIN_TIMEOUT_MS = 30_000;

/** Run pm with stdin. Used for `pm notes write` with JSON body. */
export function runPmWithStdin(
  args: string[],
  env: Record<string, string>,
  cliPathOverride: string | undefined,
  stdinContent: string,
): Promise<{ stdout: string; stderr: string; code: number | null }> {
  const fullEnv = { ...process.env, ...env };
  const pmPath = resolvePmPath(cliPathOverride);
  return new Promise((resolve, reject) => {
    const child = spawn(pmPath, args, {
      env: fullEnv,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    child.stdout?.on("data", (c) => stdoutChunks.push(c));
    child.stderr?.on("data", (c) => stderrChunks.push(c));

    let settled = false;
    function finish(
      result:
        | { stdout: string; stderr: string; code: number | null }
        | { error: Error },
    ) {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      child.stdin?.destroy();
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
      if ("error" in result) reject(result.error);
      else resolve(result);
    }

    const timeoutId = setTimeout(() => {
      finish({
        error: new Error(
          `pm notes write timed out after ${PM_STDIN_TIMEOUT_MS / 1000}s`,
        ),
      });
    }, PM_STDIN_TIMEOUT_MS);

    child.on("error", (err) => finish({ error: err }));
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      resolve({
        stdout: Buffer.concat(stdoutChunks).toString("utf-8"),
        stderr: Buffer.concat(stderrChunks).toString("utf-8"),
        code: code ?? null,
      });
    });
    child.stdin?.write(stdinContent, "utf-8", (err) => {
      if (err) {
        finish({ error: err });
        return;
      }
      child.stdin?.end();
    });
  });
}
