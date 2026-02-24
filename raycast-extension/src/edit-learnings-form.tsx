import { Form, Action, ActionPanel, showToast, Toast } from "@raycast/api";
import { updateNotesSection } from "@shanberg/project-manager/notes";

interface Props {
  notesPath: string;
  initialLearnings: string[];
  onSuccess?: () => void;
}

export default function EditLearningsForm({ notesPath, initialLearnings, onSuccess }: Props) {
  const value = initialLearnings.filter(Boolean).join("\n") || "";
  async function handleSubmit(values: { learnings: string }) {
    const learnings = values.learnings
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean);
    try {
      await updateNotesSection(notesPath, { learnings: learnings.length ? learnings : [""] });
      await showToast({ style: Toast.Style.Success, title: "Learnings updated" });
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
