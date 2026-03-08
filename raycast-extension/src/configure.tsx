import {
  Action,
  ActionPanel,
  Detail,
  getPreferenceValues,
  openExtensionPreferences,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getPmConfig,
  getPmPathsIfPresent,
} from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import EditDomains from "./edit-domains";
import EditNotesTemplate from "./edit-notes-template";
import EditPaths from "./edit-paths";
import EditProjectStructure from "./edit-project-structure";
import FirstRunSetup from "./first-run-setup";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data: pathsOrNull, revalidate } = useCachedPromise(
    getPmPathsIfPresent,
    [prefs],
  );
  const { data: config } = useCachedPromise(
    getPmConfig,
    [prefs],
    { execute: pathsOrNull != null },
  );

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
  const domains = config?.domains ?? {};
  const subfolders = config?.subfolders ?? [];
  const domainSummary =
    Object.keys(domains).length > 0
      ? Object.entries(domains)
        .map(([code, label]) => `${code} → ${label}`)
        .join("  ·  ")
      : "—";
  const structureSummary =
    subfolders.length > 0 ? subfolders.join("  ·  ") : "—";
  const paraPathText = config?.paraPath?.trim() || "—";
  const notesTemplateText = config?.notesTemplatePath?.trim() || "—";
  const useObsidianText = config?.useObsidianCLI ? "Yes" : "No";
  const obsidianVaultText = config?.obsidianVault?.trim() || "—";
  const obsidianVaultPathText = config?.obsidianVaultPath?.trim() || "—";

  return (
    <Detail
      navigationTitle="Configure Project Manager"
      markdown={`# Paths

Where your projects live. **Edit Paths** to change active, archive, or para path.

# Domains

Domain codes and labels used when creating projects (e.g. \`M\` → Marketing). **Edit Domains** to change.

# Project structure

Folder names created inside each new project. **Edit Project Structure** to change.

# Notes template

Optional path to a custom notes template file. **Edit Notes Template** to set or clear.

# Obsidian CLI

When enabled, pm reads/writes notes via the Obsidian CLI. Configure in **Open Preferences**.`}
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
          <Detail.Metadata.Label title="Para path" text={paraPathText} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Domains" text={domainSummary} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label
            title="Project structure"
            text={structureSummary}
          />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label
            title="Notes template"
            text={notesTemplateText}
          />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Use Obsidian CLI" text={useObsidianText} />
          <Detail.Metadata.Label title="Obsidian vault" text={obsidianVaultText} />
          <Detail.Metadata.Label title="Obsidian vault path" text={obsidianVaultPathText} />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action.Push title="Edit Paths" target={<EditPaths />} />
          <Action.Push title="Edit Domains" target={<EditDomains />} />
          <Action.Push
            title="Edit Project Structure"
            target={<EditProjectStructure />}
          />
          <Action.Push
            title="Edit Notes Template"
            target={<EditNotesTemplate />}
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
