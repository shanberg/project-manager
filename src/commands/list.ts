import { loadConfig, resolvePaths } from "../lib/config.js";
import { getProjectFolders } from "../lib/projects.js";

type ListScope = "active" | "archive" | "all";

export async function listProjects(scope: ListScope = "active"): Promise<void> {
  const config = await loadConfig();
  if (!config) {
    console.error("Config not found. Run 'pm config init' first.");
    process.exit(1);
  }

  const { activePath, archivePath } = resolvePaths(config);
  const domainCodes = Object.keys(config.domains);

  if (scope === "active" || scope === "all") {
    const active = await getProjectFolders(activePath, domainCodes);
    if (scope === "all") console.log("Active:");
    for (const name of active) {
      console.log(scope === "all" ? " " + name : name);
    }
    if (scope === "all" && active.length === 0) console.log("  (none)");
  }

  if (scope === "archive" || scope === "all") {
    const archive = await getProjectFolders(archivePath, domainCodes);
    if (scope === "all") console.log("\nArchive:");
    for (const name of archive) {
      console.log(scope === "all" ? " " + name : name);
    }
    if (scope === "archive" && archive.length === 0) console.log("(none)");
    if (scope === "all" && archive.length === 0) console.log("  (none)");
  }
}
