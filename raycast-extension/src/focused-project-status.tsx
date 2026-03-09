import path from "path";
import {
  getObsidianUri,
  hasSrcDir,
  buildObsidianOptions,
  ensureTodaySession,
} from "./lib/utils";
import {
  Color,
  getPreferenceValues,
  Icon,
  MenuBarExtra,
  open,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise, getProgressIcon, getFavicon } from "@raycast/utils";
import type { LinkEntry, Todo } from "./lib/notes-api";
import { getNotes, getNextDueForProject, resolveNotesPath } from "./lib/notes-api";
import { formatDueForMenubar, formatRelativeDue } from "./lib/format-relative-due";
import {
  getFocusedProject,
  parseProjectKey,
  getProjectCode,
  setFocusedProject,
} from "./lib/focused-project";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import {
  getRecentProjectsByEdit,
  type FocusedProjectData,
} from "./lib/recent-by-edit";
import type { PreferenceValues } from "./lib/types";

const TOOLTIP_MAX_LEN = 80;

function truncForTooltip(s: string): string {
  const t = s.trim();
  return t.length > TOOLTIP_MAX_LEN
    ? t.slice(0, TOOLTIP_MAX_LEN).trim() + "…"
    : t;
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
  if (goalItems)
    parts.push(
      `Goals: ${goalItems.length > 150 ? goalItems.slice(0, 150).trim() + "…" : goalItems}`,
    );
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

async function fetchFocusedProjectStatus(
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { configPath, pmCliPath };
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
      notesPath: null as null,
      done: 0,
      total: 0,
      todos: [] as Todo[],
      links: [] as { label: string; url: string }[],
      notes: null as null,
    };
  try {
    const out = await getNotes(prefs, name);
    const notes = out.notes;
    const todos = out.todos ?? [];
    const total = todos.length;
    const done = todos.filter((t) => t.checked).length;
    const links = flattenLinks(notes.links.filter((l) => l.label || l.url));
    return {
      name,
      basePath,
      projectPath: path.join(basePath, name),
      notesPath,
      done,
      total,
      todos,
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
      todos: [] as Todo[],
      links: [],
      notes: null,
    };
  }
}

function toFocusedProjectData(
  data: NonNullable<Awaited<ReturnType<typeof fetchFocusedProjectStatus>>>,
): FocusedProjectData {
  return {
    name: data.name,
    basePath: data.basePath,
    done: data.done,
    total: data.total,
    nextDue: data.todos ? getNextDueForProject(data.todos) : null,
    notes: data.notes,
  };
}

async function fetchRecentProjects(
  configPath: string | undefined,
  pmCliPath: string | undefined,
  focusedKey: string | null,
  focusedData: Awaited<ReturnType<typeof fetchFocusedProjectStatus>>,
) {
  const prefs = { configPath, pmCliPath };
  const focusedProjectData =
    focusedData != null ? toFocusedProjectData(focusedData) : undefined;
  return getRecentProjectsByEdit(
    prefs,
    10,
    focusedKey ?? undefined,
    focusedProjectData,
  );
}

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data, isLoading, revalidate } = useCachedPromise(
    fetchFocusedProjectStatus,
    [prefs.configPath, prefs.pmCliPath],
    { execute: true },
  );

  const focusedKey = data ? projectKey(data.basePath, data.name) : null;
  const { data: recentProjects } = useCachedPromise(
    fetchRecentProjects,
    [prefs.configPath, prefs.pmCliPath, focusedKey, data],
    { execute: true },
  );

  const menubarLabel =
    data && prefs.menubarProjectDisplay === "name"
      ? data.name
      : data
        ? getProjectCode(data.name)
        : "—";
  const nextDue = data?.todos ? getNextDueForProject(data.todos) : null;
  const nextDueShort = nextDue ? formatDueForMenubar(nextDue) : "";
  const titleWithDue =
    nextDueShort && data
      ? `${menubarLabel} · ${nextDueShort}`
      : menubarLabel;
  const progress = data?.total ? data.done / data.total : 1;
  const baseTooltip = data
    ? data.total
      ? `${data.name}: ${data.done}/${data.total} done`
      : data.name
    : "No Focused Project";
  const nextDueTooltip =
    nextDue && data
      ? `\nNext due: ${formatRelativeDue(nextDue)}`
      : "";
  const tooltipBase = nextDueTooltip ? `${baseTooltip}${nextDueTooltip}` : baseTooltip;
  const structured = data?.notes ? formatStructuredTooltip(data.notes) : "";
  const tooltip = structured ? `${tooltipBase}\n\n${structured}` : tooltipBase;

  async function onOpenProject() {
    if (!data) return;
    await recordRecentProject(projectKey(data.basePath, data.name));
  }

  return (
    <MenuBarExtra
      icon={getProgressIcon(progress, Color.PrimaryText, {
        backgroundOpacity: 0.25,
        background: Color.PrimaryText,
      })}
      title={titleWithDue}
      tooltip={tooltip}
      isLoading={isLoading}
    >
      {data ? (
        <>
          <MenuBarExtra.Section
            title={
              nextDue
                ? `Project · ${data.done}/${data.total} done · next ${formatRelativeDue(nextDue)}`
                : `Project · ${data.done}/${data.total} done`
            }
          >
            <MenuBarExtra.Item
              title="View Project"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/view-focused-project",
                )
              }
            />
            {data.notesPath ? (
              <MenuBarExtra.Item
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
            <MenuBarExtra.Section>
              {data.links.map((link, i) => (
                <MenuBarExtra.Item
                  key={`${i}-${link.url}`}
                  icon={getFavicon(link.url)}
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
                    } catch (err) {
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Could Not Open Link",
                        message: err instanceof Error ? err.message : String(err),
                      });
                    }
                  }}
                />
              ))}
              <MenuBarExtra.Item
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
                const baseTip = p.total
                  ? `${p.name}: ${p.done}/${p.total} done`
                  : p.name;
                const nextDueTip =
                  p.nextDue ? `\nNext due: ${formatRelativeDue(p.nextDue)}` : "";
                const tooltipBase = nextDueTip ? `${baseTip}${nextDueTip}` : baseTip;
                const structured = p.notes
                  ? formatStructuredTooltip(p.notes)
                  : "";
                const tooltip = structured
                  ? `${tooltipBase}\n\n${structured}`
                  : tooltipBase;
                const titleWithDue =
                  p.nextDue
                    ? `${p.name} · ${formatDueForMenubar(p.nextDue)}`
                    : p.name;
                return (
                  <MenuBarExtra.Item
                    key={`${p.basePath}:${p.name}`}
                    icon={getProgressIcon(
                      p.total ? p.done / p.total : 1,
                      Color.PrimaryText,
                      {
                        backgroundOpacity: 0.25,
                        background: Color.PrimaryText,
                      },
                    )}
                    title={titleWithDue}
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
              title="New Project"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/new-project",
                )
              }
            />
            <MenuBarExtra.Item
              title="List Projects"
              onAction={() =>
                open(
                  "raycast://extensions/shanberg/project-manager/list-projects",
                )
              }
            />
            <MenuBarExtra.Item
              title="Configure"
              onAction={() =>
                open("raycast://extensions/shanberg/project-manager/configure")
              }
            />
          </MenuBarExtra.Section>
        </>
      ) : (
        <MenuBarExtra.Section>
          <MenuBarExtra.Item
            title="List Projects"
            onAction={() =>
              open(
                "raycast://extensions/shanberg/project-manager/list-projects",
              )
            }
          />
          <MenuBarExtra.Item
            title="New Project"
            onAction={() =>
              open("raycast://extensions/shanberg/project-manager/new-project")
            }
          />
          <MenuBarExtra.Item
            title="Configure"
            onAction={() =>
              open("raycast://extensions/shanberg/project-manager/configure")
            }
          />
        </MenuBarExtra.Section>
      )}
    </MenuBarExtra>
  );
}
