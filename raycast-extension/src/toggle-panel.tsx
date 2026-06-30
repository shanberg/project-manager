import { spawn } from "child_process";
import { existsSync, readdirSync } from "fs";
import path from "path";
import { closeMainWindow, getPreferenceValues, showHUD } from "@raycast/api";
import type { PreferenceValues } from "./lib/types";

/** Resolve a `.app` bundle to its inner executable; pass through a direct binary path. */
function resolveExecutable(p: string): string {
  if (!p.endsWith(".app")) return p;
  const macosDir = path.join(p, "Contents", "MacOS");
  // The executable name isn't always the bundle name (here: bundle "PM Panel",
  // binary "pm-panel"), so read Contents/MacOS and pick the real entry.
  try {
    const entries = readdirSync(macosDir);
    const appName = path.basename(p, ".app");
    const chosen = entries.find((e) => e === appName) ?? entries[0];
    if (chosen) return path.join(macosDir, chosen);
  } catch {
    /* fall through to best-guess below */
  }
  return path.join(macosDir, path.basename(p, ".app"));
}

export default async function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const configured = prefs.panelPath?.trim();
  if (!configured) {
    await showHUD("Set the Panel Path in extension preferences");
    return;
  }
  const bin = resolveExecutable(configured);
  if (!existsSync(bin)) {
    await showHUD(`Panel not found: ${bin}`);
    return;
  }
  try {
    // The panel's single-instance plugin routes this to the running window (toggling it) or,
    // if nothing is running, cold-starts and shows. Detach so it outlives this command.
    const child = spawn(bin, ["--toggle"], { detached: true, stdio: "ignore" });
    child.unref();
    await closeMainWindow();
  } catch (err) {
    await showHUD(`Error: ${err instanceof Error ? err.message : String(err)}`);
  }
}
