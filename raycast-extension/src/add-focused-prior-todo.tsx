import { List, getPreferenceValues } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";
import AddPriorTodoForm from "./add-prior-todo-form";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data, isLoading } = useCachedPromise(
    async () => {
      const focusedKey = await getFocusedProject();
      if (!focusedKey) return null;
      const parsed = parseProjectKey(focusedKey);
      if (!parsed) return null;
      const { basePath, name } = parsed;
      try {
        const out = await getNotes(prefs, name);
        const nextTodo = out.todos.filter((t) => !t.checked)[0] ?? null;
        return { projectName: name, notes: out.notes, nextTodo };
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
  if (!data.nextTodo) {
    return (
      <List>
        <List.EmptyView
          title="No active task"
          description="Add prior task requires an active task. Use Add Task first."
        />
      </List>
    );
  }

  return (
    <AddPriorTodoForm
      projectName={data.projectName}
      notes={data.notes}
      beforeTodo={data.nextTodo}
      onSuccess={() => {}}
    />
  );
}
