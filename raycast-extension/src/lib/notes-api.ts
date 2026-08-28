/**
 * A project's notes, through pm's contract.
 *
 * Every read and write here is one action name and one result shape — `pm api call <action>`. This
 * file used to compose `pm notes todo …` flags itself and re-derive parts of the domain in
 * TypeScript (effective due dates, the task-line format); both are gone. The inputs are generated
 * from `pm api describe` into `pm-api.generated.ts`, so what this believes an action takes comes
 * from the binary rather than being maintained alongside it. See docs/api-contract.md.
 */

import { callApi } from "./pm-api";
import type { ApiResult, TaskRef } from "./pm-api";
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
  /** What this task is waiting on, from an inline `waiting: [[target]]`. A project, an area, or a person. */
  waiting?: string | null;
  /** Effective wait for display: own `waiting` if set, else the nearest waiting ancestor's. From notes show. */
  effectiveWaiting?: string | null;
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
  /**
   * The revision of the document these tasks were parsed from. Sent back on a batch to say "this is
   * the document I was looking at" — a batch skips a reference it can't resolve, which is right when
   * the batch itself removed it and wrong when someone else did, and this is what tells the two apart.
   * Single-task writes don't send it: their digest already names their one task.
   */
  revision?: string;
}

/** Sort key for due date comparison (earliest first). Uses YYYY-MM-DD prefix when present. */
function dueDateSortKey(s: string): string {
  const prefix = s.slice(0, 10);
  if (prefix.length === 10 && /^\d{4}-\d{2}-\d{2}$/.test(prefix)) return prefix;
  return s;
}

/**
 * Effective due for a todo: its own, or the nearest deadline inherited from an ancestor.
 *
 * Read from the field pm computes rather than derived again here. This used to walk the ancestors
 * itself, which is `todosWithEffectiveDueDates` in Swift written a second time in a second language —
 * exactly the duplication the contract exists to remove.
 */
export function getEffectiveDue(_todos: Todo[], todo: Todo): string | null {
  return todo.effectiveDueDate ?? todo.dueDate ?? null;
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

export async function fetchNotes(
  projectName: string,
  prefs: PreferenceValues,
): Promise<NotesShowOutput | null> {
  try {
    const result = await callApi<"notes.get", NotesShowOutput>(
      prefs,
      "notes.get",
      {
        project: projectName,
      },
    );
    return result.data ?? null;
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
  const result = await callApi<"notes.get", NotesShowOutput>(
    prefs,
    "notes.get",
    { project: projectName },
    { signal },
  );
  const parsed = result.data;
  if (!parsed?.notes) throw new Error("Invalid notes response");

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

/**
 * Write changed detail sections back, one action each.
 *
 * This used to send the whole document to `pm notes write`, which falls back to a full re-serialize
 * when it can't splice — dropping frontmatter and anything the model doesn't capture. The contract
 * has no whole-document action for exactly that reason, so this diffs against what's on disk and
 * sends only what changed. A change to something the contract can't set is an error rather than a
 * silent no-op, because a form that says it saved and didn't is the worse failure.
 */
export async function writeNotes(
  prefs: PreferenceValues,
  projectName: string,
  notes: ProjectNotes,
): Promise<void> {
  const current = await getNotes(prefs, projectName);
  const text = ["title", "summary", "problem", "approach"] as const;
  const lists = ["goals", "learnings"] as const;

  for (const key of text) {
    if (notes[key] !== current.notes[key]) {
      await callApi(prefs, "notes.setDetail", {
        project: projectName,
        key,
        value: notes[key],
      });
    }
  }
  for (const key of lists) {
    if (JSON.stringify(notes[key]) !== JSON.stringify(current.notes[key])) {
      await callApi(prefs, "notes.setDetail", {
        project: projectName,
        key,
        value: notes[key],
      });
    }
  }
  if (JSON.stringify(notes.links) !== JSON.stringify(current.notes.links)) {
    throw new Error(
      "Links are changed with addLinkToNotes, not by writing the whole document.",
    );
  }
}

/** The project's notes file on disk, or null if it hasn't got one. */
export async function resolveNotesPath(
  prefs: PreferenceValues,
  projectName: string,
  signal?: AbortSignal,
): Promise<string | null> {
  try {
    const result = await callApi<"project.get", { notesPath?: string | null }>(
      prefs,
      "project.get",
      { project: projectName },
      { signal },
    );
    return result.data?.notesPath ?? null;
  } catch {
    return null;
  }
}

/**
 * How a task is named to the contract: its session's ISO date, its line, and its digest.
 *
 * All three come from the read and go back unchanged. The digest is what lets pm notice that the
 * document moved between the two — a session started, a task inserted above — and act on the task we
 * meant rather than whatever now sits at that position. See docs/task-identity.md.
 */
function taskRef(todo: Todo): TaskRef {
  return {
    session: todo.sessionISODate ?? String(todo.sessionIndex ?? 0),
    line: todo.lineIndex ?? 0,
    digest: todo.digest ?? undefined,
  };
}

/** The task an action reports adding, found in the notes afterwards by the digest pm gave back. */
async function addedTodo(
  prefs: PreferenceValues,
  projectName: string,
  result: ApiResult,
  fallback: Todo,
): Promise<{ notes: ProjectNotes; todo: Todo }> {
  const digest = result.changed.find((c) => c.kind === "added")?.ref?.digest;
  const data = await getNotes(prefs, projectName);
  const found = digest
    ? data.todos.find((t) => t.digest === digest)
    : undefined;
  return { notes: data.notes, todo: found ?? fallback };
}

/** Toggle one todo (flip [ ] <-> [x]). */
export async function toggleTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  if (todo.checked) {
    await callApi(prefs, "task.reopen", {
      project: projectName,
      task: taskRef(todo),
    });
  } else {
    await callApi(prefs, "task.complete", {
      project: projectName,
      task: taskRef(todo),
      advanceFocus: false,
    });
  }
}

/** Complete every open todo in the list, leaving focus where it is. */
export async function toggleAllTodosInNotes(
  prefs: PreferenceValues,
  projectName: string,
  revision: string | undefined,
  todos: Todo[],
): Promise<void> {
  // One call for the whole selection: one write, one journal entry, one step to undo. Completing a
  // task completes its descendants, so a task an earlier parent already closed is skipped rather
  // than failing the batch — and `revision` is what keeps that tolerance from also swallowing a task
  // someone edited in Obsidian while this list sat on screen. This used to take the `ProjectNotes` it
  // never looked at; it takes the revision of that same read instead.
  const open = todos.filter((t) => !t.checked);
  if (open.length === 0) return;
  await callApi(prefs, "task.complete", {
    project: projectName,
    tasks: open.map(taskRef),
    revision,
    advanceFocus: false,
  });
}

/** Set or remove the inline due date on a task. */
export async function updateDueDateInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  dueDate: string | null,
): Promise<void> {
  await callApi(prefs, "task.setDue", {
    project: projectName,
    task: taskRef(todo),
    ...(dueDate ? { due: dueDate } : { clearDue: true }),
  });
}

/** Add a task to the current session, starting one if there isn't one to continue. */
export async function addTodoToTodaySession(
  prefs: PreferenceValues,
  projectName: string,
  text: string,
  dueDate?: string | null,
): Promise<void> {
  const trimmed = text.trim();
  if (trimmed.length === 0) return;
  await callApi(prefs, "task.add", {
    project: projectName,
    text: trimmed,
    ...(dueDate ? { due: dueDate } : {}),
  });
}

/** Append a note to the current session (starting one when there isn't one to continue). */
export async function appendNoteToTodaySession(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
  projectName: string,
  note: string,
): Promise<void> {
  const trimmed = note.trim();
  if (trimmed.length === 0) return;
  await callApi(prefs, "session.note", {
    project: projectName,
    prose: trimmed,
  });
}

/** Add a todo before the given todo, at the same hierarchy level. Returns the notes as written and
 * the anchor at its new position (for chaining "Add Another"). */
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
  const result = await callApi(prefs, "task.add", {
    project: projectName,
    text: trimmed,
    anchor: taskRef(beforeTodo),
    position: "before",
    ...(dueDate ? { due: dueDate } : {}),
  });
  // The anchor is what you keep adding before, and it has moved down a line — but its digest hasn't
  // changed, so it's found rather than calculated.
  const data = await getNotes(prefs, projectName);
  const anchor =
    data.todos.find((t) => t.digest === beforeTodo.digest) ?? beforeTodo;
  void result;
  return { notes: data.notes, nextBeforeTodo: anchor };
}

/** Add a todo after the given todo, at the same hierarchy level. Returns the notes as written and
 * the inserted todo (for chaining "Add Another"). */
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
  const result = await callApi(prefs, "task.add", {
    project: projectName,
    text: trimmed,
    anchor: taskRef(afterTodo),
    position: "after",
    ...(dueDate ? { due: dueDate } : {}),
  });
  const { notes, todo } = await addedTodo(
    prefs,
    projectName,
    result,
    afterTodo,
  );
  return { notes, insertedTodo: todo };
}

/** Add a todo as a child of the given parent (one indent level deeper) and focus it. */
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
  await callApi(prefs, "task.add", {
    project: projectName,
    text: trimmed,
    anchor: taskRef(parentTodo),
    position: "child",
    ...(dueDate ? { due: dueDate } : {}),
  });
}

/** Edit a todo's text in place; indent, checkbox state, due, and focus marker are preserved. */
export async function editTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  newText: string,
): Promise<void> {
  const trimmed = newText.trim();
  if (trimmed.length === 0) return;
  await callApi(prefs, "task.setText", {
    project: projectName,
    task: taskRef(todo),
    text: trimmed,
  });
}

/** Wrap the given todo (and its subtree) in a new parent task; focus stays on the wrapped task. */
export async function wrapTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
  newParentText: string,
): Promise<void> {
  const trimmed = newParentText.trim();
  if (trimmed.length === 0) return;
  await callApi(prefs, "task.wrap", {
    project: projectName,
    task: taskRef(todo),
    text: trimmed,
  });
}

/** Move the single " @" focus marker to the given todo's line. */
export async function setFocusToTodoInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  await callApi(prefs, "task.focus", {
    project: projectName,
    task: taskRef(todo),
  });
}

/** Complete the now task and its descendants, moving focus to the next open task.
 * See docs/task-focus-flow.md for how the next one is chosen. */
export async function completeAndAdvanceInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  _todos: Todo[],
  nowTodo: Todo,
): Promise<string> {
  const result = await callApi(prefs, "task.complete", {
    project: projectName,
    task: taskRef(nowTodo),
    advanceFocus: true,
  });
  // The domain's own sentence — "Completed X and 2 subtasks. Focus moves to Y." — so the HUD says
  // what the panel's receipt says rather than a second phrasing of the same event.
  return result.summary;
}

/** Undo: toggle the task back to unchecked and move focus (@) back to it. */
export async function undoCompleteInNotes(
  prefs: PreferenceValues,
  projectName: string,
  _notes: ProjectNotes,
  todo: Todo,
): Promise<void> {
  await callApi(prefs, "task.reopen", {
    project: projectName,
    task: taskRef(todo),
  });
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
  _notes: ProjectNotes,
  link: { label?: string; url?: string },
): Promise<void> {
  const url = link.url?.trim();
  if (!url) return;
  await callApi(prefs, "notes.addLink", {
    project: projectName,
    text: url,
    ...(link.label?.trim() ? { label: link.label.trim() } : {}),
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
