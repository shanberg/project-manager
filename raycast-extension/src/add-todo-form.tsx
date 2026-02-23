import path from "path";
import { Form, Action, ActionPanel, showToast, Toast } from "@raycast/api";
import { addTodoToTodaySession, resolveNotesPath } from "project-manager/notes";
interface Props {
  projectName: string;
  basePath: string;
  onSuccess?: () => void;
}

export default function AddTodoForm({ projectName, basePath, onSuccess }: Props) {
  async function handleSubmit(values: { text: string }) {
    const text = values.text.trim();
    if (!text) return;
    const projectPath = path.join(basePath, projectName);
    const notesPath = await resolveNotesPath(projectPath);
    if (!notesPath) {
      await showToast({
        style: Toast.Style.Failure,
        title: "No notes file",
        message: "Create a notes file first",
      });
      return;
    }
    try {
      await addTodoToTodaySession(notesPath, text);
      await showToast({
        style: Toast.Style.Success,
        title: "Todo added",
        message: text.slice(0, 50) + (text.length > 50 ? "…" : ""),
      });
      onSuccess?.();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Add Todo" onSubmit={handleSubmit} />
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
