import type { ProjectNotes, Todo } from "./types.js";

const TODO_LINE = /^(\s*-\s+)\[([ xX])\]\s+(.*)$/;
const FOCUS_ANCHOR = /\s+@\s*$/;

export function parseTodos(notes: ProjectNotes): (Todo & { focused: boolean })[] {
  const todos: (Todo & { focused: boolean })[] = [];
  for (const session of notes.sessions) {
    const context = session.label ? `${session.date} · ${session.label}` : session.date;
    const lines = session.body.split("\n");
    for (const line of lines) {
      const m = line.match(TODO_LINE);
      if (!m) continue;
      const checked = m[2].toLowerCase() === "x";
      let text = m[3];
      const focused = FOCUS_ANCHOR.test(text);
      if (focused) text = text.replace(FOCUS_ANCHOR, "").trim();
      todos.push({
        text,
        checked,
        rawLine: line,
        context,
        focused,
      });
    }
  }
  return todos;
}
