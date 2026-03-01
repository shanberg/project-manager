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
import { getConfigSubfolders, runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

function parseSubfoldersJson(json: string): string[] {
  const parsed = JSON.parse(json) as unknown;
  if (!Array.isArray(parsed)) {
    throw new Error("Project structure must be a JSON array");
  }
  const out: string[] = [];
  for (const v of parsed) {
    if (typeof v !== "string") {
      throw new Error("Each item must be a string");
    }
    const trimmed = v.trim();
    if (!trimmed) throw new Error("Folder name cannot be empty");
    out.push(trimmed);
  }
  if (out.length === 0) throw new Error("At least one folder required");
  return out;
}

export default function Command() {
  const [saving, setSaving] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();
  const {
    data: subfolders,
    isLoading,
    revalidate,
  } = useCachedPromise(getConfigSubfolders, [prefs]);

  const initialJson = subfolders ? JSON.stringify(subfolders, null, 2) : "";

  async function handleSubmit(values: { subfoldersJson: string }) {
    setSaving(true);
    try {
      const next = parseSubfoldersJson(values.subfoldersJson);
      const jsonStr = JSON.stringify(next);
      await runPmWithPrefs(prefs, ["config", "set", "subfolders", jsonStr]);
      await showToast({
        style: Toast.Style.Success,
        title: "Project Structure Updated",
        message: next.join(", "),
      });
      revalidate();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Invalid Project Structure",
        message: msg,
      });
    } finally {
      setSaving(false);
    }
  }

  if (isLoading || !subfolders) {
    return <Form isLoading />;
  }

  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Project Structure"
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="subfoldersJson"
        title="Project structure (JSON array)"
        placeholder='["deliverables", "docs", "resources", "previews", "working files"]'
        defaultValue={initialJson}
        info="Folder names created inside each new project. Order is preserved. At least one folder required."
      />
    </Form>
  );
}
