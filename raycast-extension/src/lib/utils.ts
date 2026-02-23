import path from "path";
import { existsSync } from "fs";

export function parseListAllOutput(stdout: string): { active: string[]; archive: string[] } {
  const lines = stdout.split("\n");
  const activeList: string[] = [];
  const archiveList: string[] = [];
  let inArchive = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "Archive:") {
      inArchive = true;
      continue;
    }
    if (trimmed === "Active:") continue;
    if (trimmed === "(none)") continue;
    if (line.startsWith(" ") && trimmed) {
      if (inArchive) archiveList.push(trimmed);
      else activeList.push(trimmed);
    }
  }
  return { active: activeList, archive: archiveList };
}

export function getObsidianUri(notesPath: string): string {
  const absolute = path.resolve(notesPath);
  return `obsidian://open?path=${encodeURIComponent(absolute)}`;
}

export function hasSrcDir(projectPath: string): boolean {
  return existsSync(path.join(projectPath, "src"));
}
