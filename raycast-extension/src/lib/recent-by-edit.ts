import path from "path";
import { stat } from "fs/promises";
import { runPmWithPrefs } from "./pm";
import { resolveNotesPath } from "project-manager/notes";
import { parseListAllOutput } from "./utils";
import type { PreferenceValues } from "./types";

export type RecentProject = { name: string; basePath: string; mtime: number };

export async function getRecentProjectsByEdit(
  prefs: PreferenceValues,
  limit: number,
  excludeKey?: string
): Promise<RecentProject[]> {
  const { stdout } = await runPmWithPrefs(prefs, ["list", "--all"]);
  const { active: activeNames, archive: archiveNames } = parseListAllOutput(stdout);

  const all: { name: string; basePath: string }[] = [
    ...activeNames.map((name) => ({ name, basePath: prefs.activePath })),
    ...archiveNames.map((name) => ({ name, basePath: prefs.archivePath })),
  ];

  const withMtime = await Promise.all(
    all.map(async ({ name, basePath }) => {
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(projectPath);
      const mtime = notesPath
        ? (await stat(notesPath).catch(() => ({ mtime: 0 }))).mtime
        : (await stat(projectPath).catch(() => ({ mtime: 0 }))).mtime;
      return { name, basePath, mtime };
    })
  );

  const exclude = excludeKey ? new Set([excludeKey]) : new Set<string>();
  const key = (p: RecentProject) => `${p.basePath}:${p.name}`;

  return withMtime
    .filter((p) => !exclude.has(key(p)))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, limit);
}
