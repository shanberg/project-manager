import { LocalStorage } from "@raycast/api";

const KEY = "pm-task-timing";

interface StoredState {
  taskKey: string;
  seenAt: number;
}

export async function getTaskTiming(): Promise<StoredState | null> {
  const raw = await LocalStorage.getItem<string>(KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as StoredState;
  } catch {
    return null;
  }
}

export async function setTaskTiming(taskKey: string): Promise<void> {
  await LocalStorage.setItem(
    KEY,
    JSON.stringify({ taskKey, seenAt: Date.now() }),
  );
}

export async function clearTaskTiming(): Promise<void> {
  await LocalStorage.removeItem(KEY);
}

export function taskKey(notesPath: string, rawLine: string): string {
  return `${notesPath}::${rawLine}`;
}
