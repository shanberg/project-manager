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
import { runPmWithPrefs, getPmPaths } from "./lib/pm";
import { setFocusedProject } from "./lib/focused-project";
import type { PreferenceValues } from "./lib/types";

/**
 * An area takes no domain and draws no number, so this is New Project minus the dropdown — a name is
 * the whole of it, and the folder is called exactly that.
 */
export default function Command() {
  const [loading, setLoading] = useState(false);
  const prefs = getPreferenceValues<PreferenceValues>();

  async function handleSubmit(values: { title: string }) {
    setLoading(true);
    try {
      const { stdout, stderr } = await runPmWithPrefs(prefs, [
        "new",
        "--area",
        values.title,
      ]);

      if (stderr) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Error",
          message: stderr,
        });
        return;
      }

      const createdMsg = stdout.trim();
      await showToast({
        style: Toast.Style.Success,
        title: "Area Created",
        message: createdMsg,
      });
      const match = createdMsg.match(/^Created:\s*(.+)$/);
      if (!match) return;

      const areaPath = match[1].trim();
      const projectName = path.basename(areaPath);
      const { areasPath } = await getPmPaths(prefs);
      await setFocusedProject(areasPath, projectName);
      await launchCommand({
        name: "view-project",
        type: LaunchType.UserInitiated,
        context: { projectName, basePath: areasPath },
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    } finally {
      setLoading(false);
    }
  }

  return (
    <Form
      isLoading={loading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Area" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="title"
        title="Area Name"
        placeholder="e.g. Team 1:1s"
      />
      <Form.Description text="Something ongoing — a responsibility you hold, a meeting that recurs. It isn't numbered and it doesn't finish." />
    </Form>
  );
}
