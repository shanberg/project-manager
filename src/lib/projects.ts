import { readdir } from "fs/promises";
import path from "path";

const PROJECT_PATTERN = /^(M|DE|P|I)-\d+\s+.+$/;

export async function getProjectFolders(basePath: string): Promise<string[]> {
  try {
    const entries = await readdir(basePath, { withFileTypes: true });
    return entries
      .filter((e) => e.isDirectory() && PROJECT_PATTERN.test(e.name))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}

export function matchProject(
  folders: string[],
  query: string
): string | null {
  const q = query.trim();
  if (!q) return null;

  const exact = folders.find((f) => f === q);
  if (exact) return exact;

  const prefixMatches = folders.filter((f) => f.startsWith(q));
  if (prefixMatches.length === 1) return prefixMatches[0];
  if (prefixMatches.length > 1) return null; // ambiguous

  return null;
}
