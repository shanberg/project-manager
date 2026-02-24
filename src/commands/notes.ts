import path from "path";
import { loadConfig, resolvePaths } from "../lib/config.js";
import { getProjectFolders, matchProject } from "../lib/projects.js";
import {
  addSession,
  createNotesFromTemplate,
  formatSessionDate,
  getNotesPath,
  readNotesFile,
  resolveNotesPath,
  writeNotesFile,
} from "../lib/notes/index.js";

async function resolveProjectPath(nameOrPrefix: string): Promise<string> {
  const config = await loadConfig();
  if (!config) {
    throw new Error("Config not found. Run 'pm config init' first.");
  }

  const { activePath, archivePath } = resolvePaths(config);
  const domainCodes = Object.keys(config.domains);
  const active = await getProjectFolders(activePath, domainCodes);
  const archive = await getProjectFolders(archivePath, domainCodes);
  const matched = matchProject([...active, ...archive], nameOrPrefix);

  if (!matched) {
    const all = [...active, ...archive];
    const prefixMatches = all.filter((f) => f.startsWith(nameOrPrefix.trim()));
    if (prefixMatches.length > 1) {
      throw new Error(`Ambiguous match. Multiple projects: ${prefixMatches.join(", ")}`);
    }
    throw new Error(`No project found matching: ${nameOrPrefix}`);
  }

  const inActive = active.includes(matched);
  const basePath = inActive ? activePath : archivePath;
  return path.join(basePath, matched);
}

export async function notesSessionAdd(
  nameOrPrefix: string,
  label: string,
  dateStr?: string
): Promise<void> {
  const projectPath = await resolveProjectPath(nameOrPrefix);
  const notesPath = await resolveNotesPath(projectPath);

  if (!notesPath) {
    throw new Error(`Notes file not found. Expected: ${getNotesPath(projectPath)}`);
  }

  const notes = await readNotesFile(notesPath);
  const date = dateStr ? new Date(dateStr) : undefined;
  const updated = addSession(notes, label, date);
  await writeNotesFile(notesPath, updated);

  const sessionDate = formatSessionDate(date ?? new Date());
  console.log(`Added session: ${sessionDate} ${label}`);
}

export async function notesCurrentDay(): Promise<void> {
  console.log(formatSessionDate());
}

export async function notesPath(nameOrPrefix: string): Promise<void> {
  const projectPath = await resolveProjectPath(nameOrPrefix);
  const notesPath = (await resolveNotesPath(projectPath)) ?? getNotesPath(projectPath);
  console.log(notesPath);
}

export async function notesCreate(nameOrPrefix: string): Promise<void> {
  const projectPath = await resolveProjectPath(nameOrPrefix);
  const notesPath = await createNotesFromTemplate(projectPath);
  console.log("Created:", notesPath);
}
