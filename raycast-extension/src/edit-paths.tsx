import fs from "fs";
import { useState } from "react";
import {
  Action,
  ActionPanel,
  Form,
  getPreferenceValues,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getPmConfig, setPmConfigKey } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";

type FormValues = {
  activePath: string[];
  archivePath: string[];
  paraPath: string[];
};

function isDir(p: string): boolean {
  try {
    return fs.existsSync(p) && fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export default function EditPaths() {
  const [saving, setSaving] = useState(false);
  const [activeError, setActiveError] = useState<string | undefined>();
  const [archiveError, setArchiveError] = useState<string | undefined>();
  const prefs = getPreferenceValues<PreferenceValues>();
  const {
    data: config,
    isLoading,
    revalidate,
  } = useCachedPromise(getPmConfig, [prefs]);

  async function handleSubmit(values: FormValues) {
    const activePath = values.activePath?.[0]?.trim() ?? "";
    const archivePath = values.archivePath?.[0]?.trim() ?? "";
    const paraPath = values.paraPath?.[0]?.trim() ?? "";

    if (!activePath) {
      setActiveError("Select a folder for active projects.");
      return;
    }
    if (!archivePath) {
      setArchiveError("Select a folder for archive projects.");
      return;
    }
    if (!isDir(activePath)) {
      setActiveError("Selected active path is not a directory.");
      return;
    }
    if (!isDir(archivePath)) {
      setArchiveError("Selected archive path is not a directory.");
      return;
    }
    setActiveError(undefined);
    setArchiveError(undefined);

    setSaving(true);
    try {
      await setPmConfigKey(prefs, "activePath", activePath);
      await setPmConfigKey(prefs, "archivePath", archivePath);
      await setPmConfigKey(prefs, "paraPath", paraPath);
      await showToast({
        style: Toast.Style.Success,
        title: "Paths Updated",
      });
      revalidate();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to update paths",
        message: msg,
      });
    } finally {
      setSaving(false);
    }
  }

  if (isLoading || !config) {
    return <Form isLoading />;
  }

  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save Paths" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.FilePicker
        id="activePath"
        title="Active projects path"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        defaultValue={config.activePath ? [config.activePath] : []}
        error={activeError}
        info="Where active projects are stored. Required."
      />
      <Form.FilePicker
        id="archivePath"
        title="Archive projects path"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        defaultValue={config.archivePath ? [config.archivePath] : []}
        error={archiveError}
        info="Where archived projects are stored. Required."
      />
      <Form.FilePicker
        id="paraPath"
        title="Para path (optional)"
        allowMultipleSelection={false}
        canChooseDirectories
        canChooseFiles={false}
        defaultValue={config.paraPath ? [config.paraPath] : []}
        info="If set, pm uses paraPath/active and paraPath/archive. Leave empty to use active and archive paths directly."
      />
    </Form>
  );
}
