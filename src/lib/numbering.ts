import { readdir } from "fs/promises";
import path from "path";

/**
 * Parse project folders to extract existing numbers for a domain.
 * Accepts any padding: M-1, M-01, M-001, M-100, etc.
 */
export function parseProjectNumbers(
  folderNames: string[],
  domainCode: string
): { numbers: number[]; observedMinDigits: number } {
  const numbers: number[] = [];
  let observedMinDigits = 0;

  // Match: {domainCode}-{digits} {rest}
  const escapedDomain = domainCode.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^${escapedDomain}-(\\d+)\\s+.+$`);

  for (const name of folderNames) {
    const match = name.match(pattern);
    if (match) {
      const num = parseInt(match[1], 10);
      numbers.push(num);
      observedMinDigits = Math.max(observedMinDigits, match[1].length);
    }
  }

  return { numbers, observedMinDigits };
}

/**
 * Compute next number and padding for a domain.
 */
export function nextNumberAndPadding(
  existingNumbers: number[],
  observedMinDigits: number
): { nextNumber: number; formatted: string } {
  const nextNumber =
    existingNumbers.length > 0 ? Math.max(...existingNumbers) + 1 : 1;
  const requiredDigits = String(nextNumber).length;
  const padTo = Math.max(observedMinDigits, requiredDigits);
  const formatted = String(nextNumber).padStart(padTo, "0");
  return { nextNumber, formatted };
}

/**
 * Scan active and archive folders for project numbers in a domain.
 */
export async function getNextFormattedNumber(
  activePath: string,
  archivePath: string,
  domainCode: string
): Promise<string> {
  const allNames: string[] = [];

  for (const basePath of [activePath, archivePath]) {
    try {
      const entries = await readdir(basePath, { withFileTypes: true });
      for (const e of entries) {
        if (e.isDirectory()) allNames.push(e.name);
      }
    } catch {
      // Folder may not exist yet
    }
  }

  const { numbers, observedMinDigits } = parseProjectNumbers(
    allNames,
    domainCode
  );
  const { formatted } = nextNumberAndPadding(numbers, observedMinDigits);
  return formatted;
}
