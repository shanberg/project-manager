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
import { getNotes, editTodoInNotes } from "./lib/notes-api";
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
    return { projectName: name, notes: out.notes, todos: out.todos, nextTodo };
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
          title="No Focused Project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }
  if (!data.nextTodo) {
    return (
      <List>
        <List.EmptyView
          title="No Active Task"
          description="Edit requires an active task. Use Narrow Focus first."
        />
      </List>
    );
  }

  const nowTask = data.nextTodo;

  async function handleSubmit(values: { text: string }) {
    const text = values.text.trim();
    if (!text) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Task Text Cannot Be Empty",
      });
      return;
    }
    try {
      await editTodoInNotes(
        prefs,
        data!.projectName,
        data!.notes,
        nowTask,
        text,
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Task Updated",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
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
          <Action.SubmitForm title="Update" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="text"
        title="Task"
        placeholder="e.g. Review PR, Call client"
        defaultValue={nowTask.text}
        autoFocus
      />
    </Form>
  );
}
