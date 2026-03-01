import { LocalStorage } from "@raycast/api";
import type { Todo } from "./notes-api";

const KEY = "pm-undo-todo";

export interface UndoState {
  notesPath: string;
  projectName: string;
  todo: Todo;
}

export async function saveUndoState(
  notesPath: string,
  projectName: string,
  todo: Todo,
): Promise<void> {
  const undoneTodo: Todo = {
    ...todo,
    checked: true,
    rawLine: todo.rawLine.replace(/\[ \]/, "[x]"),
  };
  await LocalStorage.setItem(
    KEY,
    JSON.stringify({ notesPath, projectName, todo: undoneTodo }),
  );
}

export async function getUndoState(): Promise<UndoState | null> {
  const raw = await LocalStorage.getItem<string>(KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as UndoState & { projectName?: string };
    if (!parsed.projectName) return null;
    return parsed as UndoState;
  } catch {
    return null;
  }
}

export async function clearUndoState(): Promise<void> {
  await LocalStorage.removeItem(KEY);
}
