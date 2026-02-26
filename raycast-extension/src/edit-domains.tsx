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
import { getConfigDomains, runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

function parseDomainsJson(json: string): Record<string, string> {
  const parsed = JSON.parse(json) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Domains must be a JSON object");
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(parsed)) {
    if (typeof k !== "string" || typeof v !== "string") {
      throw new Error("Each key and value must be a string");
    }
    const code = k.trim().toUpperCase();
    if (!code) throw new Error("Domain code cannot be empty");
    out[code] = v.trim();
  }
  if (Object.keys(out).length === 0)
    throw new Error("At least one domain required");
  return out;
}

export default function Command() {
  const [saving, setSaving] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();
  const {
    data: domains,
    isLoading,
    revalidate,
  } = useCachedPromise(getConfigDomains, [prefs]);

  const initialJson = domains ? JSON.stringify(domains, null, 2) : "";

  async function handleSubmit(values: { domainsJson: string }) {
    setSaving(true);
    try {
      const next = parseDomainsJson(values.domainsJson);
      const jsonStr = JSON.stringify(next);
      await runPmWithPrefs(prefs, ["config", "set", "domains", jsonStr]);
      await showToast({
        style: Toast.Style.Success,
        title: "Domains updated",
        message: Object.keys(next).join(", "),
      });
      revalidate();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Invalid domains",
        message: msg,
      });
    } finally {
      setSaving(false);
    }
  }

  if (isLoading || !domains) {
    return <Form isLoading />;
  }

  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save Domains" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="domainsJson"
        title="Domains (JSON)"
        placeholder='{"W": "Work", "P": "Personal", "L": "Learning", "O": "Other"}'
        defaultValue={initialJson}
        info="Code → label. Codes are used in project names (e.g. W-001). At least one domain required."
      />
    </Form>
  );
}
