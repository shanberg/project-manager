import { mkdir, writeFile, readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import type { PmConfig } from "../types.js";
import { resolvePaths } from "./config.js";
import { getNextFormattedNumber } from "./numbering.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function createProject(
  config: PmConfig,
  domainCode: string,
  title: string
): Promise<string> {
  const { activePath, archivePath } = resolvePaths(config);

  const formattedNum = await getNextFormattedNumber(
    activePath,
    archivePath,
    domainCode
  );
  const folderName = `${domainCode}-${formattedNum} ${title}`;
  const projectPath = path.join(activePath, folderName);

  await mkdir(projectPath, { recursive: true });

  for (const sub of config.subfolders) {
    await mkdir(path.join(projectPath, sub), { recursive: true });
  }

  const notesContent = await getNotesTemplate(title);
  const notesPath = path.join(projectPath, "docs", `Notes - ${title}.md`);
  await writeFile(notesPath, notesContent, "utf-8");

  return projectPath;
}

async function getNotesTemplate(title: string): Promise<string> {
  const templatePath = path.join(
    __dirname,
    "..",
    "..",
    "templates",
    "notes.md"
  );
  const template = await readFile(templatePath, "utf-8");
  return template.replace(/\{\{title\}\}/g, title);
}
