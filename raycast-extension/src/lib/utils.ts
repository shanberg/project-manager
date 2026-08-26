import path from "path";
import os from "os";
import { existsSync } from "fs";
import type { ProjectNotes } from "./notes-api";
import { callApi } from "./pm-api";
import type { PreferenceValues } from "./types";

/** Paths to apps for use with Raycast FileIcon (real app icons). */
export const FINDER_APP_PATH = "/System/Library/CoreServices/Finder.app";
export const OBSIDIAN_APP_PATH = "/Applications/Obsidian.app";

function expandPath(p: string): string {
  return p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

export interface ObsidianUriOptions {
  heading?: string;
  vault?: string;
  vaultRoot?: string;
}

export function getObsidianUri(
  notesPath: string,
  options?: ObsidianUriOptions,
): string {
  const absolute = path.resolve(notesPath);
  const vault = options?.vault?.trim();
  const vaultRootRaw = options?.vaultRoot?.trim();
  const vaultRoot = vaultRootRaw
    ? path.resolve(expandPath(vaultRootRaw))
    : null;
  const heading = options?.heading?.trim();

  if (vault && vaultRoot) {
    const relative = path.relative(vaultRoot, absolute);
    if (!relative.startsWith("..") && !path.isAbsolute(relative)) {
      const filepath = relative.replace(/\\/g, "/").replace(/\.md$/i, "");
      const params = new URLSearchParams();
      params.set("vault", vault);
      params.set("filepath", filepath);
      if (heading) params.set("heading", heading);
      return `obsidian://advanced-uri?${params.toString()}`;
    }
  }

  return `obsidian://open?path=${encodeURIComponent(absolute)}`;
}

export function getSessionHeading(date: string, label?: string): string {
  return label ? `${date} · ${label}` : date;
}

export function buildObsidianOptions(
  prefs: { obsidianVault?: string; obsidianVaultRoot?: string },
  session?: { date: string; label: string } | null,
): ObsidianUriOptions | undefined {
  if (!prefs.obsidianVault?.trim() || !prefs.obsidianVaultRoot?.trim())
    return undefined;
  const opts: ObsidianUriOptions = {
    vault: prefs.obsidianVault.trim(),
    vaultRoot: prefs.obsidianVaultRoot.trim(),
  };
  opts.heading = session
    ? getSessionHeading(session.date, session.label)
    : "Sessions";
  return opts;
}

export async function ensureTodaySession(
  projectName: string,
  notes: ProjectNotes | null,
  prefs: PreferenceValues,
): Promise<{ date: string; label: string }> {
  // `session.start` is idempotent and reports the session either way, so this doesn't have to
  // format today's date to look for it — which is what the extension used to do, in its own copy of
  // pm's session-date format.
  const result = await callApi<
    "session.start",
    { date?: string; label?: string }
  >(prefs, "session.start", { project: projectName });
  return { date: result.data?.date ?? "", label: result.data?.label ?? "" };
}

export function parseListAllOutput(stdout: string): {
  active: string[];
  areas: string[];
  archive: string[];
} {
  const headings: Record<string, "active" | "areas" | "archive"> = {
    "Active:": "active",
    "Areas:": "areas",
    "Archive:": "archive",
  };
  const out = {
    active: [] as string[],
    areas: [] as string[],
    archive: [] as string[],
  };
  let section: "active" | "areas" | "archive" = "active";

  for (const line of stdout.split("\n")) {
    const trimmed = line.trim();
    const heading = headings[trimmed];
    if (heading) {
      section = heading;
      continue;
    }
    if (trimmed === "(none)") continue;
    if (line.startsWith(" ") && trimmed) out[section].push(trimmed);
  }
  return out;
}

/**
 * Whether a folder name is an area rather than a project: a project carries a `CODE-NNN ` prefix and
 * an area doesn't. Mirrors `ProjectKind.of(folderName:)` in PmLib — the kind is derived from the name
 * everywhere, never stored, so both kinds can share one archive.
 */
const NUMBERED_PROJECT_PREFIX = /^[A-Za-z]+-\d+\s+/;

export function isAreaFolder(folderName: string): boolean {
  return !NUMBERED_PROJECT_PREFIX.test(folderName);
}

export function hasSrcDir(projectPath: string): boolean {
  return existsSync(path.join(projectPath, "src"));
}

/**
 * Expected notes file path from project folder path (for display when file does not exist yet).
 *
 * Only a real `CODE-NNN ` prefix comes off. Splitting on the first space — what this did until Areas
 * existed, matching the same bug in PmLib's `projectTitle` — turned the area "Team 1:1s" into "1:1s"
 * and pointed this at `docs/Notes - 1:1s.md`.
 */
export function getNotesPath(projectPath: string): string {
  const folderName = path.basename(projectPath);
  const title = folderName.replace(NUMBERED_PROJECT_PREFIX, "");
  return path.join(projectPath, "docs", `Notes - ${title}.md`);
}
