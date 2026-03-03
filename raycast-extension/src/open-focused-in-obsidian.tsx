import { getPreferenceValues, open, showHUD } from "@raycast/api";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes, resolveNotesPath } from "./lib/notes-api";
import {
  buildObsidianOptions,
  ensureTodaySession,
  getObsidianUri,
} from "./lib/utils";
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
  const out = await getNotes(prefs, parsed.name);
  const session = await ensureTodaySession(parsed.name, out.notes, prefs);
  const opts = buildObsidianOptions(prefs, session);
  open(getObsidianUri(notesPath, opts));
}
