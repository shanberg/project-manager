import type { LinkEntry, ProjectNotes } from "./types.js";

function escapeCalloutLine(s: string): string {
  return s ? `> ${s}` : "> ";
}

function serializeCallout(type: string, label: string, content: string): string {
  const lines = content ? content.split("\n") : [""];
  const block = lines.map((l) => escapeCalloutLine(l)).join("\n");
  return `> [!${type}] ${label}\n${block}`;
}

function serializeGoals(goals: string[]): string {
  const items = goals.length ? goals : ["", "", ""];
  const padded = items.length < 3 ? [...items, ...Array(3 - items.length).fill("")] : items.slice(0, 3);
  return padded.map((g, i) => escapeCalloutLine(`${i + 1}.  ${g}`)).join("\n");
}

function serializeLinks(entries: LinkEntry[]): string {
  if (!entries.length) return "- \n";
  return entries
    .map((e) => {
      if (e.children?.length) {
        const childLines = e.children.map((c) => (c.url ? `    - ${c.url}` : "")).filter(Boolean);
        return e.label ? `- ${e.label}\n${childLines.join("\n")}` : "";
      }
      if (e.label && e.url) return `- ${e.label}: ${e.url}`;
      if (e.url) return `- ${e.url}`;
      return "- ";
    })
    .filter(Boolean)
    .join("\n") || "- \n";
}

function serializeLearnings(items: string[]): string {
  const list = items.length ? items : [""];
  return list.map((i) => `- ${i}`).join("\n");
}

function serializeSessions(sessions: { date: string; label: string; body: string }[]): string {
  if (!sessions.length) return "";
  return sessions
    .map((s) => {
      const heading = `### ${s.date} ${s.label}`;
      return s.body ? `${heading}\n\n${s.body}` : heading;
    })
    .join("\n\n");
}

export function serializeNotes(notes: ProjectNotes): string {
  const parts: string[] = [];

  parts.push(`# ${notes.title}\n`);
  parts.push(serializeCallout("summary", "Summary", notes.summary));
  parts.push("\n");
  parts.push(serializeCallout("question", "Problem", notes.problem));
  parts.push("\n");
  parts.push(`> [!info] Goals\n${serializeGoals(notes.goals)}`);
  parts.push("\n");
  parts.push(serializeCallout("info", "Approach", notes.approach));
  parts.push("\n");
  parts.push("## Links\n\n");
  parts.push(serializeLinks(notes.links));
  parts.push("\n\n## Learnings\n\n");
  parts.push(serializeLearnings(notes.learnings));
  parts.push("\n\n## Sessions\n\n");
  parts.push(serializeSessions(notes.sessions));

  return parts.join("");
}
