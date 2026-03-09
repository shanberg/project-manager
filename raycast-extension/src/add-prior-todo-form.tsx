import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  useNavigation,
  getPreferenceValues,
} from "@raycast/api";
import { addTodoBeforeInNotes, getNotes } from "./lib/notes-api";
import { formatDueForStorage } from "./lib/format-relative-due";
import type { ProjectNotes, Todo } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
  notes: ProjectNotes;
  beforeTodo: Todo;
  onSuccess?: () => void;
}

export default function AddPriorTodoForm({
  projectName,
  notes,
  beforeTodo,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { push } = useNavigation();

  async function addTask(
    text: string,
    dueDate?: Date | null,
  ): Promise<{ notes: ProjectNotes; nextBeforeTodo: Todo } | null> {
    try {
      const data = await getNotes(prefs, projectName);
      const dueStr =
        dueDate != null ? formatDueForStorage(dueDate) : undefined;
      const result = await addTodoBeforeInNotes(
        prefs,
        projectName,
        data.notes,
        beforeTodo,
        text,
        dueStr,
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Task Added",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
      });
      onSuccess?.();
      return result;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
      return null;
    }
  }

  async function handleAddAndDone(values: { text: string; dueDate?: Date }) {
    const text = values.text.trim();
    if (!text) return;
    await addTask(text, values.dueDate);
  }

  async function handleAddAndAnother(values: { text: string; dueDate?: Date }) {
    const text = values.text.trim();
    if (!text) return;
    const result = await addTask(text, values.dueDate);
    if (result)
      push(
        <AddPriorTodoForm
          projectName={projectName}
          notes={result.notes}
          beforeTodo={result.nextBeforeTodo}
          onSuccess={onSuccess}
        />,
      );
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Add & Done" onSubmit={handleAddAndDone} />
          <Action.SubmitForm
            title="Add & Add Another"
            onSubmit={handleAddAndAnother}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="text"
        title="Task"
        placeholder="e.g. Review PR, Call client"
        autoFocus
      />
      <Form.DatePicker
        id="dueDate"
        title="Due"
        type={Form.DatePicker.Type.DateTime}
      />
    </Form>
  );
}
