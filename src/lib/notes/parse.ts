import type { LinkEntry, ProjectNotes, Session } from "./types.js";

const SESSION_HEADING = /^###\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2}),\s+(\d{4})(?:\s+(.*))?$/;
const LINK_LINE = /^\s*-\s+(.+)$/;
const NESTED_LINK = /^\s{4}-\s+(.+)$/;
const URL_PATTERN = /^https?:\/\//;

const CALLOUT_START = /^>\s*\[!/;

function extractCallout(lines: string[], pattern: RegExp): string {
  const content: string[] = [];
  let inBlock = false;

  for (const line of lines) {
    if (pattern.test(line)) {
      inBlock = true;
      continue;
    }
    if (inBlock && CALLOUT_START.test(line)) break;
    if (inBlock && line.startsWith(">")) {
      const rest = line.slice(1).replace(/^\s/, "");
      content.push(rest);
      continue;
    }
    if (inBlock && !line.startsWith(">") && line.trim()) break;
  }
  return content.join("\n").trim();
}

function extractGoals(lines: string[]): string[] {
  const re = /^>\s*\[!info\]\s*Goals/i;
  const goals: string[] = [];
  let inBlock = false;

  for (const line of lines) {
    if (re.test(line)) {
      inBlock = true;
      continue;
    }
    if (inBlock && CALLOUT_START.test(line)) break;
    if (inBlock && line.startsWith(">")) {
      const m = line.replace(/^>\s*/, "").match(/^\d+\.\s*(.*)$/);
      if (m) goals.push(m[1]?.trim() ?? "");
      continue;
    }
    if (inBlock && !line.startsWith(">")) break;
  }
  return goals.length ? goals : ["", "", ""];
}

function parseLinksBlock(text: string): LinkEntry[] {
  const lines = text.split("\n");
  const entries: LinkEntry[] = [];
  let i = 0;

  while (i < lines.length) {
    const m = lines[i].match(LINK_LINE);
    if (!m) {
      i++;
      continue;
    }
    const part = m[1].trim();
    const colonIdx = part.indexOf(":");
    const isUrl = URL_PATTERN.test(part);

    if (colonIdx > 0 && !isUrl) {
      const label = part.slice(0, colonIdx).trim();
      const url = part.slice(colonIdx + 1).trim();
      entries.push(url ? { label, url } : { label });
    } else if (isUrl) {
      entries.push({ url: part });
    } else {
      const children: LinkEntry[] = [];
      i++;
      while (i < lines.length) {
        const nm = lines[i].match(NESTED_LINK);
        if (!nm) break;
        children.push({ url: nm[1].trim() });
        i++;
      }
      entries.push({ label: part, children });
      continue;
    }
    i++;
  }
  return entries.length ? entries : [{ label: undefined, url: undefined }];
}

function parseLearningsBlock(text: string): string[] {
  const items = text
    .split("\n")
    .map((l) => l.match(/^\s*-\s+(.*)$/)?.[1]?.trim() ?? "")
    .filter((s) => s !== undefined);
  return items.length ? items : [""];
}

function parseSessionsBlock(text: string): Session[] {
  const sessions: Session[] = [];
  const lines = text.split("\n");
  let i = 0;

  while (i < lines.length) {
    const m = lines[i].match(SESSION_HEADING);
    if (!m) {
      i++;
      continue;
    }
    const date = `${m[1]}, ${m[2]} ${m[3]}, ${m[4]}`;
    const label = m[5]?.trim() ?? "";
    const bodyLines: string[] = [];
    i++;
    while (i < lines.length && !lines[i].match(SESSION_HEADING) && !lines[i].match(/^##\s/)) {
      bodyLines.push(lines[i]);
      i++;
    }
    sessions.push({ date, label, body: bodyLines.join("\n").trim() });
  }
  return sessions;
}

export function parseNotes(markdown: string): ProjectNotes {
  const lines = markdown.split("\n");
  const title = lines.find((l) => l.startsWith("# "))?.replace(/^#\s+/, "").trim() ?? "";

  const summary = extractCallout(lines, /^>\s*\[!summary\]/i);
  const problem = extractCallout(lines, /^>\s*\[!question\]/i);
  const goals = extractGoals(lines);
  const approach = extractCallout(lines, /^>\s*\[!info\]\s*Approach/i);

  const linksStart = lines.findIndex((l) => /^##\s+Links\s*$/i.test(l));
  const learningsStart = lines.findIndex((l) => /^##\s+Learnings\s*$/i.test(l));
  const sessionsStart = lines.findIndex((l) => /^##\s+Sessions\s*$/i.test(l));

  const linksText =
    linksStart >= 0 && learningsStart > linksStart
      ? lines.slice(linksStart + 1, learningsStart).join("\n")
      : "";
  const learningsText =
    learningsStart >= 0 && sessionsStart > learningsStart
      ? lines.slice(learningsStart + 1, sessionsStart >= 0 ? sessionsStart : undefined).join("\n")
      : "";
  const sessionsText =
    sessionsStart >= 0 ? lines.slice(sessionsStart + 1).join("\n") : "";

  return {
    title,
    summary,
    problem,
    goals,
    approach,
    links: parseLinksBlock(linksText),
    learnings: parseLearningsBlock(learningsText),
    sessions: parseSessionsBlock(sessionsText),
  };
}
