import {
  Action,
  ActionPanel,
  Detail,
  getPreferenceValues,
  openExtensionPreferences,
} from "@raycast/api";
import type { PreferenceValues } from "./lib/types";

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();

  return (
    <Detail
      navigationTitle="Configure Project Manager"
      markdown={`# Paths

Where your projects live. Both can point to different locations (e.g. different drives or cloud folders).

**Edit in preferences** to change.`}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Active" text={prefs.activePath} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Archive" text={prefs.archivePath} />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action
            title="Open Preferences"
            onAction={openExtensionPreferences}
          />
        </ActionPanel>
      }
    />
  );
}
