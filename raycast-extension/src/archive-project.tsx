import {
  Action,
  ActionPanel,
  getPreferenceValues,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

async function fetchActiveProjects(
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined
): Promise<string[]> {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
  const { stdout } = await runPmWithPrefs(prefs, ["list"]);
  return stdout
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data: projects = [], isLoading, revalidate, mutate } = useCachedPromise(
    fetchActiveProjects,
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { keepPreviousData: true }
  );

  async function archiveProject(name: string) {
    try {
      await mutate(
        runPmWithPrefs(prefs, ["archive", name]),
        {
          optimisticUpdate(data) {
            return data.filter((p) => p !== name);
          },
        }
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Archived",
        message: name,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  return (
    <List
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action title="Refresh" onAction={revalidate} shortcut={{ modifiers: ["cmd"], key: "r" }} />
        </ActionPanel>
      }
    >
      {projects.map((name) => (
        <List.Item
          key={name}
          title={name}
          actions={
            <ActionPanel>
              <Action
                title="Archive Project"
                onAction={() => archiveProject(name)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
