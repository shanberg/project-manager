import { Form, Action, ActionPanel, showToast, Toast } from "@raycast/api";
import { updateNotesSection } from "@shanberg/project-manager/notes";
import type { NotesSectionUpdate } from "@shanberg/project-manager/notes";

interface Props {
  notesPath: string;
  initialValue: string;
  field: keyof NotesSectionUpdate;
  label: string;
  submitTitle: string;
  onSuccess?: () => void;
}

export default function EditNotesSectionForm({
  notesPath,
  initialValue,
  field,
  label,
  submitTitle,
  onSuccess,
}: Props) {
  async function handleSubmit(values: Record<string, string>) {
    try {
      await updateNotesSection(notesPath, { [field]: values[field] });
      await showToast({
        style: Toast.Style.Success,
        title: `${label} updated`,
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
          <Action.SubmitForm title={submitTitle} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea id={field} title={label} defaultValue={initialValue} />
    </Form>
  );
}
