import { getPreferenceValues, showHUD } from "@raycast/api";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { refreshMenubar } from "./lib/menubar-refresh";
import {
  getNotes,
  resolveNotesPath,
  completeAndAdvanceInNotes,
} from "./lib/notes-api";
import { saveUndoState } from "./lib/undo-todo";
import type { PreferenceValues } from "./lib/types";

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
    const nextTodo =
      openTodos.find((t) => t.isFocused) ?? openTodos[0] ?? null;
    if (!nextTodo) {
      await showHUD("All Done");
      return;
    }
    await saveUndoState(notesPath, parsed.name, nextTodo);
    await completeAndAdvanceInNotes(
      prefs,
      parsed.name,
      out.notes,
      out.todos,
      nextTodo,
    );
    await showHUD(`Done: ${nextTodo.text.slice(0, 40)}`);
    await refreshMenubar();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await showHUD(`Error: ${msg}`);
  }
}
