import path from "path";
import fs from "fs";
import { useState } from "react";
import { Action, ActionPanel, Form, showToast, Toast } from "@raycast/api";
import { writeInitialConfig } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

function isDir(p: string): boolean {
  try {
    return fs.existsSync(p) && fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

type Props = {
  prefs: Pick<PreferenceValues, "configPath">;
  onComplete: () => void;
};

export default function FirstRunSetup({ prefs, onComplete }: Props) {
  const [activeError, setActiveError] = useState<string | undefined>();
  const [archiveError, setArchiveError] = useState<string | undefined>();

  async function handleSubmit(values: {
    useObsidian: string;
    activePath: string[];
    archivePath: string[];
    paraPath: string[];
    notesTemplatePath: string[];
    obsidianVault: string;
    obsidianVaultPath: string[];
  }) {
    const activePath = values.activePath?.[0]?.trim() ?? "";
    const archivePath = values.archivePath?.[0]?.trim() ?? "";
    const useObsidian = values.useObsidian === "yes";

    if (!activePath) {
      setActiveError("Select a folder for active projects.");
      return;
    }
    if (!archivePath) {
      setArchiveError("Select a folder for archive projects.");
      return;
    }
    if (!isDir(activePath)) {
      setActiveError("Selected path is not a directory.");
      return;
    }
    if (!isDir(archivePath)) {
      setArchiveError("Selected path is not a directory.");
      return;
    }
    if (path.normalize(activePath) === path.normalize(archivePath)) {
      setActiveError("Active and archive paths must be different.");
      setArchiveError("Active and archive paths must be different.");
      return;
    }

    setActiveError(undefined);
    setArchiveError(undefined);

    const paraPath = values.paraPath?.[0]?.trim();
    const notesTemplatePath = values.notesTemplatePath?.[0]?.trim();
    const obsidianVaultPath = values.obsidianVaultPath?.[0]?.trim();

    try {
      await writeInitialConfig(prefs, {
        activePath,
        archivePath,
        useObsidianCLI: useObsidian,
        paraPath: paraPath || undefined,
        notesTemplatePath: notesTemplatePath || undefined,
        obsidianVault: useObsidian ? values.obsidianVault.trim() || undefined : undefined,
        obsidianVaultPath: useObsidian ? obsidianVaultPath || undefined : undefined,
      });
      await showToast({
        style: Toast.Style.Success,
        title: "Configuration saved",
        message: "You can change paths later in Configure Project Manager.",
      });
      onComplete();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to save config",
        message: msg,
      });
    }
  }

  return (
    <Form
      navigationTitle="Set up Project Manager"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Configuration"
            onSubmit={(values: Parameters<typeof handleSubmit>[0]) =>
              handleSubmit(values)
            }
          />
        </ActionPanel>
      }
    >
      <Form.Dropdown
        id="useObsidian"
        title="Use with Obsidian"
        defaultValue="no"
        info="When enabled, project notes can be opened and edited through Obsidian’s CLI so they stay indexed. You can set vault and path in extension preferences later."
      >
        <Form.Dropdown.Item value="yes" title="Yes, use with Obsidian" />
        <Form.Dropdown.Item value="no" title="No, use without Obsidian" />
      </Form.Dropdown>
      <Form.FilePicker
        id="activePath"
        title="Active projects folder"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        error={activeError}
        info="Where active projects are stored. Required."
      />
      <Form.FilePicker
        id="archivePath"
        title="Archive projects folder"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        error={archiveError}
        info="Where archived projects are stored. Required."
      />
      <Form.FilePicker
        id="paraPath"
        title="Para path (optional)"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        info="If set, pm uses paraPath/active and paraPath/archive. Leave empty to use the paths above directly."
      />
      <Form.FilePicker
        id="notesTemplatePath"
        title="Notes template file (optional)"
        allowMultipleSelection={false}
        canChooseDirectories={false}
        canChooseFiles
        info="Custom notes template for new project notes. Leave empty for default."
      />
      <Form.Separator />
      <Form.TextField
        id="obsidianVault"
        title="Obsidian vault name (optional)"
        placeholder="My Vault"
        info="When using with Obsidian, set vault name and vault root below or later in extension preferences."
      />
      <Form.FilePicker
        id="obsidianVaultPath"
        title="Obsidian vault root (optional)"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
      />
    </Form>
  );
}
