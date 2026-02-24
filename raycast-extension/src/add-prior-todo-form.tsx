import { Form, Action, ActionPanel, showToast, Toast, useNavigation } from "@raycast/api";
import { addTodoBeforeInFile } from "project-manager/notes";
import type { Todo } from "project-manager/notes";

interface Props {
  notesPath: string;
  beforeTodo: Todo;
  onSuccess?: () => void;
}

export default function AddPriorTodoForm({ notesPath, beforeTodo, onSuccess }: Props) {
  const { push } = useNavigation();

  async function addTask(text: string): Promise<boolean> {
    try {
      await addTodoBeforeInFile(notesPath, beforeTodo, text);
      await showToast({
        style: Toast.Style.Success,
        title: "Todo added",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
      });
      onSuccess?.();
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
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
    if (ok) push(<AddPriorTodoForm notesPath={notesPath} beforeTodo={beforeTodo} onSuccess={onSuccess} />);
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Add & Done" onSubmit={handleAddAndDone} />
          <Action.SubmitForm title="Add & Add Another" onSubmit={handleAddAndAnother} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="text"
        title="Todo"
        placeholder="e.g. Review PR, Call client"
        autoFocus
      />
    </Form>
  );
}
