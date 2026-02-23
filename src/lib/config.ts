import { readFile, writeFile, mkdir } from "fs/promises";
import { existsSync } from "fs";
import path from "path";
import os from "os";
import type { PmConfig } from "../types.js";
import { DEFAULT_DOMAINS, DEFAULT_SUBFOLDERS } from "../types.js";

export function getConfigDir(): string {
  const pmConfig = process.env.PM_CONFIG_HOME;
  if (pmConfig) return pmConfig;
  const xdg = process.env.XDG_CONFIG_HOME;
  if (xdg) return path.join(xdg, "pm");
  return path.join(os.homedir(), ".config", "pm");
}

export function getConfigPath(): string {
  return path.join(getConfigDir(), "config.json");
}

export async function loadConfig(): Promise<PmConfig | null> {
  const configPath = getConfigPath();
  if (!existsSync(configPath)) return null;

  try {
    const raw = await readFile(configPath, "utf-8");
    return JSON.parse(raw) as PmConfig;
  } catch {
    return null;
  }
}

export async function saveConfig(config: PmConfig): Promise<void> {
  const configDir = getConfigDir();
  const configPath = getConfigPath();

  await mkdir(configDir, { recursive: true });
  await writeFile(configPath, JSON.stringify(config, null, 2), "utf-8");
}

export function createDefaultConfig(
  activePath: string,
  archivePath: string
): PmConfig {
  return {
    activePath,
    archivePath,
    domains: { ...DEFAULT_DOMAINS },
    subfolders: [...DEFAULT_SUBFOLDERS],
  };
}

/** Resolve active and archive paths. Env vars PM_ACTIVE_PATH and PM_ARCHIVE_PATH override config. */
export function resolvePaths(config: PmConfig): {
  activePath: string;
  archivePath: string;
} {
  const envActive = process.env.PM_ACTIVE_PATH;
  const envArchive = process.env.PM_ARCHIVE_PATH;
  if (envActive && envArchive) {
    return { activePath: envActive, archivePath: envArchive };
  }

  if (config.activePath && config.archivePath) {
    return { activePath: config.activePath, archivePath: config.archivePath };
  }
  if (config.paraPath) {
    return {
      activePath: path.join(config.paraPath, "active"),
      archivePath: path.join(config.paraPath, "archive"),
    };
  }
  throw new Error("Config must have activePath and archivePath (or paraPath, or PM_ACTIVE_PATH/PM_ARCHIVE_PATH env)");
}

