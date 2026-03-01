import { useState } from "react";
import path from "path";
import {
  Action,
  ActionPanel,
  Alert,
  confirmAlert,
  getPreferenceValues,
  Icon,
  List,
  open,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getNotes,
  resolveNotesPath,
  toggleAllTodosInNotes,
  toggleTodoInNotes,
  type LinkEntry,
  type Todo,
} from "./lib/notes-api";
import { runPmWithPrefs } from "./lib/pm";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import { setFocusedProject } from "./lib/focused-project";
import type { PreferenceValues } from "./lib/types";
import AddLinkForm from "./add-link-form";
import AddSessionNoteForm from "./add-session-note-form";
import AddTodoForm from "./add-todo-form";
import EditNotesSectionForm from "./edit-notes-section-form";
import EditGoalsForm from "./edit-goals-form";
import EditLearningsForm from "./edit-learnings-form";
import {
  getObsidianUri,
  hasSrcDir,
  buildObsidianOptions,
  ensureTodaySession,
  getNotesPath,
  FINDER_APP_PATH,
  OBSIDIAN_APP_PATH,
} from "./lib/utils";

function truncateSubtitle(s: string, max = 40): string {
  return s ? s.slice(0, max) + (s.length > max ? "…" : "") : "Empty";
}

function sectionDetail(content: string, emptyLabel: string) {
  const markdown = content.trim() ? content : `_${emptyLabel}_`;
  return <List.Item.Detail markdown={markdown} />;
}

async function fetchProjectNotes(
  projName: string,
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
  const notesPath = await resolveNotesPath(prefs, projName);
  if (!notesPath) return { notes: null, todos: [] as Todo[], notesPath: null };
  try {
    const out = await getNotes(prefs, projName);
    return { notes: out.notes, todos: out.todos, notesPath };
  } catch {
    return { notes: null, todos: [] as Todo[], notesPath };
  }
}

interface Props {
  projectName: string;
  basePath: string;
}

type TodoFilter = "all" | "open" | "done";
type TodoViewMode = "next" | "all";

export default function ProjectView({ projectName, basePath }: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { pop } = useNavigation();
  const isActive = basePath === prefs.activePath;
  const projectPath = path.join(basePath, projectName);
  const [viewMode, setViewMode] = useState<TodoViewMode>("next");
  const [todoFilter] = useState<TodoFilter>("all");

  const { data, isLoading, revalidate, mutate } = useCachedPromise(
    fetchProjectNotes,
    [
      projectName,
      prefs.activePath,
      prefs.archivePath,
      prefs.configPath,
      prefs.pmCliPath,
    ],
    { keepPreviousData: true },
  );

  const { notes, todos, notesPath } = data ?? {
    notes: null,
    todos: [],
    notesPath: null,
  };

  const sessionOrder: string[] = [];
  const seen = new Set<string>();
  for (const t of todos) {
    if (!seen.has(t.context)) {
      seen.add(t.context);
      sessionOrder.push(t.context);
    }
  }
  const bySession = new Map<string, Todo[]>();
  for (const t of todos) {
    const list = bySession.get(t.context) ?? [];
    list.push(t);
    bySession.set(t.context, list);
  }

  const uncheckedTodos = todos.filter((t) => !t.checked);
  const nextTodo =
    uncheckedTodos.find((t) => t.isFocused) ?? uncheckedTodos[0] ?? null;
  const nextTodoContext = nextTodo ? nextTodo.context : null;

  const filteredSessionOrder = sessionOrder.filter((context) => {
    const sessionTodos = bySession.get(context) ?? [];
    if (todoFilter === "open") return sessionTodos.some((t) => !t.checked);
    if (todoFilter === "done") return sessionTodos.some((t) => t.checked);
    return true;
  });

  function getSessionTodos(context: string): Todo[] {
    const sessionTodos = bySession.get(context) ?? [];
    if (todoFilter === "open") return sessionTodos.filter((t) => !t.checked);
    if (todoFilter === "done") return sessionTodos.filter((t) => t.checked);
    return sessionTodos;
  }

  function sessionTitle(context: string): string {
    const sessionTodos = bySession.get(context) ?? [];
    const open = sessionTodos.filter((t) => !t.checked).length;
    const done = sessionTodos.filter((t) => t.checked).length;
    const total = sessionTodos.length;
    if (total === 0) return context;
    if (done === 0) return `${context} (${open})`;
    if (open === 0) return `${context} (${done} done)`;
    return `${context} (${open}/${total})`;
  }

  async function handleToggle(todo: Todo) {
    if (!notesPath || !notes) return;
    try {
      await toggleTodoInNotes(prefs, projectName, notes, todo);
      await mutate();
      await showToast({
        style: Toast.Style.Success,
        title: todo.checked ? "Incomplete" : "Complete",
        message: todo.text.slice(0, 50) + (todo.text.length > 50 ? "…" : ""),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    }
  }

  async function handleMarkAllInSessionDone(context: string) {
    if (!notesPath || !notes) return;
    const sessionTodos = bySession.get(context) ?? [];
    const unchecked = sessionTodos.filter((t) => !t.checked);
    if (unchecked.length === 0) return;
    try {
      await toggleAllTodosInNotes(prefs, projectName, notes, unchecked);
      await mutate();
      await showToast({
        style: Toast.Style.Success,
        title: "Completed",
        message: `${unchecked.length} task${unchecked.length === 1 ? "" : "s"} in session`,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({
        style: Toast.Style.Failure,
        title: "Error",
        message: msg,
      });
    }
  }

  async function onOpenProject() {
    await recordRecentProject(projectKey(basePath, projectName));
  }

  const hasSrc = hasSrcDir(projectPath);
  const targetPath = notesPath ?? getNotesPath(projectPath);

  return (
    <List
      navigationTitle={projectName}
      isLoading={isLoading}
      searchBarPlaceholder="Search tasks…"
      searchBarAccessory={
        <List.Dropdown
          tooltip="View"
          value={viewMode}
          onChange={(v) => setViewMode(v as TodoViewMode)}
        >
          <List.Dropdown.Item
            value="next"
            title="Next up"
            icon={Icon.ArrowRightCircleFilled}
          />
          <List.Dropdown.Item value="all" title="All Tasks" icon={Icon.List} />
        </List.Dropdown>
      }
      actions={
        <ActionPanel>
          <Action
            title="Refresh"
            onAction={revalidate}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
          />
          <Action
            title="Configure"
            onAction={() =>
              open("raycast://extensions/shanberg/project-manager/configure")
            }
          />
          {notes && (
            <Action.Push
              title="Narrow Focus"
              icon={Icon.Plus}
              target={
                <AddTodoForm projectName={projectName} onSuccess={mutate} />
              }
            />
          )}
        </ActionPanel>
      }
    >
      {todos.length === 0 ? (
        <List.EmptyView
          title={notes ? "No Tasks" : "No Notes File"}
          description={
            notes
              ? "Add - [ ] task items in your session notes"
              : "Create a notes file in the project docs folder"
          }
          actions={
            <ActionPanel>
              <Action
                title="Create Notes File"
                icon={Icon.Document}
                onAction={async () => {
                  try {
                    await runPmWithPrefs(prefs, [
                      "notes",
                      "create",
                      projectName,
                    ]);
                    await showToast({
                      style: Toast.Style.Success,
                      title: "Notes Created",
                    });
                    await mutate();
                  } catch (err) {
                    const msg =
                      err instanceof Error ? err.message : String(err);
                    await showToast({
                      style: Toast.Style.Failure,
                      title: "Error",
                      message: msg,
                    });
                  }
                }}
              />
              <Action
                title="Open in Finder"
                icon={{ fileIcon: FINDER_APP_PATH }}
                onAction={async () => {
                  await onOpenProject();
                  open(projectPath);
                }}
              />
              <Action.Push
                title="Add Session Note"
                icon={Icon.ShortParagraph}
                target={<AddSessionNoteForm projectName={projectName} />}
              />
              {notes && (
                <Action.Push
                  title="Narrow Focus"
                  icon={Icon.Plus}
                  target={
                    <AddTodoForm projectName={projectName} onSuccess={mutate} />
                  }
                />
              )}
            </ActionPanel>
          }
        />
      ) : viewMode === "next" && nextTodo ? (
        <List.Section title="Next Up">
          <List.Item
            key={`${nextTodoContext}-${nextTodo.rawLine}`}
            icon={Icon.ArrowRightCircleFilled}
            title={nextTodo.text}
            subtitle={nextTodoContext ?? undefined}
            actions={
              <ActionPanel>
                <Action
                  title="Complete"
                  icon={Icon.CheckCircle}
                  onAction={() => handleToggle(nextTodo)}
                  shortcut={{ modifiers: ["cmd"], key: "t" }}
                />
                {nextTodoContext &&
                  (bySession.get(nextTodoContext) ?? []).some(
                    (t) => !t.checked,
                  ) && (
                    <Action
                      title="Complete All in Session"
                      icon={Icon.CheckCircle}
                      onAction={() =>
                        handleMarkAllInSessionDone(nextTodoContext)
                      }
                    />
                  )}
                <Action.CopyToClipboard
                  content={nextTodo.text}
                  title="Copy Task"
                  icon={Icon.Clipboard}
                />
              </ActionPanel>
            }
          />
        </List.Section>
      ) : viewMode === "next" && uncheckedTodos.length === 0 ? (
        <List.Section title="Next Up">
          <List.Item
            icon={Icon.CheckCircle}
            title="All Done"
            subtitle={`${todos.filter((t) => t.checked).length} completed`}
          />
        </List.Section>
      ) : (
        <>
          {filteredSessionOrder.map((context) => (
            <List.Section key={context} title={sessionTitle(context)}>
              {getSessionTodos(context).map((todo, i) => (
                <List.Item
                  key={`${context}-${i}-${todo.rawLine}`}
                  icon={
                    todo.checked
                      ? Icon.CheckCircle
                      : Icon.ArrowRightCircleFilled
                  }
                  title={todo.text}
                  accessoryTitle={todo.checked ? "done" : undefined}
                  actions={
                    <ActionPanel>
                      <Action
                        title={todo.checked ? "Incomplete" : "Complete"}
                        icon={todo.checked ? Icon.Circle : Icon.CheckCircle}
                        onAction={() => handleToggle(todo)}
                        shortcut={{ modifiers: ["cmd"], key: "t" }}
                      />
                      {(bySession.get(context) ?? []).some(
                        (t) => !t.checked,
                      ) && (
                        <Action
                          title="Complete All in Session"
                          icon={Icon.CheckCircle}
                          onAction={() => handleMarkAllInSessionDone(context)}
                        />
                      )}
                      <Action.CopyToClipboard
                        content={todo.text}
                        title="Copy Task"
                        icon={Icon.Clipboard}
                      />
                    </ActionPanel>
                  }
                />
              ))}
            </List.Section>
          ))}
        </>
      )}
      {notes && notesPath && (
        <List.Section title="Notes">
          <List.Item
            title="Edit Summary"
            icon={Icon.Document}
            subtitle={truncateSubtitle(notes.summary)}
            detail={sectionDetail(notes.summary, "No summary yet.")}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Summary"
                  target={
                    <EditNotesSectionForm
                      projectName={projectName}
                      notes={notes}
                      initialValue={notes.summary}
                      field="summary"
                      label="Summary"
                      submitTitle="Save Summary"
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Edit Problem"
            icon={Icon.QuestionMarkCircle}
            subtitle={truncateSubtitle(notes.problem)}
            detail={sectionDetail(notes.problem, "No problem statement yet.")}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Problem"
                  target={
                    <EditNotesSectionForm
                      projectName={projectName}
                      notes={notes}
                      initialValue={notes.problem}
                      field="problem"
                      label="Problem"
                      submitTitle="Save Problem"
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Edit Goals"
            icon={Icon.Flag}
            subtitle={truncateSubtitle(notes.goals.filter(Boolean).join(", "))}
            detail={sectionDetail(
              notes.goals
                .filter(Boolean)
                .map((g: string, i: number) => `${i + 1}. ${g}`)
                .join("\n"),
              "No goals yet.",
            )}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Goals"
                  target={
                    <EditGoalsForm
                      projectName={projectName}
                      notes={notes}
                      initialGoals={notes.goals}
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Edit Approach"
            icon={Icon.List}
            subtitle={truncateSubtitle(notes.approach)}
            detail={sectionDetail(notes.approach, "No approach yet.")}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Approach"
                  target={
                    <EditNotesSectionForm
                      projectName={projectName}
                      notes={notes}
                      initialValue={notes.approach}
                      field="approach"
                      label="Approach"
                      submitTitle="Save Approach"
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Add Link"
            icon={Icon.Link}
            subtitle={
              notes.links.filter((l: LinkEntry) => l.label || l.url).length +
              " links"
            }
            detail={sectionDetail(
              notes.links
                .filter((l: LinkEntry) => l.label || l.url)
                .map((l: LinkEntry) =>
                  l.label && l.url
                    ? `- [${l.label}](${l.url})`
                    : l.url
                      ? `- ${l.url}`
                      : "",
                )
                .filter(Boolean)
                .join("\n"),
              "No links yet.",
            )}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Add Link"
                  target={
                    <AddLinkForm
                      projectName={projectName}
                      notes={notes}
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Edit Learnings"
            icon={Icon.LightBulb}
            subtitle={truncateSubtitle(
              notes.learnings.filter(Boolean).join(", "),
            )}
            detail={sectionDetail(
              notes.learnings
                .filter(Boolean)
                .map((l: string) => `- ${l}`)
                .join("\n"),
              "No learnings yet.",
            )}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Learnings"
                  target={
                    <EditLearningsForm
                      projectName={projectName}
                      notes={notes}
                      initialLearnings={notes.learnings}
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
        </List.Section>
      )}
      <List.Section title="Actions">
        <List.Item
          title="Open in Finder"
          icon={{ fileIcon: FINDER_APP_PATH }}
          detail={sectionDetail(
            `Open the project folder in Finder.\n\n\`${projectPath}\``,
            "Project path unavailable",
          )}
          actions={
            <ActionPanel>
              <Action
                title="Open in Finder"
                icon={{ fileIcon: FINDER_APP_PATH }}
                onAction={async () => {
                  await onOpenProject();
                  open(projectPath);
                }}
              />
            </ActionPanel>
          }
        />
        {hasSrc && (
          <List.Item
            title="Open in Cursor"
            icon={Icon.Terminal}
            detail={sectionDetail(
              `Open the project in Cursor.\n\n\`${projectPath}\``,
              "Project path unavailable",
            )}
            actions={
              <ActionPanel>
                <Action
                  title="Open in Cursor"
                  icon={Icon.Terminal}
                  onAction={async () => {
                    await onOpenProject();
                    open(projectPath, "Cursor");
                  }}
                />
              </ActionPanel>
            }
          />
        )}
        <List.Item
          title="Open in Obsidian"
          icon={{ fileIcon: OBSIDIAN_APP_PATH }}
          detail={sectionDetail(
            `Open notes in Obsidian.\n\n\`${targetPath}\``,
            "Notes path unavailable",
          )}
          actions={
            <ActionPanel>
              <Action
                title="Open in Obsidian"
                icon={{ fileIcon: OBSIDIAN_APP_PATH }}
                onAction={async () => {
                  await onOpenProject();
                  const session = notes
                    ? await ensureTodaySession(projectName, notes, prefs)
                    : null;
                  const opts = buildObsidianOptions(prefs, session);
                  open(getObsidianUri(targetPath, opts));
                }}
              />
            </ActionPanel>
          }
        />
        {notes && (
          <List.Item
            title="Narrow Focus"
            icon={Icon.Plus}
            detail={sectionDetail(
              "Add a task to the current session in the project notes.",
              "",
            )}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Narrow Focus"
                  icon={Icon.Plus}
                  target={
                    <AddTodoForm projectName={projectName} onSuccess={mutate} />
                  }
                />
              </ActionPanel>
            }
          />
        )}
        <List.Item
          title="Add Session Note"
          icon={Icon.ShortParagraph}
          detail={sectionDetail(
            "Add a new session note to the project notes file.",
            "",
          )}
          actions={
            <ActionPanel>
              <Action.Push
                title="Add Session Note"
                icon={Icon.ShortParagraph}
                target={<AddSessionNoteForm projectName={projectName} />}
              />
            </ActionPanel>
          }
        />
        <List.Item
          title="Set as Focused Project"
          icon={Icon.ArrowRightCircleFilled}
          detail={sectionDetail(
            "Set this project as the focused project for quick access from the menu bar and View Focused Project.",
            "",
          )}
          actions={
            <ActionPanel>
              <Action
                title="Set as Focused Project"
                icon={Icon.ArrowRightCircleFilled}
                onAction={async () => {
                  await setFocusedProject(basePath, projectName);
                  await showToast({
                    style: Toast.Style.Success,
                    title: "Focused",
                    message: projectName,
                  });
                }}
              />
            </ActionPanel>
          }
        />
        {isActive ? (
          <List.Item
            title="Archive Project"
            icon={Icon.Trash}
            detail={sectionDetail(
              "Move this project from active to archive.",
              "",
            )}
            actions={
              <ActionPanel>
                <Action
                  title="Archive Project"
                  onAction={async () => {
                    const confirmed = await confirmAlert({
                      title: "Archive Project",
                      message: `Move "${projectName}" to archive?`,
                      primaryAction: {
                        title: "Archive",
                        style: Alert.ActionStyle.Destructive,
                      },
                    });
                    if (!confirmed) return;
                    try {
                      await runPmWithPrefs(prefs, ["archive", projectName]);
                      await showToast({
                        style: Toast.Style.Success,
                        title: "Archived",
                        message: projectName,
                      });
                      pop();
                    } catch (err) {
                      const msg =
                        err instanceof Error ? err.message : String(err);
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Error",
                        message: msg,
                      });
                    }
                  }}
                />
              </ActionPanel>
            }
          />
        ) : (
          <List.Item
            title="Unarchive Project"
            icon={Icon.ArrowUpCircle}
            detail={sectionDetail(
              "Move this project from archive back to active.",
              "",
            )}
            actions={
              <ActionPanel>
                <Action
                  title="Unarchive Project"
                  onAction={async () => {
                    const confirmed = await confirmAlert({
                      title: "Unarchive Project",
                      message: `Move "${projectName}" back to active?`,
                      primaryAction: { title: "Unarchive" },
                    });
                    if (!confirmed) return;
                    try {
                      await runPmWithPrefs(prefs, ["unarchive", projectName]);
                      await showToast({
                        style: Toast.Style.Success,
                        title: "Unarchived",
                        message: projectName,
                      });
                      pop();
                    } catch (err) {
                      const msg =
                        err instanceof Error ? err.message : String(err);
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Error",
                        message: msg,
                      });
                    }
                  }}
                />
              </ActionPanel>
            }
          />
        )}
        <List.Item
          title="Configure"
          icon={Icon.Gear}
          detail={sectionDetail("Open Project Manager configuration.", "")}
          actions={
            <ActionPanel>
              <Action
                title="Configure"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/configure",
                  )
                }
              />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
