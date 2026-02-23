import { loadConfig } from "../lib/config.js";
import { createProject } from "../lib/scaffold.js";

export async function newProject(domain?: string, title?: string): Promise<void> {
  const config = await loadConfig();
  if (!config) {
    console.error("Config not found. Run 'pm config init' first.");
    process.exit(1);
  }

  const domainCode = domain?.toUpperCase();
  const projectTitle = title?.trim();

  if (!domainCode || !projectTitle) {
    console.error("Usage: pm new <domain> <title>");
    console.error("Example: pm new M 'Slides Redesign'");
    console.error("Domains:", Object.keys(config.domains).join(", "));
    process.exit(1);
  }

  if (!(domainCode in config.domains)) {
    console.error("Unknown domain:", domainCode);
    console.error("Known domains:", Object.keys(config.domains).join(", "));
    process.exit(1);
  }

  const projectPath = await createProject(config, domainCode, projectTitle);
  console.log("Created:", projectPath);
}
