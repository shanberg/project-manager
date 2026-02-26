/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Active Projects Path - Folder where active projects live */
  "activePath": string,
  /** Archive Path - Folder where archived projects live */
  "archivePath": string,
  /** Config Path Override - Override pm config location (default: ~/.config/pm). Leave empty to use default. */
  "configPath"?: string,
  /** pm CLI Path - Full path to pm binary (e.g. ~/dev/project-manager/pm-swift/.build/release/pm). Leave empty to use pm from PATH. */
  "pmCliPath"?: string,
  /** Obsidian Vault (Advanced URI) - Vault name for cursor positioning. Requires Obsidian Advanced URI plugin. Leave empty to use path-only open. */
  "obsidianVault"?: string,
  /** Obsidian Vault Root (Advanced URI) - Absolute path to vault root (e.g. ~/Obsidian/Projects). Must contain activePath and archivePath. */
  "obsidianVaultRoot"?: string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `configure` command */
  export type Configure = ExtensionPreferences & {}
  /** Preferences accessible in the `edit-domains` command */
  export type EditDomains = ExtensionPreferences & {}
  /** Preferences accessible in the `edit-project-structure` command */
  export type EditProjectStructure = ExtensionPreferences & {}
  /** Preferences accessible in the `new-project` command */
  export type NewProject = ExtensionPreferences & {}
  /** Preferences accessible in the `list-projects` command */
  export type ListProjects = ExtensionPreferences & {}
  /** Preferences accessible in the `view-project` command */
  export type ViewProject = ExtensionPreferences & {}
  /** Preferences accessible in the `archive-project` command */
  export type ArchiveProject = ExtensionPreferences & {}
  /** Preferences accessible in the `unarchive-project` command */
  export type UnarchiveProject = ExtensionPreferences & {}
  /** Preferences accessible in the `focused-project` command */
  export type FocusedProject = ExtensionPreferences & {}
  /** Preferences accessible in the `focused-project-status` command */
  export type FocusedProjectStatus = ExtensionPreferences & {}
  /** Preferences accessible in the `view-focused-project` command */
  export type ViewFocusedProject = ExtensionPreferences & {}
  /** Preferences accessible in the `add-focused-todo` command */
  export type AddFocusedTodo = ExtensionPreferences & {}
  /** Preferences accessible in the `add-focused-prior-todo` command */
  export type AddFocusedPriorTodo = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `configure` command */
  export type Configure = {}
  /** Arguments passed to the `edit-domains` command */
  export type EditDomains = {}
  /** Arguments passed to the `edit-project-structure` command */
  export type EditProjectStructure = {}
  /** Arguments passed to the `new-project` command */
  export type NewProject = {}
  /** Arguments passed to the `list-projects` command */
  export type ListProjects = {}
  /** Arguments passed to the `view-project` command */
  export type ViewProject = {}
  /** Arguments passed to the `archive-project` command */
  export type ArchiveProject = {}
  /** Arguments passed to the `unarchive-project` command */
  export type UnarchiveProject = {}
  /** Arguments passed to the `focused-project` command */
  export type FocusedProject = {}
  /** Arguments passed to the `focused-project-status` command */
  export type FocusedProjectStatus = {}
  /** Arguments passed to the `view-focused-project` command */
  export type ViewFocusedProject = {}
  /** Arguments passed to the `add-focused-todo` command */
  export type AddFocusedTodo = {}
  /** Arguments passed to the `add-focused-prior-todo` command */
  export type AddFocusedPriorTodo = {}
}

