import { existsSync } from "fs";
import { readFile, readdir, writeFile, mkdir } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { parseNotes } from "./parse.js";
import { serializeNotes } from "./serialize.js";
import type { LinkEntry, ProjectNotes, Session, Todo } from "./types.js";

export type { LinkEntry, ProjectNotes, Session, Todo } from "./types.js";
export { parseTodos } from "./todos.js";
export { parseNotes } from "./parse.js";
export { serializeNotes } from "./serialize.js";

export function formatSessionDate(date: Date = new Date()): string {
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export function addSession(notes: ProjectNotes, label: string, date?: Date): ProjectNotes {
  const session: Session = {
    date: formatSessionDate(date ?? new Date()),
    label,
    body: "",
  };
  return {
    ...notes,
    sessions: [session, ...notes.sessions],
  };
}

export function getNotesPath(projectPath: string): string {
  const folderName = path.basename(projectPath);
  const spaceIdx = folderName.indexOf(" ");
  const title = spaceIdx >= 0 ? folderName.slice(spaceIdx + 1) : folderName;
  return path.join(projectPath, "docs", `Notes - ${title}.md`);
}

export async function resolveNotesPath(projectPath: string): Promise<string | null> {
  const canonical = getNotesPath(projectPath);
  if (existsSync(canonical)) return canonical;

  const docsPath = path.join(projectPath, "docs");
  try {
    const entries = await readdir(docsPath);
    const notesFiles = entries.filter((f) => f.startsWith("Notes - ") && f.endsWith(".md"));
    if (notesFiles.length === 1) return path.join(docsPath, notesFiles[0]);
    if (notesFiles.length > 1) {
      const canonicalName = path.basename(canonical);
      const match = notesFiles.find((f) => f === canonicalName);
      return path.join(docsPath, match ?? notesFiles[0]);
    }
  } catch {
    return null;
  }
  return null;
}

export async function readNotesFile(notesPath: string): Promise<ProjectNotes> {
  const content = await readFile(notesPath, "utf-8");
  return parseNotes(content);
}

export async function writeNotesFile(notesPath: string, notes: ProjectNotes): Promise<void> {
  const content = serializeNotes(notes);
  await writeFile(notesPath, content, "utf-8");
}

export async function createNotesFromTemplate(projectPath: string): Promise<string> {
  const folderName = path.basename(projectPath);
  const spaceIdx = folderName.indexOf(" ");
  const title = spaceIdx >= 0 ? folderName.slice(spaceIdx + 1) : folderName;
  const notesPath = getNotesPath(projectPath);

  if (existsSync(notesPath)) {
    throw new Error(`Notes file already exists: ${notesPath}`);
  }

  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const templatePath = path.join(__dirname, "..", "..", "..", "templates", "notes.md");
  const template = await readFile(templatePath, "utf-8");
  const content = template.replace(/\{\{title\}\}/g, title);

  await mkdir(path.join(projectPath, "docs"), { recursive: true });
  await writeFile(notesPath, content, "utf-8");
  return notesPath;
}

export async function toggleTodoInFile(notesPath: string, todo: Todo): Promise<void> {
  const content = await readFile(notesPath, "utf-8");
  const newLine = todo.checked
    ? todo.rawLine.replace(/\[[xX]\]/, "[ ]")
    : todo.rawLine.replace(/\[ \]/, "[x]");
  const updated = content.replace(todo.rawLine, newLine);
  if (updated === content) {
    throw new Error("Todo line not found in file");
  }
  await writeFile(notesPath, updated, "utf-8");
}

export async function toggleAllTodosInFile(
  notesPath: string,
  todos: Todo[]
): Promise<void> {
  if (todos.length === 0) return;
  let content = await readFile(notesPath, "utf-8");
  for (const todo of todos) {
    if (todo.checked) continue;
    const newLine = todo.rawLine.replace(/\[ \]/, "[x]");
    content = content.replace(todo.rawLine, newLine);
  }
  await writeFile(notesPath, content, "utf-8");
}

export type NotesSectionUpdate = Partial<
  Pick<ProjectNotes, "summary" | "problem" | "goals" | "approach" | "links" | "learnings">
>;

export async function updateNotesSection(
  notesPath: string,
  updates: NotesSectionUpdate
): Promise<void> {
  const notes = await readNotesFile(notesPath);
  const updated = { ...notes, ...updates };
  await writeNotesFile(notesPath, updated);
}

export async function addLinkToNotes(
  notesPath: string,
  link: { label?: string; url?: string }
): Promise<void> {
  const notes = await readNotesFile(notesPath);
  const links = [...notes.links];
  const emptyIdx = links.findIndex((l) => !l.label && !l.url);
  const newEntry = link.url ? { label: link.label?.trim() || undefined, url: link.url.trim() } : null;
  if (!newEntry) return;
  if (emptyIdx >= 0) {
    links[emptyIdx] = newEntry;
  } else {
    links.push(newEntry);
  }
  await writeNotesFile(notesPath, { ...notes, links });
}

const TODO_PREFIX = /^(\s*-\s+)/;

export async function addTodoBeforeInFile(
  notesPath: string,
  beforeTodo: Todo,
  text: string
): Promise<void> {
  const content = await readFile(notesPath, "utf-8");
  const prefix = beforeTodo.rawLine.match(TODO_PREFIX)?.[1] ?? "- ";
  const newLine = `${prefix}[ ] ${text}`;
  const updated = content.replace(beforeTodo.rawLine, `${newLine}\n${beforeTodo.rawLine}`);
  if (updated === content) {
    throw new Error("Todo line not found in file");
  }
  await writeFile(notesPath, updated, "utf-8");
}

export async function addTodoToTodaySession(
  notesPath: string,
  text: string
): Promise<void> {
  const notes = await readNotesFile(notesPath);
  const today = formatSessionDate(new Date());
  const todaySessionIndex = notes.sessions.findIndex((s) => s.date === today);
  let sessions = notes.sessions;

  if (todaySessionIndex < 0) {
    const updated = addSession(notes, "", new Date());
    sessions = updated.sessions;
  }

  const sessionIndex = todaySessionIndex >= 0 ? todaySessionIndex : 0;
  const session = sessions[sessionIndex];
  const newBody = session.body ? `${session.body}\n- [ ] ${text}` : `- [ ] ${text}`;
  const updatedSessions = sessions.map((s, i) =>
    i === sessionIndex ? { ...s, body: newBody } : s
  );
  await writeNotesFile(
    notesPath,
    { ...notes, sessions: updatedSessions }
  );
}

const MAX_CONTENT_LENGTH = 200;
const SESSION_LIMIT = 8;

function truncate(text: string, max: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.slice(0, max).trim() + "…";
}

function formatLink(l: { label?: string; url?: string; children?: { url?: string }[] }): string[] {
  if (l.label && l.url) return [`- [${l.label}](${l.url})`];
  if (l.url) return [`- [${l.url}](${l.url})`];
  if (l.label && l.children?.length) {
    const childLinks = l.children
      .filter((c) => c.url)
      .map((c) => `  - [${c.url}](${c.url})`);
    return [`- ${l.label}`, ...childLinks];
  }
  return [];
}

export function formatNotesForDetail(notes: ProjectNotes): string {
  const parts: string[] = [];
  if (notes.summary) parts.push(`### Summary\n${truncate(notes.summary, MAX_CONTENT_LENGTH)}\n`);
  if (notes.problem) parts.push(`### Problem\n${truncate(notes.problem, MAX_CONTENT_LENGTH)}\n`);
  if (notes.goals.some(Boolean)) {
    const goalsList = notes.goals
      .filter(Boolean)
      .map((g, i) => `${i + 1}. ${truncate(g, MAX_CONTENT_LENGTH)}`)
      .join("\n");
    parts.push(`### Goals\n${goalsList}\n`);
  }
  if (notes.approach) parts.push(`### Approach\n${truncate(notes.approach, MAX_CONTENT_LENGTH)}\n`);
  if (notes.links.some((l: LinkEntry) => l.label || l.url)) {
    const linkLines = notes.links.flatMap(formatLink).filter(Boolean);
    parts.push(`### Links\n${linkLines.join("\n")}\n`);
  }
  if (notes.learnings.some(Boolean)) {
    const learnList = notes.learnings
      .filter(Boolean)
      .map((l: string) => `- ${truncate(l, MAX_CONTENT_LENGTH)}`)
      .join("\n");
    parts.push(`### Learnings\n${learnList}\n`);
  }
  if (notes.sessions.length) {
    const sessionLines = notes.sessions
      .slice(0, SESSION_LIMIT)
      .map((s: Session) => `- ${s.label ? `${s.date} · ${s.label}` : s.date}`);
    const more = notes.sessions.length > SESSION_LIMIT
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
