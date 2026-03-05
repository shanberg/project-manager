import path from "path";
import os from "os";
import { useState } from "react";
import { Action, ActionPanel, Form, showToast, Toast } from "@raycast/api";
import { writeInitialConfig } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

const PATH_DESCRIPTION =
  "Location to store project markdown files. Can be any level of hierarchy within this folder.";

function expandPath(p: string): string {
  const trimmed = p.trim();
  if (!trimmed) return "";
  return trimmed.startsWith("~")
    ? path.join(os.homedir(), trimmed.slice(1))
    : trimmed;
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
    activePath: string;
    archivePath: string;
  }) {
    const activePath = values.activePath.trim();
    const archivePath = values.archivePath.trim();

    if (!activePath) {
      setActiveError("Enter a path for active projects.");
      return;
    }
    if (!archivePath) {
      setArchiveError("Enter a path for archive projects.");
      return;
    }

    const activeExpanded = path.normalize(expandPath(activePath));
    const archiveExpanded = path.normalize(expandPath(archivePath));
    if (activeExpanded && archiveExpanded && activeExpanded === archiveExpanded) {
      setActiveError("Active and archive paths must be different.");
      setArchiveError("Active and archive paths must be different.");
      return;
    }

    setActiveError(undefined);
    setArchiveError(undefined);

    try {
      await writeInitialConfig(prefs, {
        activePath,
        archivePath,
        useObsidianCLI: values.useObsidian === "yes",
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
      <Form.TextField
        id="activePath"
        title="Active projects folder"
        placeholder="e.g. ~/projects/active or /path/to/active"
        error={activeError}
        info={PATH_DESCRIPTION}
      />
      <Form.TextField
        id="archivePath"
        title="Archive projects folder"
        placeholder="e.g. ~/projects/archive or /path/to/archive"
        error={archiveError}
        info={PATH_DESCRIPTION}
      />
    </Form>
  );
}
