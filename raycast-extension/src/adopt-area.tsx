import { useState } from "react";
import {
  Action,
  ActionPanel,
  Icon,
  List,
  getPreferenceValues,
  launchCommand,
  LaunchType,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs, getPmPaths } from "./lib/pm";
import { setFocusedProject } from "./lib/focused-project";
import type { PreferenceValues } from "./lib/types";

/**
 * Folders in the areas root that could become areas but haven't yet.
 *
 * A PARA vault has Areas in it long before PM knows the word. The rule that makes an Area "a folder PM
 * has written notes into" is what stops PM claiming every directory it can see; it's also what leaves
 * those unreachable. This is the door that rule needs.
 */
async function fetchAdoptable(
  configPath: string | undefined,
  pmCliPath: string | undefined,
): Promise<string[]> {
  const prefs = { configPath, pmCliPath };
  const { stdout } = await runPmWithPrefs(prefs, [
    "api",
    "call",
    "project.adoptable",
    "{}",
  ]);
  const parsed = JSON.parse(stdout) as {
    data?: { folder: string }[];
  };
  return (parsed.data ?? []).map((e) => e.folder);
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const [busy, setBusy] = useState(false);
  const {
    data: folders = [],
    isLoading,
    revalidate,
  } = useCachedPromise(fetchAdoptable, [prefs.configPath, prefs.pmCliPath]);

  async function adopt(folder: string) {
    setBusy(true);
    try {
      const { stderr } = await runPmWithPrefs(prefs, [
        "api",
        "call",
        "project.adopt",
        JSON.stringify({ folder }),
      ]);
      if (stderr) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Couldn't take it on",
          message: stderr,
        });
        return;
      }
      await showToast({
        style: Toast.Style.Success,
        title: "Adopted",
        message: folder,
      });
      revalidate();

      const { areasPath } = await getPmPaths(prefs);
      await setFocusedProject(areasPath, folder);
      await launchCommand({
        name: "view-project",
        type: LaunchType.UserInitiated,
        context: { projectName: folder, basePath: areasPath },
      });
    } catch (err) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Couldn't take it on",
        message: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setBusy(false);
    }
  }

  return (
    <List isLoading={isLoading || busy} searchBarPlaceholder="Search folders…">
      <List.EmptyView
        title="Nothing to Take On"
        description="Every folder in your areas root is already an area. A folder there with no notes in it is one PM could adopt."
        icon={Icon.CircleEllipsis}
      />
      {folders.map((folder) => (
        <List.Item
          key={folder}
          icon={Icon.Folder}
          title={folder}
          subtitle="not an area yet"
          actions={
            <ActionPanel>
              <Action
                title="Take On as Area"
                icon={Icon.CircleEllipsis}
                onAction={() => adopt(folder)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
