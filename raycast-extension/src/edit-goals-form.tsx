import { Form, Action, ActionPanel, showToast, Toast } from "@raycast/api";
import { updateNotesSection } from "@shanberg/project-manager/notes";

interface Props {
  notesPath: string;
  initialGoals: string[];
  onSuccess?: () => void;
}

export default function EditGoalsForm({ notesPath, initialGoals, onSuccess }: Props) {
  const goals = [...initialGoals, "", ""].slice(0, 3);
  async function handleSubmit(values: { goal1: string; goal2: string; goal3: string }) {
    const newGoals = [values.goal1, values.goal2, values.goal3];
    try {
      await updateNotesSection(notesPath, { goals: newGoals });
      await showToast({ style: Toast.Style.Success, title: "Goals updated" });
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
          <Action.SubmitForm title="Save Goals" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="goal1" title="Goal 1" defaultValue={goals[0]} />
      <Form.TextField id="goal2" title="Goal 2" defaultValue={goals[1]} />
      <Form.TextField id="goal3" title="Goal 3" defaultValue={goals[2]} />
    </Form>
  );
}
