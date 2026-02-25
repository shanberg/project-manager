import path from "path";
import { useState } from "react";
import {
  Action,
  ActionPanel,
  Form,
  getPreferenceValues,
  launchCommand,
  LaunchType,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs, getConfigDomains } from "./lib/pm";
import { setFocusedProject } from "./lib/focused-project";
import type { PreferenceValues } from "./lib/types";

export default function Command() {
  const [loading, setLoading] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data: domains = {}, isLoading: domainsLoading } = useCachedPromise(
    getConfigDomains,
    [prefs]
  );
  const domainOptions = Object.entries(domains).map(([value, label]) => ({
    value,
    title: `${value} (${label})`,
  }));
  const defaultDomain = domainOptions[0]?.value ?? "M";

  async function handleSubmit(values: { domain: string; title: string }) {
    setLoading(true);
    try {
      const { stdout, stderr } = await runPmWithPrefs(prefs, [
        "new",
        values.domain,
        values.title,
      ]);

      if (stderr) {
        await showToast({ style: Toast.Style.Failure, title: "Error", message: stderr });
      } else {
        const createdMsg = stdout.trim();
        await showToast({
          style: Toast.Style.Success,
          title: "Project created",
          message: createdMsg,
        });
        const match = createdMsg.match(/^Created:\s*(.+)$/);
        if (match) {
          const projectPath = match[1].trim();
          const projectName = path.basename(projectPath);
          await setFocusedProject(prefs.activePath, projectName);
          await launchCommand({
            name: "view-project",
            type: LaunchType.UserInitiated,
            context: { projectName, basePath: prefs.activePath },
          });
        }
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    } finally {
      setLoading(false);
    }
  }

  return (
    <Form
      isLoading={loading || domainsLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Project" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Dropdown id="domain" title="Domain" defaultValue={defaultDomain}>
        {domainOptions.map((d) => (
          <Form.Dropdown.Item key={d.value} value={d.value} title={d.title} />
        ))}
      </Form.Dropdown>
      <Form.TextField id="title" title="Project Title" placeholder="e.g. Website Refresh" />
    </Form>
  );
}
