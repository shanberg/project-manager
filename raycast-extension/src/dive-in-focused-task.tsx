import { getPreferenceValues, showHUD } from "@raycast/api";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { refreshMenubar } from "./lib/menubar-refresh";
import { getNotes, resolveNotesPath, setFocusToTodoInNotes } from "./lib/notes-api";
import type { Todo } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

function isLeaf(todos: Todo[], index: number): boolean {
  const t = todos[index];
  const next = todos[index + 1];
  if (!next) return true;
  if (next.context !== t.context) return true;
  return (next.depth ?? 0) <= (t.depth ?? 0);
}

function findFirstLeafInSubtree(openTodos: Todo[], root: Todo): Todo {
  const sameContext = openTodos.filter((t) => t.context === root.context);
  const idx = sameContext.findIndex((t) => t === root);
  if (idx < 0) return root;
  const next = sameContext[idx + 1];
  const rootDepth = root.depth ?? 0;
  if (!next || (next.depth ?? 0) <= rootDepth) return root;
  return findFirstLeafInSubtree(openTodos, next);
}

function findFirstLeafInTree(todos: Todo[]): Todo | null {
  for (let i = 0; i < todos.length; i++) {
    if (isLeaf(todos, i)) return todos[i];
  }
  return null;
}

export default async function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const focusedKey = await getFocusedProject();
  if (!focusedKey) {
    await showHUD("No Focused Project");
    return;
  }
  const parsed = parseProjectKey(focusedKey);
  if (!parsed) {
    await showHUD("No Focused Project");
    return;
  }
  const notesPath = await resolveNotesPath(prefs, parsed.name);
  if (!notesPath) {
    await showHUD("No Notes");
    return;
  }
  try {
    const out = await getNotes(prefs, parsed.name);
    const openTodos = out.todos.filter((t) => !t.checked);
    const focusedTodo = openTodos.find((t) => t.isFocused) ?? null;
    const target = focusedTodo
      ? findFirstLeafInSubtree(openTodos, focusedTodo)
      : findFirstLeafInTree(openTodos);
    if (!target) {
      await showHUD("All Done");
      return;
    }
    if (focusedTodo && target === focusedTodo && isLeaf(openTodos, openTodos.indexOf(focusedTodo))) {
      await showHUD("Already at leaf");
      return;
    }
    await setFocusToTodoInNotes(prefs, parsed.name, out.notes, target);
    await showHUD(`Focus: ${target.text.slice(0, 40)}`);
    await refreshMenubar();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await showHUD(`Error: ${msg}`);
  }
}
