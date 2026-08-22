/**
 * Notes API via pm CLI (pm notes show / pm notes write).
 * Types match Swift PmLib JSON output.
 *
 * Task-line edits (add / due / text / wrap / complete / undo / focus) all go through
 * `pm notes todo …`, which owns the on-disk task format: the canonical `<text> due: <date> @`
 * ordering, the single focus marker, and format-preserving line splicing. Doing that surgery here
 * instead would mean a second implementation of the format — and a full-document rewrite via
 * `pm notes write`, which drops frontmatter and any section the model doesn't capture. `writeNotes`
 * is therefore only for the detail sections (summary/problem/goals/approach/links/learnings).
 */

import {
  buildEnv,
  runPmWithPrefs,
  runPmWithStdin,
  syncObsidianPrefsToPmConfig,
} from "./pm";
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
  /** Parsed from inline `due: <date>` at end of task line. */
  dueDate?: string | null;
  /** Effective due for display: own dueDate if set, else earliest due among ancestors (nearest deadline). From notes show. */
  effectiveDueDate?: string | null;
  /** Short hash of `text`, from notes show. Sent back on writes to prove this is still the task we read. */
  digest?: string | null;
  /** ISO date of this task's session — the half of its address that survives a session being started. */
  sessionISODate?: string | null;
}

export interface NotesShowOutput {
  notes: ProjectNotes;
  todos: Todo[];
  /** Key of the focused todo if any: "sessionIndex:lineIndex". */
  focusedKey?: string | null;
}

/** Sort key for due date comparison (earliest first). Uses YYYY-MM-DD prefix when present. */
function dueDateSortKey(s: string): string {
  const prefix = s.slice(0, 10);
  if (prefix.length === 10 && /^\d{4}-\d{2}-\d{2}$/.test(prefix)) return prefix;
  return s;
}

/**
 * Effective due for a todo: earliest due among own and all ancestors (nearest deadline).
 * Use when CLI does not provide effectiveDueDate (e.g. older pm) or to double-check.
 */
export function getEffectiveDue(todos: Todo[], todo: Todo): string | null {
  const sessionIndex = todo.sessionIndex ?? 0;
  const sessionTodos = todos
    .filter((t) => (t.sessionIndex ?? 0) === sessionIndex)
    .sort((a, b) => (a.lineIndex ?? 0) - (b.lineIndex ?? 0));
  const idx = sessionTodos.findIndex(
    (t) =>
      t.lineIndex === todo.lineIndex && t.sessionIndex === todo.sessionIndex,
  );
  const candidates: string[] = [];
  if (todo.dueDate) candidates.push(todo.dueDate);
  if (idx >= 0) {
    let currentDepth = todo.depth ?? 0;
    let i = idx - 1;
    while (i >= 0) {
      const d = sessionTodos[i].depth ?? 0;
      if (d < currentDepth) {
        const due = sessionTodos[i].dueDate;
        if (due) candidates.push(due);
        currentDepth = d;
      }
      i--;
    }
  }
  if (candidates.length === 0) return null;
  return candidates.reduce((a, b) =>
    dueDateSortKey(a) < dueDateSortKey(b) ? a : b,
  );
}

/**
 * Earliest effective due among all open (unchecked) todos in the list.
 * Use for project-level "next due" in the project menubar.
 */
export function getNextDueForProject(todos: Todo[]): string | null {
  const openTodos = todos.filter((t) => !t.checked);
  const effectiveDues: string[] = [];
  for (const t of openTodos) {
    const due = getEffectiveDue(todos, t);
    if (due) effectiveDues.push(due);
  }
  if (effectiveDues.length === 0) return null;
  return effectiveDues.reduce((a, b) =>
    dueDateSortKey(a) < dueDateSortKey(b) ? a : b,
  );
}

/** A trailing inline `due: <date>`, optionally followed by the focus marker. */
const INLINE_DUE_SUFFIX =
  /\s+due:\s*(?:\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?|\d{1,2}-\d{1,2}-\d{4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)(?:\s*@)?$/;

/**
 * Display helper: drop a trailing inline `due:` (and focus marker) from task text. `pm notes show`
 * already returns text with both stripped — this is for raw lines and for text carrying the tokens
 * in either order, so a legacy `<text> @ due: <date>` line still renders as just its text.
 */
export function stripInlineDueFromText(text: string): string {
  return text
    .replace(INLINE_DUE_SUFFIX, "")
    .replace(/\s+@$/, "")
    .replace(INLINE_DUE_SUFFIX, "")
    .trimEnd();
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

/** First open (unchecked) leaf in document order. A leaf has no children (next task in same session has depth <= this, or last in session). */
function firstOpenLeaf(todos: Todo[]): Todo | undefined {
  const bySession = new Map<number, Todo[]>();
  for (const t of todos) {
    const si = t.sessionIndex ?? 0;
    if (!bySession.has(si)) bySession.set(si, []);
    bySession.get(si)!.push(t);
  }
  const sessionIndices = [...bySession.keys()].sort((a, b) => a - b);
  for (const si of sessionIndices) {
    const sessionTodos = bySession
      .get(si)!
      .sort((a, b) => (a.lineIndex ?? 0) - (b.lineIndex ?? 0));
    for (let i = 0; i < sessionTodos.length; i++) {
      const t = sessionTodos[i];
      if (t.checked) continue;
      const next = sessionTodos[i + 1];
      const depth = t.depth ?? 0;
      const isLeaf = next === undefined || (next.depth ?? 0) <= depth;
      if (isLeaf) return t;
    }
  }
  return undefined;
}

/** Call pm notes show and return parsed output. Throws on error. */
export async function getNotes(
  prefs: PreferenceValues,
  projectName: string,
  signal?: AbortSignal,
): Promise<NotesShowOutput> {
  const { stdout, stderr } = await runPmWithPrefs(
    prefs,
    ["notes", "show", projectName],
    signal,
  );
  const parsed = JSON.parse(stdout.trim()) as NotesShowOutput;
  if (!parsed?.notes) throw new Error(stderr || "Invalid notes response");

  const firstLeaf = firstOpenLeaf(parsed.todos ?? []);
  if (
    (parsed.focusedKey == null || parsed.focusedKey === "") &&
    firstLeaf !== undefined
  ) {
    try {
      await setFocusToTodoInNotes(prefs, projectName, parsed.notes, firstLeaf);
      return getNotes(prefs, projectName, signal);
    } catch {
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

/** Position of a todo as pm indexes them: session, then task line within that session. */
/**
 * How a task is named on the command line: `<session> <line>`, plus a `--digest` when we have one.
 *
 * The session is its ISO date wherever the CLI gave us one. Sessions are newest-first and a new one
 * is spliced in at the top, so starting a session — which quick add does by itself, first thing each
 * day — renumbers every session below it. A list rendered before that and clicked after it would
 * otherwise act on whatever task had moved into the position.
 *
 * The digest is the text we believe the task has. Between rendering a list and clicking a row, a task
 * can be inserted or deleted above it, and the CLI uses the digest to notice and to find the task
 * where it has actually gone. Without one it acts on the position and hopes, which is what this
 * extension did until now. See docs/task-identity.md.
 */
function todoAddress(todo: Todo): {
  session: string;
  line: string;
  digestArgs: string[];
} {
  return {
    session: todo.sessionISODate ?? String(todo.sessionIndex ?? 0),
    line: String(todo.lineIndex ?? 0),
    digestArgs: todo.digest ? ["--digest", todo.digest] : [],
  };
}

/** Run a `pm notes todo <sub> …` command. Throws with the CLI's own message on failure. */
async function runTodoCommand(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  sub: string,
  args: string[],
): Promise<void> {
  const { stderr, code } = await runPmWithPrefs(prefs, [
    "notes",
    "todo",
    sub,
    ...args,
  ]);
  if (code !== 0) {
    throw new Error(stderr.trim() || `pm notes todo ${sub} failed`);
  }
}

/** Complete a todo and its descendants via pm notes todo complete. */
async function completeTodoViaCli(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  projectName: string,
  todo: Todo,
  advanceFocus: boolean,
): Promise<void> {
  const { session, line, digestArgs } = todoAddress(todo);
  const args = [projectName, session, line, ...digestArgs];
  if (!advanceFocus) args.push("--no-advance");
  await runTodoCommand(prefs, "complete", args);
}

/**
 * Insert a task via `pm notes todo add` and return the notes as they are on disk afterwards, plus
 * the todo now sitting at `resultIndex` — the caller's next anchor. pm inserts a `before` task into
 * the anchor's own slot (pushing the anchor down one) and an `after`/`child` task into the slot right
 * below it, so the caller can name which of the two it wants back.
 */
async function insertTodoViaCli(
  prefs: PreferenceValues,
  projectName: string,
  anchor: Todo,
  text: string,
  dueDate: string | null | undefined,
  position: "before" | "after" | "child",
  resultIndex: (anchorLineIndex: number) => number,
): Promise<{ notes: ProjectNotes; todo: Todo }> {
  const { session, line, digestArgs } = todoAddress(anchor);
  const args = [projectName, text, ...digestArgs];
  if (dueDate) args.push("--due", dueDate);
  args.push(`--${position}`, session, line);
  await runTodoCommand(prefs, "add", args);

  const data = await getNotes(prefs, projectName);
  const wantedSession = anchor.sessionIndex ?? 0;
  const wantedLine = resultIndex(anchor.lineIndex ?? 0);
  const found = data.todos.find(
    (t) =>
      (t.sessionIndex ?? 0) === wantedSession &&
      (t.lineIndex ?? 0) === wantedLine,
  );
  return {
    notes: data.notes,
    todo: found ?? {
      ...anchor,
      sessionIndex: wantedSession,
      lineIndex: wantedLine,
    },
  };
}

/** Get notes file path via pm notes path. */
export async function resolveNotesPath(
  prefs: PreferenceValues,
  projectName: string,
  signal?: AbortSignal,
): Promise<string | null> {
  try {
    const { stdout } = await runPmWithPrefs(
      prefs,
      ["notes", "path", projectName],
      signal,
    );
    const p = stdout.trim();
    return p || null;
  } catch {
    return null;
  }
}

/** Toggle one todo in notes (flip [ ] <-> [x]). Check uses CLI complete; uncheck uses CLI undo. */
export async function toggleTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  if (todo.checked) {
    await undoCompleteInNotes(prefs, projectName, _notes, todo);
  } else {
    await completeTodoViaCli(prefs, projectName, todo, false);
  }
}

/** Complete every open todo in the list, leaving focus where it is. Uses CLI. */
export async function toggleAllTodosInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todos: Todo[],
): Promise<void> {
  // Completing a task also completes its descendants, and checking a line never shifts any line
  // index — so the positions captured before the loop stay valid, and a task already completed by an
  // earlier parent is simply a no-op.
  for (const todo of todos) {
    if (todo.checked) continue;
    await completeTodoViaCli(prefs, projectName, todo, false);
  }
}

/** Set or remove the inline due date on a task. Uses CLI. */
export async function updateDueDateInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  dueDate: string | null,
): Promise<void> {
  const { session, line, digestArgs } = todoAddress(todo);
  await runTodoCommand(prefs, "due", [
    projectName,
    session,
    line,
    dueDate ?? "--clear",
    ...digestArgs,
  ]);
}

/** Add a todo to today's session (creating it if missing) and focus it. Uses CLI. */
export async function addTodoToTodaySession(
  prefs: PreferenceValues,
  projectName: string,
  text: string,
  dueDate?: string | null,
): Promise<void> {
  const trimmed = text.trim();
  if (trimmed.length === 0) return;
  const args = [projectName, trimmed];
  if (dueDate) args.push("--due", dueDate);
  await runTodoCommand(prefs, "add", args);
}

/** Append a note to today's session (creating the session if missing). Uses CLI. */
export async function appendNoteToTodaySession(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  projectName: string,
  note: string,
): Promise<void> {
  const trimmed = note.trim();
  if (trimmed.length === 0) return;
  const { stderr, code } = await runPmWithPrefs(prefs, [
    "notes",
    "session",
    "note",
    projectName,
    trimmed,
  ]);
  if (code !== 0) {
    throw new Error(stderr.trim() || "pm notes session note failed");
  }
}

/** Add a todo before the given todo, at the same hierarchy level. Uses CLI. Returns the notes as
 * written and the anchor at its new position (for chaining "Add Another"). */
export async function addTodoBeforeInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  beforeTodo: Todo,
  text: string,
  dueDate?: string | null,
): Promise<{ notes: ProjectNotes; nextBeforeTodo: Todo }> {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    const data = await getNotes(prefs, projectName);
    return { notes: data.notes, nextBeforeTodo: beforeTodo };
  }
  const { notes, todo } = await insertTodoViaCli(
    prefs,
    projectName,
    beforeTodo,
    trimmed,
    dueDate,
    "before",
    (anchorLine) => anchorLine + 1,
  );
  return { notes, nextBeforeTodo: todo };
}

/** Add a todo after the given todo, at the same hierarchy level. Uses CLI. Returns the notes as
 * written and the inserted todo (for chaining "Add Another"). */
export async function addTodoAfterInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  afterTodo: Todo,
  text: string,
  dueDate?: string | null,
): Promise<{ notes: ProjectNotes; insertedTodo: Todo }> {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    const data = await getNotes(prefs, projectName);
    return { notes: data.notes, insertedTodo: afterTodo };
  }
  const { notes, todo } = await insertTodoViaCli(
    prefs,
    projectName,
    afterTodo,
    trimmed,
    dueDate,
    "after",
    (anchorLine) => anchorLine + 1,
  );
  return { notes, insertedTodo: todo };
}

/** Add a todo as a child of the given parent (one indent level deeper) and focus it. Uses CLI. */
export async function addTodoAsChildInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  parentTodo: Todo,
  text: string,
  dueDate?: string | null,
): Promise<void> {
  const trimmed = text.trim();
  if (trimmed.length === 0) return;
  const { session, line, digestArgs } = todoAddress(parentTodo);
  const args = [projectName, trimmed, ...digestArgs];
  if (dueDate) args.push("--due", dueDate);
  args.push("--child", session, line);
  await runTodoCommand(prefs, "add", args);
}

/** Edit a todo's text in place; indent, checkbox state, due, and focus marker are preserved. Uses CLI. */
export async function editTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  newText: string,
): Promise<void> {
  const trimmed = newText.trim();
  if (trimmed.length === 0) return;
  const { session, line, digestArgs } = todoAddress(todo);
  await runTodoCommand(prefs, "text", [projectName, session, line, trimmed, ...digestArgs]);
}

/** Wrap the given todo (and its subtree) in a new parent task; focus stays on the wrapped task. Uses CLI. */
export async function wrapTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  newParentText: string,
): Promise<void> {
  const trimmed = newParentText.trim();
  if (trimmed.length === 0) return;
  const { session, line, digestArgs } = todoAddress(todo);
  await runTodoCommand(prefs, "wrap", [projectName, session, line, trimmed, ...digestArgs]);
}

/** Move the single " @" focus marker to the given todo's line. Uses CLI. */
export async function setFocusToTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  const { session, line, digestArgs } = todoAddress(todo);
  await runTodoCommand(prefs, "focus", [projectName, session, line, ...digestArgs]);
}

/** Complete the now task and its descendants, move focus to next open task. Uses CLI. See docs/task-focus-flow.md for how next focus is chosen. */
export async function completeAndAdvanceInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  _todos: Todo[],
  nowTodo: Todo,
): Promise<void> {
  await completeTodoViaCli(prefs, projectName, nowTodo, true);
}

/** Undo: toggle the task back to unchecked and move focus (@) back to it. Uses CLI. */
export async function undoCompleteInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  const { session, line, digestArgs } = todoAddress(todo);
  await runTodoCommand(prefs, "undo", [projectName, session, line, ...digestArgs]);
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
