import path from "path";
import { readFile } from "fs/promises";
import { getObsidianUri, buildObsidianOptions, ensureTodaySession } from "./lib/utils";
import {
  Alert,
  confirmAlert,
  getPreferenceValues,
  Icon,
  MenuBarExtra,
  open,
  showHUD,
} from "@raycast/api";
import { useCachedPromise, getProgressIcon } from "@raycast/utils";
import type { LinkEntry } from "@shanberg/project-manager/notes";
import { parseNotes, parseTodos, resolveNotesPath } from "@shanberg/project-manager/notes";
import {
  getFocusedProject,
  parseProjectKey,
  getProjectCode,
  setFocusedProject,
  clearFocusedProject,
} from "./lib/focused-project";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import { getRecentProjectsByEdit } from "./lib/recent-by-edit";
import type { PreferenceValues } from "./lib/types";

function flattenLinks(links: LinkEntry[]): { label: string; url: string }[] {
  const result: { label: string; url: string }[] = [];
  for (const l of links) {
    if (l.url) {
      result.push({ label: l.label || l.url, url: l.url });
    }
    if (l.children) {
      for (const c of l.children) {
        if (c.url) result.push({ label: l.label ? `${l.label}: ${c.url}` : c.url, url: c.url });
      }
    }
  }
  return result;
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data, isLoading, revalidate } = useCachedPromise(
    async () => {
      const focusedKey = await getFocusedProject();
      if (!focusedKey) return null;
      const parsed = parseProjectKey(focusedKey);
      if (!parsed) return null;
      const { basePath, name } = parsed;
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(projectPath);
      if (!notesPath) return { projectPath, name, basePath, notesPath: null, done: 0, total: 0, links: [], notes: null };
      const content = await readFile(notesPath, "utf-8");
      const notes = parseNotes(content);
      const todos = parseTodos(notes);
      const total = todos.length;
      const done = todos.filter((t) => t.checked).length;
      const links = flattenLinks(notes.links.filter((l) => l.label || l.url));
      return { projectPath, name, basePath, notesPath, done, total, links, notes };
    },
    [],
    { execute: true }
  );

  const focusedKey = data ? projectKey(data.basePath, data.name) : null;
  const { data: recentProjects } = useCachedPromise(
    () => getRecentProjectsByEdit(prefs, 10, focusedKey ?? undefined),
    [prefs.activePath, prefs.archivePath, focusedKey],
    { execute: true }
  );

  if (!data && !isLoading) return null;

  const code = data ? getProjectCode(data.name) : "";
  const progress = data?.total ? data.done / data.total : 1;
  const tooltip = data
    ? data.total
      ? `${data.name}: ${data.done}/${data.total} done`
      : data.name
    : "No focused project";

  async function onOpenProject() {
    if (!data) return;
    await recordRecentProject(projectKey(data.basePath, data.name));
  }

  return (
    <MenuBarExtra
      icon={getProgressIcon(progress)}
      title={code}
      tooltip={tooltip}
      isLoading={isLoading}
    >
      {data && (
        <>
          <MenuBarExtra.Section title="Project">
            <MenuBarExtra.Item icon={getProgressIcon(progress)} title={data.name} />
            <MenuBarExtra.Item title={`${data.done}/${data.total} done`} />
            {data.notesPath && (
              <MenuBarExtra.Item
                icon={Icon.Document}
                title="Open in Obsidian"
                onAction={async () => {
                  await onOpenProject();
                  const session = await ensureTodaySession(data.name, data.notes ?? null, prefs);
                  const opts = buildObsidianOptions(prefs, session);
                  open(getObsidianUri(data.notesPath!, opts));
                }}
              />
            )}
            <MenuBarExtra.Item
              icon={Icon.Eye}
              title="View Project"
              onAction={() => open("raycast://extensions/shanberg/project-manager/view-focused-project")}
            />
            <MenuBarExtra.Item
              icon={Icon.Plus}
              title="New Project"
              onAction={() => open("raycast://extensions/shanberg/project-manager/new-project")}
            />
            {data.links.length > 0 &&
              data.links.map((link, i) => (
                <MenuBarExtra.Item
                  key={`${i}-${link.url}`}
                  icon={Icon.Link}
                  title={link.label.length > 50 ? link.label.slice(0, 47) + "…" : link.label}
                  tooltip={link.url}
                  onAction={() => open(link.url)}
                />
              ))}
          </MenuBarExtra.Section>
          {recentProjects && recentProjects.length > 0 && (
            <MenuBarExtra.Section title="Recent">
              {recentProjects.map((p) => (
                <MenuBarExtra.Item
                  key={`${p.basePath}:${p.name}`}
                  icon={getProgressIcon(p.total ? p.done / p.total : 1)}
                  title={p.name}
                  onAction={async () => {
                    await setFocusedProject(p.basePath, p.name);
                    await showHUD(`Focused: ${p.name}`);
                    revalidate();
                  }}
                />
              ))}
            </MenuBarExtra.Section>
          )}
          <MenuBarExtra.Section>
            <MenuBarExtra.Item
              icon={Icon.Folder}
              title="Open in Finder"
              onAction={async () => {
                await onOpenProject();
                open(data.projectPath);
              }}
            />
          </MenuBarExtra.Section>
          <MenuBarExtra.Section>
            <MenuBarExtra.Item
              icon={Icon.Star}
              title="Clear Focused Project"
              onAction={async () => {
                const confirmed = await confirmAlert({
                  title: "Clear Focused Project",
                  message: "Remove focus from the current project?",
                  primaryAction: { title: "Clear" },
                });
                if (!confirmed) return;
                await clearFocusedProject();
                await showHUD("Cleared");
              }}
            />
          </MenuBarExtra.Section>
        </>
      )}
    </MenuBarExtra>
  );
}
