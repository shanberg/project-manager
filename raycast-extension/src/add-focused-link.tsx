import { List, getPreferenceValues } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes, resolveNotesPath } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";
import AddLinkForm from "./add-link-form";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data, isLoading } = useCachedPromise(
    async () => {
      const focusedKey = await getFocusedProject();
      if (!focusedKey) return null;
      const parsed = parseProjectKey(focusedKey);
      if (!parsed) return null;
      const notesPath = await resolveNotesPath(prefs, parsed.name);
      if (!notesPath) return null;
      try {
        const out = await getNotes(prefs, parsed.name);
        return { projectName: parsed.name, notes: out.notes };
      } catch {
        return null;
      }
    },
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { execute: true }
  );

  if (isLoading) return <List isLoading />;
  if (!data) {
    return (
      <List>
        <List.EmptyView
          title="No focused project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }

  return <AddLinkForm projectName={data.projectName} notes={data.notes} />;
}
