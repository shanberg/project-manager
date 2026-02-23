import { LocalStorage } from "@raycast/api";
import type { Todo } from "project-manager/notes";

const KEY = "pm-undo-todo";

export interface UndoState {
  notesPath: string;
  todo: Todo;
}

export async function saveUndoState(notesPath: string, todo: Todo): Promise<void> {
  const undoneTodo: Todo = {
    ...todo,
    checked: true,
    rawLine: todo.rawLine.replace(/\[ \]/, "[x]"),
  };
  await LocalStorage.setItem(KEY, JSON.stringify({ notesPath, todo: undoneTodo }));
}

export async function getUndoState(): Promise<UndoState | null> {
  const raw = await LocalStorage.getItem<string>(KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as UndoState;
  } catch {
    return null;
  }
}

export async function clearUndoState(): Promise<void> {
  await LocalStorage.removeItem(KEY);
}
