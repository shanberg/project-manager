import { getPreferenceValues, showHUD } from "@raycast/api";
import { getNotes, undoCompleteInNotes } from "./lib/notes-api";
import { refreshMenubar } from "./lib/menubar-refresh";
import { getUndoState, clearUndoState } from "./lib/undo-todo";
import type { PreferenceValues } from "./lib/types";

export default async function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const undoState = await getUndoState();
  if (!undoState) {
    await showHUD("Nothing to Undo");
    return;
  }
  try {
    const out = await getNotes(prefs, undoState.projectName);
    await undoCompleteInNotes(
      prefs,
      undoState.projectName,
      out.notes,
      undoState.todo,
    );
    await clearUndoState();
    await showHUD(`Undone: ${undoState.todo.text.slice(0, 40)}`);
    await refreshMenubar();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await showHUD(`Error: ${msg}`);
  }
}
