import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  useNavigation,
  getPreferenceValues,
} from "@raycast/api";
import { addTodoAsChildInNotes } from "./lib/notes-api";
import type { ProjectNotes, Todo } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
  notes: ProjectNotes;
  parentTodo: Todo;
  onSuccess?: () => void;
}

export default function AddChildTodoForm({
  projectName,
  notes,
  parentTodo,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { push } = useNavigation();

  async function addTask(text: string): Promise<boolean> {
    try {
      await addTodoAsChildInNotes(prefs, projectName, notes, parentTodo, text);
      await showToast({
        style: Toast.Style.Success,
        title: "Child Task Added",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
      });
      onSuccess?.();
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
      return false;
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
    const ok = await addTask(text);
    if (ok)
      push(
        <AddChildTodoForm
          projectName={projectName}
          notes={notes}
          parentTodo={parentTodo}
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
        title="Child Task"
        placeholder="e.g. Subtask under current task"
        autoFocus
      />
    </Form>
  );
}
