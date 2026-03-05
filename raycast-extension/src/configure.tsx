import {
  Action,
  ActionPanel,
  Detail,
  getPreferenceValues,
  openExtensionPreferences,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getConfigDomains,
  getConfigSubfolders,
  getPmPathsIfPresent,
} from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import EditDomains from "./edit-domains";
import EditProjectStructure from "./edit-project-structure";
import FirstRunSetup from "./first-run-setup";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data: pathsOrNull, revalidate } = useCachedPromise(
    getPmPathsIfPresent,
    [prefs],
  );
  const { data: domains = {} } = useCachedPromise(getConfigDomains, [prefs]);
  const { data: subfolders = [] } = useCachedPromise(getConfigSubfolders, [
    prefs,
  ]);

  if (pathsOrNull === undefined) {
    return <Detail navigationTitle="Configure Project Manager" markdown="Loading…" />;
  }

  if (pathsOrNull === null) {
    return (
      <FirstRunSetup
        prefs={prefs}
        onComplete={() => {
          revalidate();
        }}
      />
    );
  }

  const paths = pathsOrNull;
  const domainSummary =
    Object.keys(domains).length > 0
      ? Object.entries(domains)
          .map(([code, label]) => `${code} → ${label}`)
          .join("  ·  ")
      : "—";
  const structureSummary =
    subfolders.length > 0 ? subfolders.join("  ·  ") : "—";

  return (
    <Detail
      navigationTitle="Configure Project Manager"
      markdown={`# Paths

Where your projects live. Both can point to different locations (e.g. different drives or cloud folders).

Paths are stored in pm config. Use **Configure Project Manager** on first run to set them, or \`pm config set activePath|archivePath\` in the terminal.

# Domains

Domain codes and labels used when creating projects (e.g. \`M\` → Marketing). **Edit Domains** to change.

# Project structure

Folder names created inside each new project. **Edit Project Structure** to change.`}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label
            title="Active"
            text={paths.activePath}
          />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label
            title="Archive"
            text={paths.archivePath}
          />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Domains" text={domainSummary} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label
            title="Project structure"
            text={structureSummary}
          />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action.Push title="Edit Domains" target={<EditDomains />} />
          <Action.Push
            title="Edit Project Structure"
            target={<EditProjectStructure />}
          />
          <Action
            title="Open Preferences"
            onAction={openExtensionPreferences}
          />
        </ActionPanel>
      }
    />
  );
}
