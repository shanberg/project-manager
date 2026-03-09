import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  getPreferenceValues,
} from "@raycast/api";
import { updateDueDateInNotes } from "./lib/notes-api";
import { parseDueDate, formatDueForStorage } from "./lib/format-relative-due";
import type { ProjectNotes, Todo } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
  notes: ProjectNotes;
  todo: Todo;
  onSuccess?: () => void;
}

export default function SetDueDateForm({
  projectName,
  notes,
  todo,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const initialDate = todo.dueDate ? parseDueDate(todo.dueDate) : null;

  async function handleSet(values: { dueDate: Date }) {
    const dueStr = formatDueForStorage(values.dueDate);
    try {
      await updateDueDateInNotes(prefs, projectName, notes, todo, dueStr);
      await showToast({
        style: Toast.Style.Success,
        title: "Due Date Set",
        message: dueStr,
      });
      onSuccess?.();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    }
  }

  async function handleRemove() {
    try {
      await updateDueDateInNotes(prefs, projectName, notes, todo, null);
      await showToast({
        style: Toast.Style.Success,
        title: "Due Date Removed",
      });
      onSuccess?.();
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
          <Action.SubmitForm
            title="Set Due Date"
            onSubmit={handleSet}
          />
          {todo.dueDate ? (
            <Action.SubmitForm title="Remove Due Date" onSubmit={handleRemove} />
          ) : null}
        </ActionPanel>
      }
    >
      <Form.DatePicker
        id="dueDate"
        title="Due"
        type={Form.DatePicker.Type.DateTime}
        defaultValue={initialDate ?? undefined}
      />
    </Form>
  );
}
