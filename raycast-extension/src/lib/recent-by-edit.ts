import path from "path";
import { stat } from "fs/promises";
import { runPmWithPrefs } from "./pm";
import { getNotes, resolveNotesPath } from "./notes-api";
import { parseListAllOutput } from "./utils";
import type { PreferenceValues } from "./types";

export type RecentProject = {
  name: string;
  basePath: string;
  mtime: number;
  done: number;
  total: number;
  notes: {
    summary: string;
    problem: string;
    goals: string[];
    approach: string;
  } | null;
};

export async function getRecentProjectsByEdit(
  prefs: PreferenceValues,
  limit: number,
  excludeKey?: string,
): Promise<RecentProject[]> {
  const { stdout } = await runPmWithPrefs(prefs, ["list", "--all"]);
  const { active: activeNames, archive: archiveNames } =
    parseListAllOutput(stdout);

  const all: { name: string; basePath: string }[] = [
    ...activeNames.map((name) => ({ name, basePath: prefs.activePath })),
    ...archiveNames.map((name) => ({ name, basePath: prefs.archivePath })),
  ];

  const withMeta = await Promise.all(
    all.map(async ({ name, basePath }) => {
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(prefs, name);
      const statsNotes = notesPath
        ? await stat(notesPath).catch(() => null)
        : null;
      const statsProject = await stat(projectPath).catch(() => null);
      const mtime = statsNotes
        ? statsNotes.mtime instanceof Date
          ? statsNotes.mtime.getTime()
          : (statsNotes.mtime as number)
        : statsProject
          ? statsProject.mtime instanceof Date
            ? statsProject.mtime.getTime()
            : (statsProject.mtime as number)
          : 0;
      let done = 0;
      let total = 0;
      let notes = null;
      if (notesPath) {
        try {
          const out = await getNotes(prefs, name);
          total = out.todos.length;
          done = out.todos.filter((t) => t.checked).length;
          notes = out.notes
            ? {
                summary: out.notes.summary,
                problem: out.notes.problem,
                goals: out.notes.goals,
                approach: out.notes.approach,
              }
            : null;
        } catch {
          /* ignore */
        }
      }
      return { name, basePath, mtime, done, total, notes };
    }),
  );

  const exclude = excludeKey ? new Set([excludeKey]) : new Set<string>();
  const key = (p: RecentProject) => `${p.basePath}:${p.name}`;

  return withMeta
    .filter((p) => !exclude.has(key(p)))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, limit);
}
