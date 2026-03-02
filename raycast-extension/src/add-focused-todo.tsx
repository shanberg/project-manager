import { List, getPreferenceValues } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";
import AddChildTodoForm from "./add-child-todo-form";

async function fetchFocusedProjectWithFocusedTask(
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
    const focusedTodo =
      openTodos.find((t) => t.isFocused) ?? openTodos[0] ?? null;
    return { projectName: name, notes: out.notes, focusedTodo };
  } catch {
    return null;
  }
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data, isLoading } = useCachedPromise(
    fetchFocusedProjectWithFocusedTask,
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { execute: true },
  );

  if (isLoading) return <List isLoading />;
  if (!data) {
    return (
      <List>
        <List.EmptyView
          title="No Focused Project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }
  if (!data.focusedTodo) {
    return (
      <List>
        <List.EmptyView
          title="No Active Task"
          description="Narrow Focus adds a child to the current task. Add or select a task in the project first."
        />
      </List>
    );
  }

  return (
    <AddChildTodoForm
      projectName={data.projectName}
      notes={data.notes}
      parentTodo={data.focusedTodo}
      onSuccess={() => {}}
    />
  );
}
