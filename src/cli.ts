#!/usr/bin/env node

import { Command } from "commander";
import { initConfig, getConfig, setConfig } from "./commands/config.js";
import { newProject } from "./commands/new.js";
import { listProjects } from "./commands/list.js";
import { archiveProject } from "./commands/archive.js";
import { unarchiveProject } from "./commands/unarchive.js";
import {
  notesSessionAdd,
  notesCreate,
  notesCurrentDay,
  notesPath,
} from "./commands/notes.js";

const program = new Command();

program
  .name("pm")
  .description("Project Manager - PARA-style project creation")
  .version("0.1.0");

program
  .command("new")
  .description("Create a new project")
  .argument("[domain]", "Domain code (M, DE, P, I)")
  .argument("[title]", "Project title")
  .action(async (domain, title) => {
    await newProject(domain, title);
  });

program
  .command("list")
  .description("List projects")
  .option("-a, --archive", "List archived projects only")
  .option("--all", "List both active and archived")
  .action(async (opts) => {
    const scope = opts.all ? "all" : opts.archive ? "archive" : "active";
    await listProjects(scope);
  });

program
  .command("archive")
  .description("Move a project from active to archive")
  .argument("<name>", "Project name or prefix (e.g. M-1 or 'M-1 Slides Redesign')")
  .action(async (name) => {
    await archiveProject(name);
  });

program
  .command("unarchive")
  .description("Move a project from archive back to active")
  .argument("<name>", "Project name or prefix")
  .action(async (name) => {
    await unarchiveProject(name);
  });

const configCmd = program
  .command("config")
  .description("Manage configuration");

configCmd
  .command("init")
  .description("Initialize config and create PARA structure")
  .action(initConfig);

configCmd
  .command("get")
  .description("Show config or a specific key")
  .argument("[key]", "Config key (activePath, archivePath, domains, subfolders)")
  .action(async (key) => {
    await getConfig(key);
  });

configCmd
  .command("set")
  .description("Set a config value")
  .argument("<key>", "Config key")
  .argument("<value>", "Config value (JSON for domains/subfolders)")
  .action(async (key, value) => {
    await setConfig(key, value);
  });

const notesCmd = program
  .command("notes")
  .description("Project notes operations");

notesCmd
  .command("current-day")
  .description("Print today's date in session format")
  .action(async () => {
    await notesCurrentDay();
  });

notesCmd
  .command("path")
  .description("Print path to project notes file")
  .argument("<project>", "Project name or prefix")
  .action(async (project) => {
    await notesPath(project);
  });

notesCmd
  .command("create")
  .description("Create notes file from template")
  .argument("<project>", "Project name or prefix")
  .action(async (project) => {
    await notesCreate(project);
  });

const sessionCmd = notesCmd.command("session").description("Session operations");
sessionCmd
  .command("add")
  .description("Prepend a new session to project notes")
  .argument("<project>", "Project name or prefix")
  .argument("[label]", "Session label (e.g. Sync, Discovery meeting)")
  .option("-d, --date <date>", "Date (YYYY-MM-DD)")
  .action(async (project, label, opts) => {
    await notesSessionAdd(project, label ?? "", opts.date);
  });

program.parse();
