import {
  Action,
  ActionPanel,
  Detail,
  getPreferenceValues,
  openExtensionPreferences,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getConfigDomains } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import EditDomains from "./edit-domains";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data: domains = {} } = useCachedPromise(getConfigDomains, [prefs]);
  const domainSummary =
    Object.keys(domains).length > 0
      ? Object.entries(domains)
          .map(([code, label]) => `${code} → ${label}`)
          .join("  ·  ")
      : "—";

  return (
    <Detail
      navigationTitle="Configure Project Manager"
      markdown={`# Paths

Where your projects live. Both can point to different locations (e.g. different drives or cloud folders).

**Edit in preferences** to change paths.

# Domains

Domain codes and labels used when creating projects (e.g. \`M\` → Marketing). **Edit Domains** to change.`}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Active" text={prefs.activePath} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Archive" text={prefs.archivePath} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Domains" text={domainSummary} />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action.Push title="Edit Domains" target={<EditDomains />} />
          <Action
            title="Open Preferences"
            onAction={openExtensionPreferences}
          />
        </ActionPanel>
      }
    />
  );
}
