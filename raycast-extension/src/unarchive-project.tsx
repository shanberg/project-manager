import {
  Action,
  ActionPanel,
  confirmAlert,
  getPreferenceValues,
  List,
  open,
  showToast,
  Toast,
} from "@raycast/api";
import path from "path";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs, getPmPaths } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import { FINDER_APP_PATH } from "./lib/utils";

async function fetchArchivedProjects(
  configPath: string | undefined,
  pmCliPath: string | undefined,
): Promise<{ projects: string[]; archivePath: string }> {
  const prefs = { configPath, pmCliPath };
  const [paths, { stdout }] = await Promise.all([
    getPmPaths(prefs),
    runPmWithPrefs(prefs, ["list", "--archive"]),
  ]);
  const projects = stdout
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  return { projects, archivePath: paths.archivePath };
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  const {
    data = { projects: [], archivePath: "" },
    isLoading,
    revalidate,
    mutate,
  } = useCachedPromise(
    fetchArchivedProjects,
    [prefs.configPath, prefs.pmCliPath],
    { keepPreviousData: true },
  );

  async function unarchiveProject(name: string) {
    const confirmed = await confirmAlert({
      title: "Unarchive Project",
      message: `Move "${name}" back to active?`,
      primaryAction: { title: "Unarchive" },
    });
    if (!confirmed) return;
    try {
      await mutate(async () => {
        await runPmWithPrefs(prefs, ["unarchive", name]);
        return {
          projects: data.projects.filter((p) => p !== name),
          archivePath: data.archivePath,
        };
      }, {
        optimisticUpdate(d) {
          if (!d) return { projects: [], archivePath: "" };
          return {
            ...d,
            projects: d.projects.filter((p) => p !== name),
          };
        },
      });
      await showToast({
        style: Toast.Style.Success,
        title: "Unarchived",
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
      {data.projects.map((name) => (
        <List.Item
          key={name}
          title={name}
          actions={
            <ActionPanel>
              <Action
                title="Unarchive Project"
                onAction={() => unarchiveProject(name)}
              />
              <Action
                title="Open in Finder"
                icon={{ fileIcon: FINDER_APP_PATH }}
                onAction={() => open(path.join(data.archivePath, name))}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
