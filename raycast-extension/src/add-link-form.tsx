import { Form, Action, ActionPanel, showToast, Toast } from "@raycast/api";
import { addLinkToNotes } from "@shanberg/project-manager/notes";

interface Props {
  notesPath: string;
  onSuccess?: () => void;
}

export default function AddLinkForm({ notesPath, onSuccess }: Props) {
  async function handleSubmit(values: { label: string; url: string }) {
    const url = values.url.trim();
    if (!url) return;
    try {
      await addLinkToNotes(notesPath, {
        label: values.label.trim() || undefined,
        url,
      });
      await showToast({
        style: Toast.Style.Success,
        title: "Link added",
        message: values.label.trim() || url.slice(0, 40) + (url.length > 40 ? "…" : ""),
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
          <Action.SubmitForm title="Add Link" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="label"
        title="Label"
        placeholder="e.g. Figma, Docs"
      />
      <Form.TextField
        id="url"
        title="URL"
        placeholder="https://..."
      />
    </Form>
  );
}
