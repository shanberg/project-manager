import { launchCommand, LaunchType } from "@raycast/api";

export async function refreshMenubar(): Promise<void> {
  await Promise.all([
    launchCommand({ name: "focused-project", type: LaunchType.Background }),
    launchCommand({ name: "focused-project-status", type: LaunchType.Background }),
  ]);
}
