import {
  Form,
  Action,
  ActionPanel,
  getPreferenceValues,
  showToast,
  Toast,
} from "@raycast/api";
import { runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
}

export default function AddSessionNoteForm({ projectName }: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();

  async function handleSubmit(values: { label: string }) {
    try {
      const { stdout, stderr } = await runPmWithPrefs(prefs, [
        "notes",
        "session",
        "add",
        projectName,
        values.label.trim() || "Session",
      ]);

      if (stderr) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Error",
          message: stderr,
        });
      } else {
        await showToast({
          style: Toast.Style.Success,
          title: "Session Added",
          message: stdout.trim(),
        });
      }
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
          <Action.SubmitForm title="Add Session" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="label"
        title="Session Label"
        placeholder="e.g. Sync, Discovery meeting"
        defaultValue=""
      />
    </Form>
  );
}
