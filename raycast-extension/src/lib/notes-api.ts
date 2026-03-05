/**
 * Notes API via pm CLI (pm notes show / pm notes write).
 * Types match Swift PmLib JSON output.
 */

import { buildEnv, runPmWithPrefs, runPmWithStdin, syncObsidianPrefsToPmConfig } from "./pm";
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

export type FocusTarget = { rawLine: string };

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

  // If no task is focused but there are open tasks, focus the first one (best-effort).
  const openTodos = (parsed.todos ?? []).filter((t) => !t.checked);
  if (
    (parsed.focusedKey == null || parsed.focusedKey === "") &&
    openTodos.length > 0
  ) {
    try {
      await setFocusToTodoInNotes(
        prefs,
        projectName,
        parsed.notes,
        openTodos[0],
      );
      return getNotes(prefs, projectName);
    } catch {
      // Write failed (e.g. permissions, pm unavailable); return current data so fetch doesn't fail.
      return parsed;
    }
  }

  return parsed;
}

/** Write notes back via pm notes write (stdin JSON). */
export async function writeNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
): Promise<void> {
  await syncObsidianPrefsToPmConfig(prefs);
  const { stderr, code } = await runPmWithStdin(
    ["notes", "write", projectName],
    buildEnv(prefs),
    prefs.pmCliPath,
    JSON.stringify(notes),
  );
  if (code !== 0) throw new Error(stderr || "pm notes write failed");
}

/** Complete a todo and its descendants via pm notes todo complete. */
async function completeTodoViaCli(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  projectName: string,
  todo: Todo,
  advanceFocus: boolean,
): Promise<void> {
  const si = todo.sessionIndex ?? 0;
  const li = todo.lineIndex ?? 0;
  const args = [
    "notes",
    "todo",
    "complete",
    projectName,
    String(si),
    String(li),
  ];
  if (advanceFocus) args.push("--advance");
  const { stderr, code } = await runPmWithPrefs(prefs, args);
  if (code !== 0) throw new Error(stderr || "pm notes todo complete failed");
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

/** Toggle one todo in notes (flip [ ] <-> [x]) and write back. Completing cascades to children via CLI. */
export async function toggleTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  if (todo.checked) {
    const newLine = todo.rawLine.replace(/\[[xX]\]/, "[ ]");
    const updated =
      typeof todo.sessionIndex === "number" &&
      typeof todo.lineIndex === "number"
        ? replaceTodoAtPositionInNotes(
            notes,
            todo.sessionIndex,
            todo.lineIndex,
            newLine,
          )
        : replaceTodoRawLineInNotes(notes, todo.rawLine, newLine);
    await writeNotes(prefs, projectName, updated);
  } else {
    await completeTodoViaCli(prefs, projectName, todo, false);
  }
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

/** List-item prefix (indent + "- ") from a raw task line. Used so new tasks match the anchor's hierarchy level. */
function getListPrefix(rawLine: string): string {
  return rawLine.match(/^(\s*-\s+)/)?.[1] ?? "- ";
}

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
  const lines = session.body.split(/\r?\n/);
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

/** Add a todo to today's session. Creates today's session if missing. Sets focus to the new task. */
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
  let updated = { ...notes, sessions: updatedSessions };
  const newLine = `- [ ] ${text}`;
  updated = applyFocusToTodoInNotes(updated, { rawLine: newLine });
  await writeNotes(prefs, projectName, updated);
}

/** Add a todo line before the given todo in notes. Tasks are inserted in sequence (1, then 2, then …) before the anchor. New tasks use the same hierarchy level (indent) as the anchor. Returns updated notes and the anchor at its new position (for chaining "Add Another"). */
export async function addTodoBeforeInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  beforeTodo: Todo,
  text: string,
): Promise<{ notes: ProjectNotes; nextBeforeTodo: Todo }> {
  const prefix = getListPrefix(beforeTodo.rawLine);
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
  const nextBeforeTodo: Todo =
    typeof beforeTodo.sessionIndex === "number" &&
    typeof beforeTodo.lineIndex === "number"
      ? { ...beforeTodo, lineIndex: beforeTodo.lineIndex + 1 }
      : (() => {
          const pos = findTodoPositionInNotes(updated, beforeTodo.rawLine);
          return pos
            ? { ...beforeTodo, sessionIndex: pos.sessionIndex, lineIndex: pos.lineIndex }
            : beforeTodo;
        })();
  return { notes: updated, nextBeforeTodo };
}

/** Add a todo line after the given todo in notes. Tasks are inserted in sequence (each after the previous). New tasks use the same hierarchy level (indent) as the anchor. Returns updated notes and the inserted todo (for chaining "Add Another"). */
export async function addTodoAfterInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  afterTodo: Todo,
  text: string,
): Promise<{ notes: ProjectNotes; insertedTodo: Todo }> {
  const prefix = getListPrefix(afterTodo.rawLine);
  const newLine = `${prefix}[ ] ${text}`;
  const updated =
    typeof afterTodo.sessionIndex === "number" &&
    typeof afterTodo.lineIndex === "number"
      ? replaceTodoAtPositionInNotes(
          notes,
          afterTodo.sessionIndex,
          afterTodo.lineIndex,
          `${afterTodo.rawLine}\n${newLine}`,
        )
      : replaceTodoRawLineInNotes(
          notes,
          afterTodo.rawLine,
          `${afterTodo.rawLine}\n${newLine}`,
        );
  await writeNotes(prefs, projectName, updated);
  const insertedTodo: Todo =
    typeof afterTodo.sessionIndex === "number" &&
    typeof afterTodo.lineIndex === "number"
      ? {
          rawLine: newLine,
          sessionIndex: afterTodo.sessionIndex,
          lineIndex: afterTodo.lineIndex + 1,
          text,
          checked: false,
          context: "",
        }
      : (() => {
          const pos = findTodoPositionInNotes(updated, newLine);
          return pos
            ? {
                rawLine: newLine,
                sessionIndex: pos.sessionIndex,
                lineIndex: pos.lineIndex,
                text,
                checked: false,
                context: "",
              }
            : { rawLine: newLine, text, checked: false, context: "" };
        })();
  return { notes: updated, insertedTodo };
}

function normalizeLineForMatch(line: string): string {
  return line.replace(/\r/g, "").trimEnd();
}

function findTodoPositionInNotes(
  notes: ProjectNotes,
  rawLine: string,
): { sessionIndex: number; lineIndex: number } | null {
  const rawNorm = normalizeLineForMatch(rawLine);
  for (let si = 0; si < notes.sessions.length; si++) {
    const lines = notes.sessions[si].body.split(/\r?\n/);
    let taskCount = 0;
    for (const line of lines) {
      if (TODO_LINE_REGEX.test(line)) {
        if (line === rawLine || normalizeLineForMatch(line) === rawNorm) {
          return { sessionIndex: si, lineIndex: taskCount };
        }
        taskCount++;
      }
    }
  }
  return null;
}

/** Add a todo as a child of the given parent (insert right after parent, indent + 2 spaces). Sets focus to the new child. */
export async function addTodoAsChildInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  parentTodo: Todo,
  text: string,
): Promise<void> {
  const trimmed = text.trim();
  if (trimmed.length === 0) return;
  const parentPrefix = parentTodo.rawLine.match(/^(\s*-\s+)/)?.[1] ?? "- ";
  const childPrefix = "  " + parentPrefix;
  const newLine = `${childPrefix}[ ] ${trimmed}`;
  let updated =
    typeof parentTodo.sessionIndex === "number" &&
    typeof parentTodo.lineIndex === "number"
      ? replaceTodoAtPositionInNotes(
          notes,
          parentTodo.sessionIndex,
          parentTodo.lineIndex,
          `${parentTodo.rawLine}\n${newLine}`,
        )
      : replaceTodoRawLineInNotes(
          notes,
          parentTodo.rawLine,
          `${parentTodo.rawLine}\n${newLine}`,
        );
  const newChildPos =
    typeof parentTodo.sessionIndex === "number" &&
    typeof parentTodo.lineIndex === "number"
      ? {
          sessionIndex: parentTodo.sessionIndex,
          lineIndex: parentTodo.lineIndex + 1,
        }
      : findTodoPositionInNotes(updated, newLine);
  if (newChildPos) {
    updated = applyFocusToTodoInNotes(updated, { rawLine: newLine });
  }
  await writeNotes(prefs, projectName, updated);
}

/** Edit a todo's text in place; preserves indent, checkbox state, and focus marker. */
export async function editTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
  newText: string,
): Promise<void> {
  const trimmed = newText.trim();
  if (trimmed.length === 0) return;
  const prefix = todo.rawLine.match(/^(\s*-\s+)/)?.[1] ?? "- ";
  const checkMatch = todo.rawLine.match(/\[([ xX])\]/);
  const checkbox = checkMatch ? checkMatch[1] : " ";
  let newLine = `${prefix}[${checkbox}] ${trimmed}`;
  if (todo.isFocused) {
    newLine += FOCUS_MARKER;
  }
  const sessionIndex = todo.sessionIndex ?? 0;
  const lineIndex = todo.lineIndex ?? 0;
  const updated = replaceTodoAtPositionInNotes(
    notes,
    sessionIndex,
    lineIndex,
    newLine,
  );
  await writeNotes(prefs, projectName, updated);
}

/** Wrap the given todo in a new parent task (insert parent above, indent current by 2 spaces); focus stays on the wrapped task. */
export async function wrapTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
  newParentText: string,
): Promise<void> {
  const trimmed = newParentText.trim();
  if (trimmed.length === 0) return;
  const prefix = todo.rawLine.match(/^(\s*-\s+)/)?.[1] ?? "- ";
  const parentLine = `${prefix}[ ] ${trimmed}`;
  const childLine = "  " + todo.rawLine;
  const sessionIndex = todo.sessionIndex ?? 0;
  const lineIndex = todo.lineIndex ?? 0;
  const updated = replaceTodoAtPositionInNotes(
    notes,
    sessionIndex,
    lineIndex,
    `${parentLine}\n${childLine}`,
  );
  await writeNotes(prefs, projectName, updated);
}

const FOCUS_MARKER = " @";

/** Pure: return notes with " @" only on the given todo's line. Matches by content (rawLine) not position. */
function applyFocusToTodoInNotes(
  notes: ProjectNotes,
  todo: FocusTarget | null,
): ProjectNotes {
  if (!todo) {
    const sessions = notes.sessions.map((session) => {
      const lines = session.body.split(/\r?\n/);
      const newLines = lines.map((line) =>
        TODO_LINE_REGEX.test(line) && line.endsWith(FOCUS_MARKER)
          ? line.slice(0, -FOCUS_MARKER.length)
          : line,
      );
      return { ...session, body: newLines.join("\n") };
    });
    return { ...notes, sessions };
  }
  const targetNorm = normalizeLineForMatch(
    todo.rawLine.endsWith(FOCUS_MARKER)
      ? todo.rawLine.slice(0, -FOCUS_MARKER.length)
      : todo.rawLine,
  );
  const sessions = notes.sessions.map((session) => {
    const lines = session.body.split(/\r?\n/);
    const newLines = lines.map((line) => {
      if (!TODO_LINE_REGEX.test(line)) return line;
      const stripped = line.endsWith(FOCUS_MARKER)
        ? line.slice(0, -FOCUS_MARKER.length)
        : line;
      const isTarget = normalizeLineForMatch(stripped) === targetNorm;
      return isTarget ? stripped + FOCUS_MARKER : stripped;
    });
    return { ...session, body: newLines.join("\n") };
  });
  return { ...notes, sessions };
}

/** Move the single " @" focus marker to the given todo's line. Strips @ from all other task lines across all sessions. Matches by content (rawLine) not position. */
export async function setFocusToTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  const updated = applyFocusToTodoInNotes(notes, todo);
  await writeNotes(prefs, projectName, updated);
}

/** Complete the now task and its descendants, move focus to next open task. Uses CLI. */
export async function completeAndAdvanceInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  _todos: Todo[],
  nowTodo: Todo,
): Promise<void> {
  await completeTodoViaCli(prefs, projectName, nowTodo, true);
}

/** Undo: toggle the task back to unchecked and move focus (@) back to it. One write. */
export async function undoCompleteInNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  let newLine = todo.rawLine.replace(/\[[xX]\]/, "[ ]");
  if (newLine.endsWith(FOCUS_MARKER)) {
    newLine = newLine.slice(0, -FOCUS_MARKER.length).trimEnd();
  }
  const sessionIndex = todo.sessionIndex ?? 0;
  const lineIndex = todo.lineIndex ?? 0;
  let updated = replaceTodoAtPositionInNotes(
    notes,
    sessionIndex,
    lineIndex,
    newLine,
  );
  updated = applyFocusToTodoInNotes(updated, { rawLine: newLine });
  await writeNotes(prefs, projectName, updated);
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
