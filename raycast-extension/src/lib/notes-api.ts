/**
 * Notes API via pm CLI (pm notes show / pm notes write).
 * Types match Swift PmLib JSON output.
 */

import { buildEnv, ensureConfig, runPmWithPrefs, runPmWithStdin } from "./pm";
import type { PreferenceValues } from "./types";

export interface LinkEntry {
  label?: string;
  url?: string;
  children?: { url?: string }[];
}

export interface Session {
  date: string;
  label: string;
  body: string;
}

export interface ProjectNotes {
  title: string;
  summary: string;
  problem: string;
  goals: string[];
  approach: string;
  links: LinkEntry[];
  learnings: string[];
  sessions: Session[];
}

export interface Todo {
  text: string;
  checked: boolean;
  rawLine: string;
  context: string;
  /** Indent depth (0 = root, 2 spaces = 1 level). */
  depth?: number;
  /** Index of the session in notes.sessions. */
  sessionIndex?: number;
  /** Index of the task line within that session (among task lines). */
  lineIndex?: number;
  /** True if this task is the single focused item (line ends with " @"). */
  isFocused?: boolean;
}

export interface NotesShowOutput {
  notes: ProjectNotes;
  todos: Todo[];
  /** Key of the focused todo if any: "sessionIndex:lineIndex". */
  focusedKey?: string | null;
}

export async function fetchNotes(
  projectName: string,
  prefs: PreferenceValues,
): Promise<NotesShowOutput | null> {
  try {
    const { stdout } = await runPmWithPrefs(prefs, [
      "notes",
      "show",
      projectName,
    ]);
    if (!stdout.trim()) return null;
    return JSON.parse(stdout.trim()) as NotesShowOutput;
  } catch {
    return null;
  }
}

/** Call pm notes show and return parsed output. Throws on error. */
export async function getNotes(
  prefs: PreferenceValues,
  projectName: string,
): Promise<NotesShowOutput> {
  const { stdout, stderr } = await runPmWithPrefs(prefs, [
    "notes",
    "show",
    projectName,
  ]);
  const parsed = JSON.parse(stdout.trim()) as NotesShowOutput;
  if (!parsed?.notes) throw new Error(stderr || "Invalid notes response");
  return parsed;
}

/** Write notes back via pm notes write (stdin JSON). */
export async function writeNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
): Promise<void> {
  await ensureConfig(prefs.activePath, prefs.archivePath, prefs.configPath);
  const { stderr, code } = await runPmWithStdin(
    ["notes", "write", projectName],
    buildEnv(prefs),
    prefs.pmCliPath,
    JSON.stringify(notes),
  );
  if (code !== 0) throw new Error(stderr || "pm notes write failed");
}

/** Get notes file path via pm notes path. */
export async function resolveNotesPath(
  prefs: PreferenceValues,
  projectName: string,
): Promise<string | null> {
  try {
    const { stdout } = await runPmWithPrefs(prefs, [
      "notes",
      "path",
      projectName,
    ]);
    const p = stdout.trim();
    return p || null;
  } catch {
    return null;
  }
}

/** Toggle one todo in notes (flip [ ] <-> [x]) and write back. Uses position when available to avoid duplicate rawLine ambiguity. */
export async function toggleTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  const newLine = todo.checked
    ? todo.rawLine.replace(/\[[xX]\]/, "[ ]")
    : todo.rawLine.replace(/\[ \]/, "[x]");
  const updated =
    typeof todo.sessionIndex === "number" && typeof todo.lineIndex === "number"
      ? replaceTodoAtPositionInNotes(
          notes,
          todo.sessionIndex,
          todo.lineIndex,
          newLine,
        )
      : replaceTodoRawLineInNotes(notes, todo.rawLine, newLine);
  await writeNotes(prefs, projectName, updated);
}

/** Toggle multiple todos (all to [x]) and write back. */
export async function toggleAllTodosInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todos: Todo[],
): Promise<void> {
  let updated = notes;
  for (const todo of todos) {
    if (todo.checked) continue;
    const newLine = todo.rawLine.replace(/\[ \]/, "[x]");
    updated = replaceTodoRawLineInNotes(updated, todo.rawLine, newLine);
  }
  await writeNotes(prefs, projectName, updated);
}

const TODO_LINE_REGEX = /^\s*-\s+\[([ xX])\]\s+(.*)$/;

function replaceTodoRawLineInNotes(
  notes: ProjectNotes,
  oldLine: string,
  newLine: string,
): ProjectNotes {
  const sessions = notes.sessions.map((s) =>
    s.body.includes(oldLine)
      ? { ...s, body: s.body.replace(oldLine, newLine) }
      : s,
  );
  return { ...notes, sessions };
}

/** Replace the task at (sessionIndex, lineIndex) with newLine. Use when rawLine is ambiguous (duplicates). */
function replaceTodoAtPositionInNotes(
  notes: ProjectNotes,
  sessionIndex: number,
  lineIndex: number,
  newLine: string,
): ProjectNotes {
  const session = notes.sessions[sessionIndex];
  if (!session) return notes;
  const lines = session.body.split("\n");
  let taskCount = 0;
  const newLines = lines.map((line) => {
    if (!TODO_LINE_REGEX.test(line)) return line;
    if (taskCount === lineIndex) {
      taskCount++;
      return newLine;
    }
    taskCount++;
    return line;
  });
  const newBody = newLines.join("\n");
  const sessions = notes.sessions.map((s, i) =>
    i === sessionIndex ? { ...s, body: newBody } : s,
  );
  return { ...notes, sessions };
}

/** Add a todo to today's session. Creates today's session if missing. */
export async function addTodoToTodaySession(
  prefs: PreferenceValues,
  projectName: string,
  text: string,
): Promise<void> {
  const data = await getNotes(prefs, projectName);
  const notes = data.notes;
  const today = formatSessionDate(new Date());
  let sessions = [...notes.sessions];
  const todayIdx = sessions.findIndex((s) => s.date === today);
  if (todayIdx < 0) {
    await runPmWithPrefs(prefs, ["notes", "session", "add", projectName, ""]);
    const refreshed = await getNotes(prefs, projectName);
    sessions = refreshed.notes.sessions;
  }
  const idx = todayIdx >= 0 ? todayIdx : 0;
  const session = sessions[idx];
  const newBody = session.body
    ? `${session.body}\n- [ ] ${text}`
    : `- [ ] ${text}`;
  const updatedSessions = sessions.map((s, i) =>
    i === idx ? { ...s, body: newBody } : s,
  );
  await writeNotes(prefs, projectName, { ...notes, sessions: updatedSessions });
}

/** Add a todo line before the given todo in notes. */
export async function addTodoBeforeInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  beforeTodo: Todo,
  text: string,
): Promise<void> {
  const prefix = beforeTodo.rawLine.match(/^(\s*-\s+)/)?.[1] ?? "- ";
  const newLine = `${prefix}[ ] ${text}`;
  const updated =
    typeof beforeTodo.sessionIndex === "number" &&
    typeof beforeTodo.lineIndex === "number"
      ? replaceTodoAtPositionInNotes(
          notes,
          beforeTodo.sessionIndex,
          beforeTodo.lineIndex,
          `${newLine}\n${beforeTodo.rawLine}`,
        )
      : replaceTodoRawLineInNotes(
          notes,
          beforeTodo.rawLine,
          `${newLine}\n${beforeTodo.rawLine}`,
        );
  await writeNotes(prefs, projectName, updated);
}

const FOCUS_MARKER = " @";

/** Move the single " @" focus marker to the given todo's line. Strips @ from all other task lines across all sessions. */
export async function setFocusToTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  const targetSessionIndex = todo.sessionIndex ?? 0;
  const targetLineIndex = todo.lineIndex ?? 0;
  const sessions = notes.sessions.map((session, si) => {
    const lines = session.body.split("\n");
    let taskCount = 0;
    const newLines = lines.map((line) => {
      if (!TODO_LINE_REGEX.test(line)) return line;
      const isTarget =
        si === targetSessionIndex && taskCount === targetLineIndex;
      taskCount++;
      const stripped = line.endsWith(FOCUS_MARKER)
        ? line.slice(0, -FOCUS_MARKER.length).trimEnd()
        : line;
      return isTarget ? stripped + FOCUS_MARKER : stripped;
    });
    return { ...session, body: newLines.join("\n") };
  });
  await writeNotes(prefs, projectName, { ...notes, sessions });
}

/** Update sections (summary, problem, goals, approach, links, learnings). */
export function updateNotesSection(
  notes: ProjectNotes,
  updates: Partial<
    Pick<
      ProjectNotes,
      "summary" | "problem" | "goals" | "approach" | "links" | "learnings"
    >
  >,
): ProjectNotes {
  return { ...notes, ...updates };
}

/** Add a link to notes and write back. */
export async function addLinkToNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  link: { label?: string; url?: string },
): Promise<void> {
  const links = [...notes.links];
  const emptyIdx = links.findIndex((l) => !l.label && !l.url);
  const newEntry = link.url
    ? { label: link.label?.trim() || undefined, url: link.url.trim() }
    : null;
  if (!newEntry) return;
  if (emptyIdx >= 0) {
    links[emptyIdx] = newEntry;
  } else {
    links.push(newEntry);
  }
  await writeNotes(prefs, projectName, { ...notes, links });
}

/** Session date format matching pm notes current-day (en-US short). */
export function formatSessionDate(date: Date = new Date()): string {
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

const MAX_CONTENT_LENGTH = 200;
const SESSION_LIMIT = 8;

function truncate(text: string, max: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.slice(0, max).trim() + "…";
}

function formatLink(l: LinkEntry): string[] {
  if (l.label && l.url) return [`- [${l.label}](${l.url})`];
  if (l.url) return [`- [${l.url}](${l.url})`];
  if (l.label && l.children?.length) {
    const childLinks = (l.children ?? [])
      .filter((c) => c.url)
      .map((c) => `  - [${c.url}](${c.url})`);
    return [`- ${l.label}`, ...childLinks];
  }
  return [];
}

export function formatNotesForDetail(notes: ProjectNotes): string {
  const parts: string[] = [];
  if (notes.summary)
    parts.push(`### Summary\n${truncate(notes.summary, MAX_CONTENT_LENGTH)}\n`);
  if (notes.problem)
    parts.push(`### Problem\n${truncate(notes.problem, MAX_CONTENT_LENGTH)}\n`);
  if (notes.goals.some(Boolean)) {
    const goalsList = notes.goals
      .filter(Boolean)
      .map((g, i) => `${i + 1}. ${truncate(g, MAX_CONTENT_LENGTH)}`)
      .join("\n");
    parts.push(`### Goals\n${goalsList}\n`);
  }
  if (notes.approach)
    parts.push(
      `### Approach\n${truncate(notes.approach, MAX_CONTENT_LENGTH)}\n`,
    );
  if (notes.links.some((l) => l.label || l.url)) {
    const linkLines = notes.links.flatMap(formatLink).filter(Boolean);
    parts.push(`### Links\n${linkLines.join("\n")}\n`);
  }
  if (notes.learnings.some(Boolean)) {
    const learnList = notes.learnings
      .filter(Boolean)
      .map((l) => `- ${truncate(l, MAX_CONTENT_LENGTH)}`)
      .join("\n");
    parts.push(`### Learnings\n${learnList}\n`);
  }
  if (notes.sessions.length) {
    const sessionLines = notes.sessions
      .slice(0, SESSION_LIMIT)
      .map((s) => `- ${s.label ? `${s.date} · ${s.label}` : s.date}`);
    const more =
      notes.sessions.length > SESSION_LIMIT
        ? `\n_…${notes.sessions.length - SESSION_LIMIT} more_`
        : "";
    parts.push(`### Sessions\n${sessionLines.join("\n")}${more}`);
  }
  if (parts.length === 0) {
    return "_No notes content yet._\n\nAdd content in the notes file or use **Add Session Note**.";
  }
  return parts.join("\n\n---\n\n");
}

export function formatNotesEmptyState(): string {
  return "_No notes file._\n\nCreate a new project or add a notes file in the project's `docs/` folder.";
}
