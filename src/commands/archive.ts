import path from "path";
import { rename } from "fs/promises";
import { loadConfig, resolvePaths } from "../lib/config.js";
import { getProjectFolders, matchProject } from "../lib/projects.js";

export async function archiveProject(nameOrPrefix: string): Promise<void> {
  const config = await loadConfig();
  if (!config) {
    console.error("Config not found. Run 'pm config init' first.");
    process.exit(1);
  }

  const { activePath, archivePath } = resolvePaths(config);

  const folders = await getProjectFolders(activePath);
  const matched = matchProject(folders, nameOrPrefix);

  if (!matched) {
    const prefixMatches = folders.filter((f) => f.startsWith(nameOrPrefix.trim()));
    if (prefixMatches.length > 1) {
      console.error("Ambiguous match. Multiple projects start with:", nameOrPrefix);
      prefixMatches.forEach((f) => console.error(" -", f));
    } else {
      console.error("No project found matching:", nameOrPrefix);
      if (folders.length > 0) {
        console.error("Active projects:", folders.join(", "));
      }
    }
    process.exit(1);
  }

  const src = path.join(activePath, matched);
  const dest = path.join(archivePath, matched);

  await rename(src, dest);
  console.log("Archived:", matched);
}
