import {
  Form,
  Action,
  ActionPanel,
  getPreferenceValues,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { appendNoteToTodaySession } from "./lib/notes-api";
import type { PreferenceValues } from "./lib/types";

interface Props {
  projectName: string;
}

/**
 * Append a note to today's session. The note joins whatever today's session already says (under a
 * blank line) rather than replacing it, and today's session is created if the project hasn't got one
 * yet — so this is "write down what just happened", not "start a session".
 */
export default function AddSessionNoteForm({ projectName }: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { pop } = useNavigation();

  async function handleSubmit(values: { note: string }) {
    const note = values.note.trim();
    if (!note) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Note Is Empty",
      });
      return;
    }
    try {
      await appendNoteToTodaySession(prefs, projectName, note);
      await showToast({
        style: Toast.Style.Success,
        title: "Note Added",
        message: note.slice(0, 50) + (note.length > 50 ? "…" : ""),
      });
      pop();
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
          <Action.SubmitForm title="Add Note" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="note"
        title="Note"
        placeholder="What happened, what you decided, what's next"
        enableMarkdown
        autoFocus
      />
    </Form>
  );
}
