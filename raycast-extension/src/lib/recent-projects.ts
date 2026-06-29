import { LocalStorage } from "@raycast/api";

const KEY = "pm-recent-projects";
const MAX_RECENT = 20;

export type ProjectKey = string;

export function projectKey(basePath: string, name: string): ProjectKey {
  return `${basePath}:${name}`;
}

export async function recordRecentProject(key: ProjectKey): Promise<void> {
  const raw = await LocalStorage.getItem<string>(KEY);
  const recent: string[] = raw ? JSON.parse(raw) : [];
  const filtered = recent.filter((k) => k !== key);
  filtered.unshift(key);
  const trimmed = filtered.slice(0, MAX_RECENT);
  await LocalStorage.setItem(KEY, JSON.stringify(trimmed));
}

export async function replaceRecentProjectKey(
  oldKey: ProjectKey,
  newKey: ProjectKey,
): Promise<void> {
  if (oldKey === newKey) return;
  const raw = await LocalStorage.getItem<string>(KEY);
  const recent: string[] = raw ? JSON.parse(raw) : [];
  const mapped = recent.map((k) => (k === oldKey ? newKey : k));
  const deduped: string[] = [];
  for (const k of mapped) {
    if (!deduped.includes(k)) deduped.push(k);
  }
  await LocalStorage.setItem(KEY, JSON.stringify(deduped.slice(0, MAX_RECENT)));
}

export async function getRecentProjectKeys(): Promise<ProjectKey[]> {
  const raw = await LocalStorage.getItem<string>(KEY);
  return raw ? JSON.parse(raw) : [];
}
