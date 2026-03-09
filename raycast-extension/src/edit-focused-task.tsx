import {
  Form,
  Action,
  ActionPanel,
  Icon,
  List,
  showToast,
  Toast,
  getPreferenceValues,
  useNavigation,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { getNotes, editTodoInNotes, updateDueDateInNotes } from "./lib/notes-api";
import { refreshMenubar } from "./lib/menubar-refresh";
import { parseDueDate, formatDueForStorage } from "./lib/format-relative-due";
import type { PreferenceValues } from "./lib/types";

async function fetchFocusedProjectWithNextTodo(
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { configPath, pmCliPath };
  const focusedKey = await getFocusedProject();
  if (!focusedKey) return null;
  const parsed = parseProjectKey(focusedKey);
  if (!parsed) return null;
  const { name } = parsed;
  try {
    const out = await getNotes(prefs, name);
    const openTodos = out.todos.filter((t) => !t.checked);
    const nextTodo = openTodos.find((t) => t.isFocused) ?? openTodos[0] ?? null;
    return { projectName: name, notes: out.notes, todos: out.todos, nextTodo };
  } catch {
    return null;
  }
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { pop } = useNavigation();

  const { data, isLoading, revalidate } = useCachedPromise(
    fetchFocusedProjectWithNextTodo,
    [prefs.configPath, prefs.pmCliPath],
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

  async function handleRemoveDue() {
    try {
      await updateDueDateInNotes(
        prefs,
        data!.projectName,
        data!.notes,
        nowTask,
        null,
      );
      await showToast({ style: Toast.Style.Success, title: "Due Date Removed" });
      await revalidate();
      await refreshMenubar();
      pop();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  async function handleSubmit(values: { text: string; dueDate?: Date }) {
    const text = values.text.trim();
    if (!text) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Task Text Cannot Be Empty",
      });
      return;
    }
    try {
      const updatedNotes = await editTodoInNotes(
        prefs,
        data!.projectName,
        data!.notes,
        nowTask,
        text,
      );
      if (values.dueDate != null) {
        await updateDueDateInNotes(
          prefs,
          data!.projectName,
          updatedNotes,
          nowTask,
          formatDueForStorage(values.dueDate),
        );
      }
      await showToast({
        style: Toast.Style.Success,
        title: "Task Updated",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
      });
      await revalidate();
      await refreshMenubar();
      pop();
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
          {nowTask.dueDate && (
            <Action
              title="Remove Due Date"
              icon={Icon.XMarkCircle}
              onAction={handleRemoveDue}
            />
          )}
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
      <Form.DatePicker
        id="dueDate"
        title="Due"
        type={Form.DatePicker.Type.DateTime}
        defaultValue={nowTask.dueDate ? parseDueDate(nowTask.dueDate) ?? undefined : undefined}
      />
    </Form>
  );
}
