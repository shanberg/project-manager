import { useState } from "react";
import {
  Action,
  ActionPanel,
  Form,
  getPreferenceValues,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getPmConfig, setPmConfigKey } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

export default function EditNotesTemplate() {
  const [saving, setSaving] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();
  const {
    data: config,
    isLoading,
    revalidate,
  } = useCachedPromise(getPmConfig, [prefs]);

  async function handleSubmit(values: { notesTemplatePath: string[] }) {
    const path = values.notesTemplatePath?.[0]?.trim() ?? "";
    setSaving(true);
    try {
      await setPmConfigKey(prefs, "notesTemplatePath", path);
      await showToast({
        style: Toast.Style.Success,
        title: path ? "Notes template updated" : "Notes template cleared",
      });
      revalidate();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to update notes template",
        message: msg,
      });
    } finally {
      setSaving(false);
    }
  }

  if (isLoading || !config) {
    return <Form isLoading />;
  }

  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.FilePicker
        id="notesTemplatePath"
        title="Notes template file"
        allowMultipleSelection={false}
        canChooseDirectories={false}
        canChooseFiles
        defaultValue={config.notesTemplatePath ? [config.notesTemplatePath] : []}
        info="Optional custom notes template file. When set, new project notes use this file. Leave empty to use pm default."
      />
    </Form>
  );
}
