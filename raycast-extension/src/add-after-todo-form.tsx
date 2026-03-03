import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  useNavigation,
  getPreferenceValues,
} from "@raycast/api";
import { addTodoAfterInNotes, getNotes } from "./lib/notes-api";
import type { ProjectNotes, Todo } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
  notes: ProjectNotes;
  afterTodo: Todo;
  onSuccess?: () => void;
}

export default function AddAfterTodoForm({
  projectName,
  notes,
  afterTodo,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { push } = useNavigation();

  async function addTask(text: string): Promise<{ notes: ProjectNotes; insertedTodo: Todo } | null> {
    try {
      const data = await getNotes(prefs, projectName);
      const result = await addTodoAfterInNotes(prefs, projectName, data.notes, afterTodo, text);
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

  async function handleAddAndDone(values: { text: string }) {
    const text = values.text.trim();
    if (!text) return;
    await addTask(text);
  }

  async function handleAddAndAnother(values: { text: string }) {
    const text = values.text.trim();
    if (!text) return;
    const result = await addTask(text);
    if (result)
      push(
        <AddAfterTodoForm
          projectName={projectName}
          notes={result.notes}
          afterTodo={result.insertedTodo}
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
    </Form>
  );
}
