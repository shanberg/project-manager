import path from "path";
import { stat } from "fs/promises";
import { runPmWithPrefs, getPmPaths } from "./pm";
import { getNotes, getNextDueForProject, resolveNotesPath } from "./notes-api";
import { parseListAllOutput } from "./utils";
import { mapWithConcurrency, PM_CONCURRENCY } from "./concurrency";
import type { PreferenceValues } from "./types";

export type RecentProject = {
  name: string;
  basePath: string;
  mtime: number;
  done: number;
  total: number;
  /** Soonest effective due among open tasks, or null. */
  nextDue: string | null;
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
  nextDue: string | null;
  notes: RecentProject["notes"];
};

function toMs(m: Date | number): number {
  return m instanceof Date ? m.getTime() : m;
}

function dueSortKey(due: string | null): string {
  if (!due) return "9999-12-31";
  const prefix = due.slice(0, 10);
  if (prefix.length === 10 && /^\d{4}-\d{2}-\d{2}$/.test(prefix)) return prefix;
  return due;
}

export async function getRecentProjectsByEdit(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  limit: number,
  excludeKey?: string,
  focusedProjectData?: FocusedProjectData | null,
  signal?: AbortSignal,
): Promise<RecentProject[]> {
  const [paths, { stdout }] = await Promise.all([
    getPmPaths(prefs, signal),
    runPmWithPrefs(prefs, ["list", "--all"], signal),
  ]);
  const { active: activeNames, archive: archiveNames } =
    parseListAllOutput(stdout);

  const all: { name: string; basePath: string }[] = [
    ...activeNames.map((name) => ({ name, basePath: paths.activePath })),
    ...archiveNames.map((name) => ({ name, basePath: paths.archivePath })),
  ];

  const withMtime = await mapWithConcurrency(
    all,
    PM_CONCURRENCY,
    async ({ name, basePath }) => {
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(prefs, name, signal);
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
    },
  );

  const key = (p: { basePath: string; name: string }) => `${p.basePath}:${p.name}`;
  const sorted = [...withMtime].sort((a, b) => b.mtime - a.mtime);
  const excludeFocused = !!excludeKey;
  const takeCount = excludeFocused ? limit + 1 : limit;
  const topByMtime = sorted.slice(0, takeCount);

  const withData = await mapWithConcurrency(
    topByMtime,
    PM_CONCURRENCY,
    async (p): Promise<RecentProject> => {
      if (excludeKey && key(p) === excludeKey && focusedProjectData) {
        return {
          name: focusedProjectData.name,
          basePath: focusedProjectData.basePath,
          mtime: p.mtime,
          done: focusedProjectData.done,
          total: focusedProjectData.total,
          nextDue: focusedProjectData.nextDue,
          notes: focusedProjectData.notes,
        };
      }
      const notesPath = await resolveNotesPath(prefs, p.name, signal);
      let done = 0;
      let total = 0;
      let nextDue: string | null = null;
      let notes: RecentProject["notes"] = null;
      if (notesPath) {
        try {
          const out = await getNotes(prefs, p.name, signal);
          const todos = out.todos ?? [];
          total = todos.length;
          done = todos.filter((t) => t.checked).length;
          nextDue = getNextDueForProject(todos);
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
        nextDue,
        notes,
      };
    },
  );

  const withoutFocused = excludeKey
    ? withData.filter((p) => key(p) !== excludeKey)
    : withData;
  withoutFocused.sort((a, b) =>
    dueSortKey(a.nextDue).localeCompare(dueSortKey(b.nextDue)),
  );
  return withoutFocused.slice(0, limit);
}
