import { readdir } from "fs/promises";
import { DEFAULT_DOMAINS } from "../types.js";

function buildProjectPattern(domainCodes: string[]): RegExp {
  const sorted = [...domainCodes].sort((a, b) => b.length - a.length);
  const escaped = sorted.map((c) => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  return new RegExp(`^(${escaped.join("|")})-\\d+\\s+.+$`);
}

export async function getProjectFolders(
  basePath: string,
  domainCodes?: string[]
): Promise<string[]> {
  const codes = domainCodes ?? Object.keys(DEFAULT_DOMAINS);
  if (codes.length === 0) return [];
  const pattern = buildProjectPattern(codes);
  try {
    const entries = await readdir(basePath, { withFileTypes: true });
    return entries
      .filter((e) => e.isDirectory() && pattern.test(e.name))
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
