import {
  Form,
  Action,
  ActionPanel,
  showToast,
  Toast,
  getPreferenceValues,
} from "@raycast/api";
import { updateNotesSection, writeNotes } from "./lib/notes-api";
import type { ProjectNotes } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

type NotesSectionUpdate = Partial<
  Pick<
    ProjectNotes,
    "summary" | "problem" | "goals" | "approach" | "links" | "learnings"
  >
>;

interface Props {
  projectName: string;
  notes: ProjectNotes;
  initialValue: string;
  field: keyof NotesSectionUpdate;
  label: string;
  submitTitle: string;
  onSuccess?: () => void;
}

export default function EditNotesSectionForm({
  projectName,
  notes,
  initialValue,
  field,
  label,
  submitTitle,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();

  async function handleSubmit(values: Record<string, string>) {
    try {
      const updated = updateNotesSection(notes, { [field]: values[field] });
      await writeNotes(prefs, projectName, updated);
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
