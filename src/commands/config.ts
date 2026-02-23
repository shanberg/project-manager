import { mkdir } from "fs/promises";
import path from "path";
import * as readline from "readline";
import {
  loadConfig,
  saveConfig,
  getConfigPath,
  createDefaultConfig,
} from "../lib/config.js";

function ask(question: string): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

export async function initConfig(): Promise<void> {
  const existing = await loadConfig();
  if (existing) {
    console.log("Config already exists at:", getConfigPath());
    const overwrite = await ask("Re-initialize? (y/N): ");
    if (overwrite.toLowerCase() !== "y") return;
  }

  console.log("Enter the path for active projects:");
  const activePath = await ask("Active path: ");
  if (!activePath) {
    console.error("No active path provided.");
    process.exit(1);
  }

  console.log("Enter the path for archived projects:");
  const archivePath = await ask("Archive path: ");
  if (!archivePath) {
    console.error("No archive path provided.");
    process.exit(1);
  }

  const config = createDefaultConfig(activePath, archivePath);
  await saveConfig(config);

  await mkdir(activePath, { recursive: true });
  await mkdir(archivePath, { recursive: true });

  console.log("Config saved to:", getConfigPath());
  console.log("Active:", activePath);
  console.log("Archive:", archivePath);
}

export async function getConfig(key?: string): Promise<void> {
  const config = await loadConfig();
  if (!config) {
    console.error("Config not found. Run 'pm config init' first.");
    process.exit(1);
  }

  if (key) {
    const value = (config as unknown as Record<string, unknown>)[key];
    if (value === undefined) {
      console.error("Unknown key:", key);
      process.exit(1);
    }
    console.log(JSON.stringify(value, null, 2));
  } else {
    console.log(JSON.stringify(config, null, 2));
  }
}

export async function setConfig(key: string, valueStr: string): Promise<void> {
  const config = await loadConfig();
  if (!config) {
    console.error("Config not found. Run 'pm config init' first.");
    process.exit(1);
  }

  const cfg = config as unknown as Record<string, unknown>;
  if (key === "paraPath" || key === "activePath" || key === "archivePath") {
    cfg[key] = valueStr;
  } else if (key === "domains" || key === "subfolders") {
    try {
      cfg[key] = JSON.parse(valueStr);
    } catch {
      console.error("Value must be valid JSON for", key);
      process.exit(1);
    }
  } else {
    console.error("Unknown key:", key);
    process.exit(1);
  }

  await saveConfig(config);
  console.log("Updated", key);
}
