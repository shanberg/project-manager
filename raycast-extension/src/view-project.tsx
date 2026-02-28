import {
  Action,
  ActionPanel,
  getPreferenceValues,
  List,
  open,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { runPmWithPrefs } from "./lib/pm";
import { parseListAllOutput } from "./lib/utils";
import type { PreferenceValues } from "./lib/types";
import ProjectView from "./project-view";

async function fetchProjects(
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
  const { stdout } = await runPmWithPrefs(prefs, ["list", "--all"]);
  return parseListAllOutput(stdout);
}

type LaunchContext = { projectName: string; basePath: string };

export default function Command(props: { launchContext?: LaunchContext }) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const direct = props.launchContext;

  if (direct?.projectName && direct?.basePath) {
    return (
      <ProjectView
        projectName={direct.projectName}
        basePath={direct.basePath}
      />
    );
  }

  const { data, isLoading, revalidate } = useCachedPromise(
    fetchProjects,
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { keepPreviousData: true },
  );

  const active = data?.active ?? [];
  const archive = data?.archive ?? [];

  return (
    <List
      navigationTitle="View Project"
      isLoading={isLoading}
      searchBarPlaceholder="Search projects…"
      actions={
        <ActionPanel>
          <Action
            title="Refresh"
            onAction={revalidate}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
          />
          <Action
            title="Configure"
            onAction={() =>
              open("raycast://extensions/shanberg/project-manager/configure")
            }
          />
        </ActionPanel>
      }
    >
      <List.Section title="Active">
        {active.map((name) => (
          <List.Item
            key={`active:${name}`}
            title={name}
            actions={
              <ActionPanel>
                <Action.Push
                  title="View Project"
                  target={
                    <ProjectView
                      projectName={name}
                      basePath={prefs.activePath}
                    />
                  }
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
      <List.Section title="Archive">
        {archive.map((name) => (
          <List.Item
            key={`archive:${name}`}
            title={name}
            actions={
              <ActionPanel>
                <Action.Push
                  title="View Project"
                  target={
                    <ProjectView
                      projectName={name}
                      basePath={prefs.archivePath}
                    />
                  }
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
