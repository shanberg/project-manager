import { LocalStorage } from "@raycast/api";
import { projectKey, type ProjectKey } from "./recent-projects";

const KEY = "pm-focused-project";

export async function setFocusedProject(basePath: string, name: string): Promise<void> {
  await LocalStorage.setItem(KEY, projectKey(basePath, name));
}

export async function getFocusedProject(): Promise<ProjectKey | null> {
  const raw = await LocalStorage.getItem<string>(KEY);
  return raw ?? null;
}

export async function clearFocusedProject(): Promise<void> {
  await LocalStorage.removeItem(KEY);
}

export function parseProjectKey(key: ProjectKey): { basePath: string; name: string } | null {
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
  const rest = name.slice(code.length).replace(/^[\s-]+/, "").trim();
  return rest || name;
}
