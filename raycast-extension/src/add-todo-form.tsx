import path from "path";
import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import {
  addTodoToTodaySession,
  resolveNotesPath,
} from "@shanberg/project-manager/notes";

interface Props {
  projectName: string;
  basePath: string;
  onSuccess?: () => void;
}

export default function AddTodoForm({
  projectName,
  basePath,
  onSuccess,
}: Props) {
  const { push } = useNavigation();

  async function addTask(text: string): Promise<boolean> {
    const projectPath = path.join(basePath, projectName);
    const notesPath = await resolveNotesPath(projectPath);
    if (!notesPath) {
      await showToast({
        style: Toast.Style.Failure,
        title: "No notes file",
        message: "Create a notes file first",
      });
      return false;
    }
    try {
      await addTodoToTodaySession(notesPath, text);
      await showToast({
        style: Toast.Style.Success,
        title: "Task added",
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
        <AddTodoForm
          projectName={projectName}
          basePath={basePath}
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
