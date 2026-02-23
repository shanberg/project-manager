import type { ProjectNotes, Todo } from "./types.js";

const TODO_LINE = /^(\s*-\s+)\[([ xX])\]\s+(.*)$/;

export function parseTodos(notes: ProjectNotes): Todo[] {
  const todos: Todo[] = [];
  for (const session of notes.sessions) {
    const context = session.label ? `${session.date} · ${session.label}` : session.date;
    const lines = session.body.split("\n");
    for (const line of lines) {
      const m = line.match(TODO_LINE);
      if (!m) continue;
      const prefix = m[1];
      const checked = m[2].toLowerCase() === "x";
      const text = m[3];
      todos.push({
        text,
        checked,
        rawLine: line,
        context,
      });
    }
  }
  return todos;
}
