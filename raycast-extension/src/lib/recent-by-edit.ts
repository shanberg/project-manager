import path from "path";
import { readFile, stat } from "fs/promises";
import { runPmWithPrefs } from "./pm";
import {
  parseNotes,
  parseTodos,
  resolveNotesPath,
} from "@shanberg/project-manager/notes";
import { parseListAllOutput } from "./utils";
import type { PreferenceValues } from "./types";

export type RecentProject = {
  name: string;
  basePath: string;
  mtime: number;
  done: number;
  total: number;
  notes: { summary: string; problem: string; goals: string[]; approach: string } | null;
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
      const notesPath = await resolveNotesPath(projectPath);
      const mtime = notesPath
        ? (await stat(notesPath).catch(() => ({ mtime: 0 }))).mtime
        : (await stat(projectPath).catch(() => ({ mtime: 0 }))).mtime;
      let done = 0;
      let total = 0;
      let notes = null;
      if (notesPath) {
        try {
          const content = await readFile(notesPath, "utf-8");
          const parsed = parseNotes(content);
          const todos = parseTodos(parsed);
          total = todos.length;
          done = todos.filter((t) => t.checked).length;
          notes = {
            summary: parsed.summary,
            problem: parsed.problem,
            goals: parsed.goals,
            approach: parsed.approach,
          };
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
