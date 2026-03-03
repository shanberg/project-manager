import path from "path";
import { open, showHUD } from "@raycast/api";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";

export default async function Command() {
  const focusedKey = await getFocusedProject();
  if (!focusedKey) {
    await showHUD("No Focused Project");
    return;
  }
  const parsed = parseProjectKey(focusedKey);
  if (!parsed) {
    await showHUD("No Focused Project");
    return;
  }
  const projectPath = path.join(parsed.basePath, parsed.name);
  await open(projectPath);
}
