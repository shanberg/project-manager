import { getPreferenceValues, showHUD } from "@raycast/api";
import type { PreferenceValues } from "./lib/types";
import { togglePanelSetting } from "./lib/panel-settings";

export default async function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  try {
    const pinned = await togglePanelSetting("pinned", prefs.configPath);
    await showHUD(
      pinned
        ? "PM Panel: stays open when unfocused"
        : "PM Panel: auto-hides when unfocused",
    );
  } catch (err) {
    await showHUD(`Error: ${err instanceof Error ? err.message : String(err)}`);
  }
}
