import { getPreferenceValues } from "@raycast/api";
import { mkdir, readFile, writeFile, unlink } from "fs/promises";
import path from "path";
import { projectKey, type ProjectKey } from "./recent-projects";
import { getConfigDir } from "./pm";
import type { PreferenceValues } from "./types";

const FOCUSED_FILE = "focused.json";

function getFocusedFilePath(): string {
  const prefs = getPreferenceValues<PreferenceValues>();
  return path.join(getConfigDir(prefs.configPath), FOCUSED_FILE);
}

export async function setFocusedProject(
  basePath: string,
  name: string,
): Promise<void> {
  const key = projectKey(basePath, name);
  const filePath = getFocusedFilePath();
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, JSON.stringify({ projectKey: key }) + "\n", "utf-8");
}

export async function getFocusedProject(): Promise<ProjectKey | null> {
  const filePath = getFocusedFilePath();
  try {
    const raw = await readFile(filePath, "utf-8");
    const data = JSON.parse(raw) as { projectKey?: string };
    const key = data?.projectKey?.trim();
    return key && key.length > 0 ? key : null;
  } catch {
    return null;
  }
}

export async function clearFocusedProject(): Promise<void> {
  const filePath = getFocusedFilePath();
  try {
    await unlink(filePath);
  } catch {
    /* file may not exist */
  }
}

export function parseProjectKey(
  key: ProjectKey,
): { basePath: string; name: string } | null {
  const idx = key.indexOf(":");
  if (idx < 0) return null;
  return { basePath: key.slice(0, idx), name: key.slice(idx + 1) };
}

export function getProjectCode(name: string): string {
  const m = name.match(/^((?:M|DE|P|I)-\d+)/);
  return m ? m[1] : name;
}

export function getReadableProjectName(name: string): string {
  const code = getProjectCode(name);
  const rest = name
    .slice(code.length)
    .replace(/^[\s-]+/, "")
    .trim();
  return rest || name;
}
