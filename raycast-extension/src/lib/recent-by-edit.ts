import path from "path";
import { stat } from "fs/promises";
import { runPmWithPrefs, getPmPaths } from "./pm";
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

/** Pre-fetched data for the focused project so we can skip calling getNotes for it. */
export type FocusedProjectData = {
  name: string;
  basePath: string;
  done: number;
  total: number;
  notes: RecentProject["notes"];
};

function toMs(m: Date | number): number {
  return m instanceof Date ? m.getTime() : m;
}

export async function getRecentProjectsByEdit(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  limit: number,
  excludeKey?: string,
  focusedProjectData?: FocusedProjectData | null,
): Promise<RecentProject[]> {
  const [paths, { stdout }] = await Promise.all([
    getPmPaths(prefs),
    runPmWithPrefs(prefs, ["list", "--all"]),
  ]);
  const { active: activeNames, archive: archiveNames } =
    parseListAllOutput(stdout);

  const all: { name: string; basePath: string }[] = [
    ...activeNames.map((name) => ({ name, basePath: paths.activePath })),
    ...archiveNames.map((name) => ({ name, basePath: paths.archivePath })),
  ];

  const withMtime = await Promise.all(
    all.map(async ({ name, basePath }) => {
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(prefs, name);
      const statsNotes = notesPath
        ? await stat(notesPath).catch(() => null)
        : null;
      const statsProject = await stat(projectPath).catch(() => null);
      const mtime = statsNotes
        ? toMs(statsNotes.mtime)
        : statsProject
          ? toMs(statsProject.mtime)
          : 0;
      return { name, basePath, mtime };
    }),
  );

  const key = (p: { basePath: string; name: string }) => `${p.basePath}:${p.name}`;
  const sorted = [...withMtime].sort((a, b) => b.mtime - a.mtime);
  const excludeFocused = !!excludeKey;
  const takeCount = excludeFocused ? limit + 1 : limit;
  const topByMtime = sorted.slice(0, takeCount);

  const withData = await Promise.all(
    topByMtime.map(async (p): Promise<RecentProject> => {
      if (excludeKey && key(p) === excludeKey && focusedProjectData) {
        return {
          name: focusedProjectData.name,
          basePath: focusedProjectData.basePath,
          mtime: p.mtime,
          done: focusedProjectData.done,
          total: focusedProjectData.total,
          notes: focusedProjectData.notes,
        };
      }
      const notesPath = await resolveNotesPath(prefs, p.name);
      let done = 0;
      let total = 0;
      let notes: RecentProject["notes"] = null;
      if (notesPath) {
        try {
          const out = await getNotes(prefs, p.name);
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
      return {
        name: p.name,
        basePath: p.basePath,
        mtime: p.mtime,
        done,
        total,
        notes,
      };
    }),
  );

  const withoutFocused = excludeKey
    ? withData.filter((p) => key(p) !== excludeKey)
    : withData;
  return withoutFocused.slice(0, limit);
}
