import { useState, useEffect, useMemo } from "react";
import path from "path";
import { stat } from "fs/promises";
import {
  Action,
  ActionPanel,
  getPreferenceValues,
  List,
  open,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise, getProgressIcon } from "@raycast/utils";
import {
  getNotes,
  resolveNotesPath,
  formatNotesForDetail,
  formatNotesEmptyState,
} from "./lib/notes-api";
import type { ProjectNotes } from "./lib/notes-api";
import {
  recordRecentProject,
  getRecentProjectKeys,
  projectKey,
} from "./lib/recent-projects";
import { setFocusedProject, getProjectCode, getReadableProjectName } from "./lib/focused-project";
import { runPmWithPrefs, getConfigDomains } from "./lib/pm";
import type { PreferenceValues } from "./lib/types";
import AddSessionNoteForm from "./add-session-note-form";
import ProjectView from "./project-view";

import {
  parseListAllOutput,
  getObsidianUri,
  hasSrcDir,
  buildObsidianOptions,
  ensureTodaySession,
  getNotesPath,
} from "./lib/utils";

/** Match domain code at start of project name; use longer codes first so DE matches before D. */
function getDomainFromCodes(name: string, domainCodes: string[]): string | null {
  const sorted = [...domainCodes].sort((a, b) => b.length - a.length);
  const escaped = sorted.map((c) => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const re = new RegExp(`^(${escaped.join("|")})-\\d+`);
  const m = name.match(re);
  return m ? m[1] : null;
}

function parseSearchToken(
  search: string,
  domainCodes: string[]
): { domain: string | null; query: string } {
  const trimmed = search.trim();
  const upper = trimmed.toUpperCase();
  for (const code of domainCodes) {
    if (upper === code || upper.startsWith(`${code} `)) {
      return { domain: code, query: trimmed.slice(code.length).trim() };
    }
  }
  return { domain: null, query: trimmed };
}

async function loadNotesForProject(
  prefs: { activePath: string; archivePath: string; configPath?: string; pmCliPath?: string },
  projectName: string
): Promise<{ notes: ProjectNotes; notesPath: string } | null> {
  const notesPath = await resolveNotesPath(prefs, projectName);
  if (!notesPath) return null;
  try {
    const out = await getNotes(prefs, projectName);
    return { notes: out.notes, notesPath };
  } catch {
    return null;
  }
}

type ProjectWithMeta = {
  name: string;
  notes: ProjectNotes | null;
  notesPath: string | null;
  mtime: number;
  hasSrc: boolean;
  basePath: string;
  domain: string | null;
  done: number;
  total: number;
};

async function fetchProjectsWithMeta(
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined
): Promise<{ active: ProjectWithMeta[]; archive: ProjectWithMeta[] }> {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
  const [domains, { stdout }] = await Promise.all([
    getConfigDomains(prefs),
    runPmWithPrefs(prefs, ["list", "--all"]),
  ]);
  const domainCodes = Object.keys(domains);

  async function enrich(
    names: string[],
    basePath: string
  ): Promise<ProjectWithMeta[]> {
    const prefs = { activePath, archivePath, configPath, pmCliPath };
    const results = await Promise.all(
      names.map(async (name) => {
        const projectPath = path.join(basePath, name);
        const [loaded, stats] = await Promise.all([
          loadNotesForProject(prefs, name),
          stat(projectPath).catch(() => ({ mtime: 0 as number })),
        ]);
        const notes = loaded?.notes ?? null;
        const todos = loaded?.todos ?? [];
        const done = todos.filter((t: { checked: boolean }) => t.checked).length;
        const mtime = typeof stats.mtime === "number" ? stats.mtime : stats.mtime.getTime();
        return {
          name,
          notes,
          notesPath: loaded?.notesPath ?? null,
          mtime,
          hasSrc: hasSrcDir(path.join(basePath, name)),
          basePath,
          domain: getDomainFromCodes(name, domainCodes),
          done,
          total: todos.length,
        };
      })
    );
    return results;
  }

  const { active: activeNames, archive: archiveNames } = parseListAllOutput(stdout);
  const [active, archive] = await Promise.all([
    enrich(activeNames, activePath),
    enrich(archiveNames, archivePath),
  ]);

  return { active, archive };
}

function filterAndSort(
  projects: ProjectWithMeta[],
  domainFilter: string | null,
  query: string,
  recentKeys: string[]
): ProjectWithMeta[] {
  let filtered = projects;
  if (domainFilter) {
    filtered = filtered.filter((p) => p.domain === domainFilter);
  }
  if (query) {
    const q = query.toLowerCase();
    filtered = filtered.filter((p) => p.name.toLowerCase().includes(q));
  }
  const recentSet = new Set(recentKeys);
  return filtered.sort((a, b) => {
    const aRecent = recentSet.has(projectKey(a.basePath, a.name));
    const bRecent = recentSet.has(projectKey(b.basePath, b.name));
    if (aRecent && !bRecent) return -1;
    if (!aRecent && bRecent) return 1;
    if (aRecent && bRecent) {
      const aIdx = recentKeys.indexOf(projectKey(a.basePath, a.name));
      const bIdx = recentKeys.indexOf(projectKey(b.basePath, b.name));
      return aIdx - bIdx;
    }
    return b.mtime - a.mtime;
  });
}

export default function Command() {
  const [scope, setScope] = useState<"active" | "archive" | "all">("active");
  const [searchText, setSearchText] = useState("");
  const [recentKeys, setRecentKeys] = useState<string[]>([]);
  const prefs = getPreferenceValues<PreferenceValues>();

  const { data: domains = {} } = useCachedPromise(getConfigDomains, [prefs]);
  const domainCodes = Object.keys(domains);

  const { data, isLoading, revalidate } = useCachedPromise(
    fetchProjectsWithMeta,
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
    { keepPreviousData: true }
  );

  useEffect(() => {
    getRecentProjectKeys().then(setRecentKeys);
  }, []);

  const active = data?.active ?? [];
  const archive = data?.archive ?? [];
  const pathToShow = scope === "active" ? prefs.activePath : prefs.archivePath;

  const { domain: domainFilter, query } = parseSearchToken(searchText, domainCodes);

  const displayActive = useMemo(
    () => filterAndSort(active, domainFilter, query, recentKeys),
    [active, domainFilter, query, recentKeys]
  );
  const displayArchive = useMemo(
    () => filterAndSort(archive, domainFilter, query, recentKeys),
    [archive, domainFilter, query, recentKeys]
  );

  async function onOpenProject(basePath: string, name: string) {
    await recordRecentProject(projectKey(basePath, name));
    setRecentKeys(await getRecentProjectKeys());
  }

  function renderDetail(notes: ProjectNotes | null) {
    const markdown = notes ? formatNotesForDetail(notes) : formatNotesEmptyState();
    return <List.Item.Detail markdown={markdown} />;
  }

  function ProjectActions({
    name,
    basePath,
    hasSrc,
    hasNotes,
    notesPath,
    notes,
  }: {
    name: string;
    basePath: string;
    hasSrc: boolean;
    hasNotes: boolean;
    notesPath: string | null;
    notes: ProjectNotes | null;
  }) {
    const projectPath = path.join(basePath, name);
    const targetPath = notesPath ?? getNotesPath(projectPath);

    return (
      <ActionPanel>
        {!hasNotes ? (
          <Action
            title="Create Notes File"
            onAction={async () => {
              try {
                await runPmWithPrefs(prefs, ["notes", "create", name]);
                await showToast({ style: Toast.Style.Success, title: "Notes created" });
                revalidate();
              } catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
              }
            }}
          />
        ) : (
          <Action.Push
            title="View Project"
            target={<ProjectView projectName={name} basePath={basePath} />}
          />
        )}
        {hasSrc ? (
          <Action
            title="Open in Cursor"
            onAction={async () => {
              await onOpenProject(basePath, name);
              open(projectPath, "Cursor");
            }}
          />
        ) : (
          <Action
            title="Open in Obsidian"
            onAction={async () => {
              await onOpenProject(basePath, name);
              const session = await ensureTodaySession(name, notes, prefs);
              const opts = buildObsidianOptions(prefs, session);
              open(getObsidianUri(targetPath, opts));
            }}
          />
        )}
        {hasSrc && (
          <Action
            title="Open in Obsidian"
            onAction={async () => {
              await onOpenProject(basePath, name);
              const session = await ensureTodaySession(name, notes, prefs);
              const opts = buildObsidianOptions(prefs, session);
              open(getObsidianUri(targetPath, opts));
            }}
          />
        )}
        <Action
          title="Open in Finder"
          onAction={async () => {
            await onOpenProject(basePath, name);
            open(projectPath);
          }}
        />
        <Action
          title="Set as Focused Project"
          onAction={async () => {
            await setFocusedProject(basePath, name);
            await showToast({ style: Toast.Style.Success, title: "Focused", message: name });
          }}
        />
        <Action.Push
          title="Add Session Note"
          target={
            <AddSessionNoteForm projectName={name} />
          }
        />
      </ActionPanel>
    );
  }

  const searchPlaceholder = domainFilter
    ? `Filtered to ${domainFilter}. Type to search…`
    : domainCodes.length > 0
      ? `Search or type ${domainCodes.join(", ")} to filter by domain`
      : "Search projects…";

  return (
    <List
      isShowingDetail
      isLoading={isLoading}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder={searchPlaceholder}
      filtering={false}
      searchBarAccessory={
        <List.Dropdown
          tooltip="Scope"
          value={scope}
          onChange={(v) => setScope(v as typeof scope)}
        >
          <List.Dropdown.Item value="active" title="Active" />
          <List.Dropdown.Item value="archive" title="Archive" />
          <List.Dropdown.Item value="all" title="All" />
        </List.Dropdown>
      }
      actions={
        <ActionPanel>
          <Action title="Refresh" onAction={revalidate} shortcut={{ modifiers: ["cmd"], key: "r" }} />
        </ActionPanel>
      }
    >
      {scope === "all" ? (
        <>
          <List.Section title="Active">
            {displayActive.map(({ name, notes, notesPath, hasSrc, done, total }) => (
              <List.Item
                key={`active:${name}`}
                icon={getProgressIcon(total ? done / total : 1)}
                title={getReadableProjectName(name)}
                keywords={[getDomainFromCodes(name, domainCodes) ?? "", getProjectCode(name)]}
                detail={renderDetail(notes)}
                actions={
                  <ProjectActions name={name} basePath={prefs.activePath} hasSrc={hasSrc} hasNotes={!!notes} notesPath={notesPath} notes={notes} />
                }
              />
            ))}
          </List.Section>
          <List.Section title="Archive">
            {displayArchive.map(({ name, notes, notesPath, hasSrc, done, total }) => (
              <List.Item
                key={`archive:${name}`}
                icon={getProgressIcon(total ? done / total : 1)}
                title={getReadableProjectName(name)}
                keywords={[getDomainFromCodes(name, domainCodes) ?? "", getProjectCode(name)]}
                detail={renderDetail(notes)}
                actions={
                  <ProjectActions name={name} basePath={prefs.archivePath} hasSrc={hasSrc} hasNotes={!!notes} notesPath={notesPath} notes={notes} />
                }
              />
            ))}
          </List.Section>
        </>
      ) : (
        (scope === "active" ? displayActive : displayArchive).map(
          ({ name, notes, notesPath, hasSrc, done, total }) => (
            <List.Item
              key={name}
              icon={getProgressIcon(total ? done / total : 1)}
              title={getReadableProjectName(name)}
              keywords={[getDomainFromCodes(name, domainCodes) ?? "", getProjectCode(name)]}
              detail={renderDetail(notes)}
                actions={
                <ProjectActions
                  name={name}
                  basePath={pathToShow}
                  hasSrc={hasSrc}
                  hasNotes={!!notes}
                  notesPath={notesPath}
                  notes={notes}
                />
              }
            />
          )
        )
      )}
    </List>
  );
}
