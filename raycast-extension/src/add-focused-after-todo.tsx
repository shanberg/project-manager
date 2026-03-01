import { List, getPreferenceValues } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";
import AddAfterTodoForm from "./add-after-todo-form";

async function fetchFocusedProjectWithNextTodo(
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
  const focusedKey = await getFocusedProject();
  if (!focusedKey) return null;
  const parsed = parseProjectKey(focusedKey);
  if (!parsed) return null;
  const { name } = parsed;
  try {
    const out = await getNotes(prefs, name);
    const openTodos = out.todos.filter((t) => !t.checked);
    const nextTodo =
      openTodos.find((t) => t.isFocused) ?? openTodos[0] ?? null;
    return { projectName: name, notes: out.notes, nextTodo };
  } catch {
    return null;
  }
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data, isLoading } = useCachedPromise(
    fetchFocusedProjectWithNextTodo,
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { execute: true },
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
          description="Add After requires an active task. Use Narrow Focus first."
        />
      </List>
    );
  }

  return (
    <AddAfterTodoForm
      projectName={data.projectName}
      notes={data.notes}
      afterTodo={data.nextTodo}
      onSuccess={() => {}}
    />
  );
}
