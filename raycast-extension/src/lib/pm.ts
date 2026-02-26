import { exec } from "child_process";
import { promisify } from "util";
import path from "path";
import os from "os";
import { mkdir, writeFile } from "fs/promises";
import { existsSync } from "fs";
import {
  DEFAULT_DOMAINS,
  DEFAULT_SUBFOLDERS,
} from "@shanberg/project-manager/types";
import type { PreferenceValues } from "./types";

/** Load domains from pm config. Uses DEFAULT_DOMAINS if config missing or invalid. */
export async function getConfigDomains(
  prefs: Pick<
    PreferenceValues,
    "activePath" | "archivePath" | "configPath" | "pmCliPath"
  >,
): Promise<Record<string, string>> {
  await ensureConfig(prefs.activePath, prefs.archivePath, prefs.configPath);
  const env = buildEnv(prefs as PreferenceValues);
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
  prefs: Pick<
    PreferenceValues,
    "activePath" | "archivePath" | "configPath" | "pmCliPath"
  >,
): Promise<string[]> {
  await ensureConfig(prefs.activePath, prefs.archivePath, prefs.configPath);
  const env = buildEnv(prefs as PreferenceValues);
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

const execAsync = promisify(exec);

function resolvePmPath(cliPathOverride?: string): string {
  const raw = cliPathOverride?.trim();
  if (raw) return path.normalize(expandPath(raw));
  const candidates = [
    path.join(os.homedir(), "dev", "project-manager", "dist", "cli.js"),
    path.join(process.cwd(), "..", "dist", "cli.js"),
    path.join(process.cwd(), "..", "..", "dist", "cli.js"),
    path.join(os.homedir(), "Projects", "project-manager", "dist", "cli.js"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return "pm";
}

function expandPath(p: string): string {
  return p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

function getConfigDir(configPathOverride?: string): string {
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

export function buildEnv(prefs: PreferenceValues): Record<string, string> {
  return {
    PM_ACTIVE_PATH: prefs.activePath,
    PM_ARCHIVE_PATH: prefs.archivePath,
    ...getConfigEnv(prefs.configPath),
  };
}

/** Ensure config exists, then run pm with prefs. Reduces boilerplate in commands. */
export async function runPmWithPrefs(
  prefs: PreferenceValues,
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  await ensureConfig(prefs.activePath, prefs.archivePath, prefs.configPath);
  return runPm(args, buildEnv(prefs), prefs.pmCliPath);
}

export async function ensureConfig(
  activePath: string,
  archivePath: string,
  configPathOverride?: string,
): Promise<void> {
  const configDir = getConfigDir(configPathOverride);
  const configPath = path.join(configDir, "config.json");

  if (existsSync(configPath)) return;

  const config = {
    activePath,
    archivePath,
    domains: DEFAULT_DOMAINS,
    subfolders: DEFAULT_SUBFOLDERS,
  };
  await mkdir(configDir, { recursive: true });
  await writeFile(configPath, JSON.stringify(config, null, 2), "utf-8");
}

export async function runPm(
  args: string[],
  env: Record<string, string> = {},
  cliPathOverride?: string,
): Promise<{ stdout: string; stderr: string }> {
  const fullEnv = { ...process.env, ...env };
  const pmPath = resolvePmPath(cliPathOverride);

  /** Escape for zsh -c: wrap in single quotes, escape single quotes as '\'' */
  function shellArg(a: string): string {
    return `'${a.replace(/'/g, "'\\''")}'`;
  }
  let innerCmd: string;
  if (pmPath === "pm") {
    innerCmd = `pm ${args.map(shellArg).join(" ")}`;
  } else {
    innerCmd = `node ${shellArg(pmPath)} ${args.map(shellArg).join(" ")}`;
  }
  const cmd = `/bin/zsh -l -c ${JSON.stringify(innerCmd)}`;

  const { stdout, stderr } = await execAsync(cmd, {
    env: fullEnv,
    maxBuffer: 10 * 1024 * 1024,
  });
  return { stdout, stderr };
}
