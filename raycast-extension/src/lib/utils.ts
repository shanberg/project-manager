import path from "path";
import os from "os";
import { existsSync } from "fs";
import { formatSessionDate } from "./notes-api";
import type { ProjectNotes } from "./notes-api";
import { runPmWithPrefs } from "./pm";
import type { PreferenceValues } from "./types";

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
  options?: ObsidianUriOptions
): string {
  const absolute = path.resolve(notesPath);
  const vault = options?.vault?.trim();
  const vaultRootRaw = options?.vaultRoot?.trim();
  const vaultRoot = vaultRootRaw ? path.resolve(expandPath(vaultRootRaw)) : null;
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
  session?: { date: string; label: string } | null
): ObsidianUriOptions | undefined {
  if (!prefs.obsidianVault?.trim() || !prefs.obsidianVaultRoot?.trim()) return undefined;
  const opts: ObsidianUriOptions = {
    vault: prefs.obsidianVault.trim(),
    vaultRoot: prefs.obsidianVaultRoot.trim(),
  };
  opts.heading = session ? getSessionHeading(session.date, session.label) : "Sessions";
  return opts;
}

export async function ensureTodaySession(
  projectName: string,
  notes: ProjectNotes | null,
  prefs: PreferenceValues
): Promise<{ date: string; label: string }> {
  const today = formatSessionDate(new Date());
  const existing = notes?.sessions.find((s) => s.date === today);
  if (existing) return existing;
  await runPmWithPrefs(prefs, ["notes", "session", "add", projectName, ""]);
  return { date: today, label: "" };
}

export function parseListAllOutput(stdout: string): { active: string[]; archive: string[] } {
  const lines = stdout.split("\n");
  const activeList: string[] = [];
  const archiveList: string[] = [];
  let inArchive = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "Archive:") {
      inArchive = true;
      continue;
    }
    if (trimmed === "Active:") continue;
    if (trimmed === "(none)") continue;
    if (line.startsWith(" ") && trimmed) {
      if (inArchive) archiveList.push(trimmed);
      else activeList.push(trimmed);
    }
  }
  return { active: activeList, archive: archiveList };
}

export function hasSrcDir(projectPath: string): boolean {
  return existsSync(path.join(projectPath, "src"));
}

/** Expected notes file path from project folder path (for display when file does not exist yet). */
export function getNotesPath(projectPath: string): string {
  const folderName = path.basename(projectPath);
  const spaceIdx = folderName.indexOf(" ");
  const title = spaceIdx >= 0 ? folderName.slice(spaceIdx + 1) : folderName;
  return path.join(projectPath, "docs", `Notes - ${title}.md`);
}
