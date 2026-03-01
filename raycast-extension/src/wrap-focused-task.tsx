import {
  Form,
  Action,
  ActionPanel,
  List,
  showToast,
  Toast,
  getPreferenceValues,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes, wrapTodoInNotes } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

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
          description="Wrap requires an active task. Use Narrow Focus first."
        />
      </List>
    );
  }

  const nowTask = data.nextTodo;

  async function handleSubmit(values: { parentName: string }) {
    const parentName = values.parentName.trim();
    if (!parentName) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Parent name cannot be empty",
      });
      return;
    }
    try {
      await wrapTodoInNotes(
        prefs,
        data!.projectName,
        data!.notes,
        nowTask,
        parentName,
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Task wrapped",
        message: `"${nowTask.text}" under "${parentName}"`,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    }
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Wrap" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="parentName"
        title="New parent name"
        placeholder="e.g. Phase 1"
        autoFocus
      />
    </Form>
  );
}
