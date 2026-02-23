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
import { runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import { DEFAULT_DOMAINS } from "project-manager/types";

const DOMAINS = Object.entries(DEFAULT_DOMAINS).map(([value, title]) => ({
  value,
  title: `${value} (${title})`,
}));

export default function Command() {
  const [loading, setLoading] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();

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
      isLoading={loading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Project" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Dropdown id="domain" title="Domain" defaultValue="M">
        {DOMAINS.map((d) => (
          <Form.Dropdown.Item key={d.value} value={d.value} title={d.title} />
        ))}
      </Form.Dropdown>
      <Form.TextField id="title" title="Project Title" placeholder="e.g. Slides Redesign" />
    </Form>
  );
}
