import { getPreferenceValues, showHUD } from "@raycast/api";
import type { PreferenceValues } from "./lib/types";
import { togglePanelSetting } from "./lib/panel-settings";

export default async function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  try {
    const floating = await togglePanelSetting("floating", prefs.configPath);
    await showHUD(
      floating
        ? "PM Panel: floating above other windows"
        : "PM Panel: normal window stacking",
    );
  } catch (err) {
    await showHUD(`Error: ${err instanceof Error ? err.message : String(err)}`);
  }
}
