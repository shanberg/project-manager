import path from "path";
import { List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { resolveNotesPath } from "@shanberg/project-manager/notes";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import AddLinkForm from "./add-link-form";

export default function Command() {
  const { data: focusedKey, isLoading } = useCachedPromise(
    getFocusedProject,
    [],
  );
  const parsed = focusedKey ? parseProjectKey(focusedKey) : null;
  const { data: notesPath } = useCachedPromise(
    async () => {
      if (!parsed) return null;
      const projectPath = path.join(parsed.basePath, parsed.name);
      return resolveNotesPath(projectPath);
    },
    [parsed?.basePath, parsed?.name],
    { execute: !!parsed },
  );

  if (isLoading) return <List isLoading />;
  if (!parsed) {
    return (
      <List>
        <List.EmptyView
          title="No focused project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }
  if (!notesPath) {
    return (
      <List>
        <List.EmptyView
          title="No notes file"
          description="Create a notes file in the project first"
        />
      </List>
    );
  }

  return <AddLinkForm notesPath={notesPath} />;
}
