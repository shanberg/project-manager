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

interface Props {
  projectName: string;
  notes: ProjectNotes;
  initialLearnings: string[];
  onSuccess?: () => void;
}

export default function EditLearningsForm({
  projectName,
  notes,
  initialLearnings,
  onSuccess,
}: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const value = initialLearnings.filter(Boolean).join("\n") || "";

  async function handleSubmit(values: { learnings: string }) {
    const learnings = values.learnings
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean);
    try {
      const updated = updateNotesSection(notes, {
        learnings: learnings.length ? learnings : [""],
      });
      await writeNotes(prefs, projectName, updated);
      await showToast({
        style: Toast.Style.Success,
        title: "Learnings updated",
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
          <Action.SubmitForm title="Save Learnings" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="learnings"
        title="Learnings"
        placeholder="One per line"
        defaultValue={value}
      />
    </Form>
  );
}
