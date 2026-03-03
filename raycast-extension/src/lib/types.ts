export interface PreferenceValues {
  configPath?: string;
  pmCliPath?: string;
  obsidianVault?: string;
  obsidianVaultRoot?: string;
  /** When true, extension syncs Obsidian prefs to pm config so pm uses Obsidian CLI for notes read/write. */
  useObsidianCLI?: boolean;
  menubarProjectDisplay?: "code" | "name";
}
