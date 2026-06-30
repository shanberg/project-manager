import { useState } from "react";
import {
  Action,
  ActionPanel,
  Form,
  List,
  getPreferenceValues,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  folderTitleFromBasename,
  getFocusedProject,
  parseProjectKey,
  setFocusedProject,
} from "./lib/focused-project";
import { refreshMenubar } from "./lib/menubar-refresh";
import { runPmWithPrefs } from "./lib/pm";
import { projectKey, replaceRecentProjectKey } from "./lib/recent-projects";
import type { PreferenceValues } from "./lib/types";

async function loadFocused() {
  const focusedKey = await getFocusedProject();
  if (!focusedKey) return null;
  const parsed = parseProjectKey(focusedKey);
  if (!parsed) return null;
  return { ...parsed, focusedKey };
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const [loading, setLoading] = useState(false);
  const { data, isLoading, revalidate } = useCachedPromise(loadFocused, [], {
    execute: true,
  });

  if (isLoading) return <List isLoading />;
  if (!data) {
    return (
      <List>
        <List.EmptyView
          title="No Focused Project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }

  const defaultTitle = folderTitleFromBasename(data.name);
  const oldKey = projectKey(data.basePath, data.name);

  async function handleSubmit(values: { title: string }) {
    if (!data) return;
    const newTitle = values.title.trim();
    if (!newTitle) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Title required",
      });
      return;
    }
    setLoading(true);
    try {
      const { stdout, stderr, code } = await runPmWithPrefs(prefs, [
        "rename",
        data.name,
        newTitle,
      ]);
      if (code !== 0) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Rename failed",
          message: stderr.trim() || stdout.trim() || `exit ${code}`,
        });
        return;
      }
      const newBasename = stdout.trim().split("\n")[0]?.trim() ?? "";
      if (!newBasename) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Rename failed",
          message: "Empty response from pm",
        });
        return;
      }
      const newKey = projectKey(data.basePath, newBasename);
      await setFocusedProject(data.basePath, newBasename);
      await replaceRecentProjectKey(oldKey, newKey);
      await refreshMenubar();
      await showToast({
        style: Toast.Style.Success,
        title: "Project renamed",
        message: newBasename,
      });
      await revalidate();
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
      key={data.name}
      isLoading={loading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description text="Only the title after the project code changes (e.g. W-1)." />
      <Form.TextField
        id="title"
        title="Project title"
        defaultValue={defaultTitle}
      />
    </Form>
  );
}
