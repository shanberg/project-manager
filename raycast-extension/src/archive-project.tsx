import {
  Action,
  ActionPanel,
  Alert,
  confirmAlert,
  getPreferenceValues,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

async function fetchActiveProjects(
  configPath: string | undefined,
  pmCliPath: string | undefined,
): Promise<string[]> {
  const prefs = { configPath, pmCliPath };
  const { stdout } = await runPmWithPrefs(prefs, ["list"]);
  return stdout
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const {
    data: projects = [],
    isLoading,
    revalidate,
    mutate,
  } = useCachedPromise(
    fetchActiveProjects,
    [prefs.configPath, prefs.pmCliPath],
    { keepPreviousData: true },
  );

  async function archiveProject(name: string) {
    const confirmed = await confirmAlert({
      title: "Archive Project",
      message: `Move "${name}" to archive?`,
      primaryAction: { title: "Archive", style: Alert.ActionStyle.Destructive },
    });
    if (!confirmed) return;
    try {
      await mutate(
        async () => {
          await runPmWithPrefs(prefs, ["archive", name]);
          return (projects ?? []).filter((p) => p !== name);
        },
        {
          optimisticUpdate(data) {
            return data !== undefined ? data.filter((p) => p !== name) : [];
          },
        },
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Archived",
        message: name,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    }
  }

  return (
    <List
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action
            title="Refresh"
            onAction={revalidate}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
          />
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
