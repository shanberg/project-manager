import path from "path";
import {
  getObsidianUri,
  hasSrcDir,
  buildObsidianOptions,
  ensureTodaySession,
} from "./lib/utils";
import {
  getPreferenceValues,
  Icon,
  MenuBarExtra,
  open,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise, getProgressIcon } from "@raycast/utils";
import type { LinkEntry } from "./lib/notes-api";
import { getNotes, resolveNotesPath } from "./lib/notes-api";
import {
  getFocusedProject,
  parseProjectKey,
  getProjectCode,
  setFocusedProject,
} from "./lib/focused-project";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import { getRecentProjectsByEdit } from "./lib/recent-by-edit";
import type { PreferenceValues } from "./lib/types";

const TOOLTIP_MAX_LEN = 80;

function truncForTooltip(s: string): string {
  const t = s.trim();
  return t.length > TOOLTIP_MAX_LEN ? t.slice(0, TOOLTIP_MAX_LEN).trim() + "…" : t;
}

function formatStructuredTooltip(notes: {
  summary: string;
  problem: string;
  goals: string[];
  approach: string;
}): string {
  const parts: string[] = [];
  const summary = truncForTooltip(notes.summary);
  if (summary) parts.push(`Summary: ${summary}`);
  const problem = truncForTooltip(notes.problem);
  if (problem) parts.push(`Problem: ${problem}`);
  const goalItems = notes.goals
    .map((g) => truncForTooltip(g))
    .filter(Boolean)
    .map((g, i) => `${i + 1}. ${g}`)
    .join(" ");
  if (goalItems) parts.push(`Goals: ${goalItems.length > 150 ? goalItems.slice(0, 150).trim() + "…" : goalItems}`);
  const approach = truncForTooltip(notes.approach);
  if (approach) parts.push(`Approach: ${approach}`);
  return parts.join("\n\n");
}

function flattenLinks(links: LinkEntry[]): { label: string; url: string }[] {
  const result: { label: string; url: string }[] = [];
  for (const l of links) {
    if (l.url) {
      result.push({ label: l.label || l.url, url: l.url });
    }
    if (l.children) {
      for (const c of l.children) {
        if (c.url)
          result.push({
            label: l.label ? `${l.label}: ${c.url}` : c.url,
            url: c.url,
          });
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
      const notesPath = await resolveNotesPath(prefs, name);
      if (!notesPath)
        return {
          name,
          basePath,
          projectPath: path.join(basePath, name),
          notesPath: null,
          done: 0,
          total: 0,
          links: [],
          notes: null,
        };
      try {
        const out = await getNotes(prefs, name);
        const notes = out.notes;
        const total = out.todos.length;
        const done = out.todos.filter((t) => t.checked).length;
        const links = flattenLinks(notes.links.filter((l) => l.label || l.url));
        return {
          name,
          basePath,
          projectPath: path.join(basePath, name),
          notesPath,
          done,
          total,
          links,
          notes,
        };
      } catch {
        return {
          name,
          basePath,
          projectPath: path.join(basePath, name),
          notesPath: null,
          done: 0,
          total: 0,
          links: [],
          notes: null,
        };
      }
    },
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { execute: true }
  );

  const focusedKey = data ? projectKey(data.basePath, data.name) : null;
  const { data: recentProjects } = useCachedPromise(
    () => getRecentProjectsByEdit(prefs, 10, focusedKey ?? undefined),
    [prefs.activePath, prefs.archivePath, focusedKey],
    { execute: true },
  );

  if (!data && !isLoading) return null;

  const code = data ? getProjectCode(data.name) : "";
  const progress = data?.total ? data.done / data.total : 1;
  const baseTooltip = data
    ? data.total
      ? `${data.name}: ${data.done}/${data.total} done`
      : data.name
    : "No focused project";
  const structured =
    data?.notes
      ? formatStructuredTooltip(data.notes)
      : "";
  const tooltip = structured ? `${baseTooltip}\n\n${structured}` : baseTooltip;

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
          <MenuBarExtra.Section
            title={`Project · ${data.done}/${data.total} done`}
          >
            <MenuBarExtra.Item
              icon={Icon.Eye}
              title="View Project"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/view-focused-project",
                )
              }
            />
            {data.notesPath ? (
              <MenuBarExtra.Item
                icon={Icon.Document}
                title="Open in Obsidian"
                onAction={async () => {
                  await onOpenProject();
                  const session = await ensureTodaySession(
                    data.name,
                    data.notes ?? null,
                    prefs,
                  );
                  const opts = buildObsidianOptions(prefs, session);
                  open(getObsidianUri(data.notesPath!, opts));
                }}
                alternate={
                  <MenuBarExtra.Item
                    icon={Icon.Folder}
                    title="Open in Finder"
                    onAction={async () => {
                      await onOpenProject();
                      open(data.projectPath);
                    }}
                  />
                }
              />
            ) : (
              <MenuBarExtra.Item
                icon={Icon.Folder}
                title="Open in Finder"
                onAction={async () => {
                  await onOpenProject();
                  open(data.projectPath);
                }}
              />
            )}
            {hasSrcDir(data.projectPath) && (
              <MenuBarExtra.Item
                icon={Icon.Terminal}
                title="Open in Cursor"
                onAction={async () => {
                  await onOpenProject();
                  open(data.projectPath, "Cursor");
                }}
              />
            )}
          </MenuBarExtra.Section>
            {data.notesPath && (
            <MenuBarExtra.Section title="Links">
              {data.links.map((link, i) => (
                <MenuBarExtra.Item
                  key={`${i}-${link.url}`}
                  icon={Icon.Link}
                  title={
                    link.label.length > 50
                      ? link.label.slice(0, 47) + "…"
                      : link.label
                  }
                  tooltip={link.url}
                  onAction={async () => {
                    const url = link.url.trim();
                    try {
                      await open(url);
                    } catch (e) {
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Could not open link",
                        message: url,
                      });
                    }
                  }}
                />
              ))}
              <MenuBarExtra.Item
                icon={Icon.Plus}
                title="Add Link"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-link",
                  )
                }
              />
            </MenuBarExtra.Section>
          )}
          {recentProjects && recentProjects.length > 0 && (
            <MenuBarExtra.Section title="Recent">
              {recentProjects.map((p) => {
                const baseTip =
                  p.total ? `${p.name}: ${p.done}/${p.total} done` : p.name;
                const structured = p.notes
                  ? formatStructuredTooltip(p.notes)
                  : "";
                const tooltip = structured
                  ? `${baseTip}\n\n${structured}`
                  : baseTip;
                return (
                  <MenuBarExtra.Item
                    key={`${p.basePath}:${p.name}`}
                    icon={getProgressIcon(p.total ? p.done / p.total : 1)}
                    title={p.name}
                    tooltip={tooltip}
                    onAction={async () => {
                      await setFocusedProject(p.basePath, p.name);
                      await showHUD(`Focused: ${p.name}`);
                      revalidate();
                    }}
                  />
                );
              })}
            </MenuBarExtra.Section>
          )}
          <MenuBarExtra.Section>
            <MenuBarExtra.Item
              icon={Icon.Plus}
              title="New Project"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/new-project",
                )
              }
            />
            <MenuBarExtra.Item
              icon={Icon.List}
              title="List Projects"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/list-projects",
                )
              }
            />
            <MenuBarExtra.Item
              icon={Icon.Gear}
              title="Configure"
              onAction={() =>
                open("raycast://extensions/shanberg/project-manager/configure")
              }
            />
          </MenuBarExtra.Section>
        </>
      )}
    </MenuBarExtra>
  );
}
