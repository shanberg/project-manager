import path from "path";
import { mkdir, readFile, writeFile } from "fs/promises";
import { getConfigDir } from "./pm";

/**
 * Window-behavior toggles shared with the PM Panel app via `panel-settings.json` in the pm config
 * dir. The panel watches this file and applies changes live (and reads it on launch).
 */
export interface PanelSettings {
  /** Keep the panel visible when it loses focus instead of auto-hiding. */
  pinned: boolean;
  /** Float the panel above all other windows (always-on-top). */
  floating: boolean;
}

const PANEL_SETTINGS_FILE = "panel-settings.json";

function settingsPath(configPathOverride?: string): string {
  return path.join(getConfigDir(configPathOverride), PANEL_SETTINGS_FILE);
}

/** Read panel settings; returns defaults (all off) when the file is missing or unparseable. */
export async function readPanelSettings(
  configPathOverride?: string,
): Promise<PanelSettings> {
  try {
    const raw = await readFile(settingsPath(configPathOverride), "utf-8");
    const parsed = JSON.parse(raw) as Partial<PanelSettings>;
    return {
      pinned: parsed.pinned === true,
      floating: parsed.floating === true,
    };
  } catch {
    return { pinned: false, floating: false };
  }
}

/** Persist panel settings, matching the panel's pretty-printed JSON shape. */
export async function writePanelSettings(
  settings: PanelSettings,
  configPathOverride?: string,
): Promise<void> {
  const dir = getConfigDir(configPathOverride);
  await mkdir(dir, { recursive: true });
  await writeFile(
    settingsPath(configPathOverride),
    JSON.stringify(settings, null, 2),
    "utf-8",
  );
}

/** Flip one setting and persist. Returns the new value of that key. */
export async function togglePanelSetting(
  key: keyof PanelSettings,
  configPathOverride?: string,
): Promise<boolean> {
  const current = await readPanelSettings(configPathOverride);
  const next: PanelSettings = { ...current, [key]: !current[key] };
  await writePanelSettings(next, configPathOverride);
  return next[key];
}
