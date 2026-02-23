import { useState } from "react";
import path from "path";
import { readFile } from "fs/promises";
import {
  Action,
  ActionPanel,
  getPreferenceValues,
  Icon,
  List,
  open,
  showToast,
  Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getNotesPath,
  parseNotes,
  parseTodos,
  resolveNotesPath,
  toggleAllTodosInFile,
  toggleTodoInFile,
} from "project-manager/notes";
import type { Todo } from "project-manager/notes";
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
import { getObsidianUri, hasSrcDir } from "./lib/utils";

function truncateSubtitle(s: string, max = 40): string {
  return s ? s.slice(0, max) + (s.length > max ? "…" : "") : "Empty";
}

interface Props {
  projectName: string;
  basePath: string;
}

type TodoFilter = "all" | "open" | "done";
type TodoViewMode = "next" | "all";

export default function ProjectView({ projectName, basePath }: Props) {
  const prefs = getPreferenceValues<PreferenceValues>();
  const projectPath = path.join(basePath, projectName);
  const [viewMode, setViewMode] = useState<TodoViewMode>("next");
  const [todoFilter, setTodoFilter] = useState<TodoFilter>("all");

  const { data, isLoading, revalidate, mutate } = useCachedPromise(
    async () => {
      const notesPath = await resolveNotesPath(projectPath);
      if (!notesPath) return { notes: null, todos: [], notesPath: null };
      const content = await readFile(notesPath, "utf-8");
      const notes = parseNotes(content);
      const todos = parseTodos(notes);
      return { notes, todos, notesPath };
    },
    [projectPath],
    { keepPreviousData: true }
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
  const nextTodo = uncheckedTodos[0] ?? null;
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
    if (!notesPath) return;
    try {
      await toggleTodoInFile(notesPath, todo);
      await mutate();
      await showToast({
        style: Toast.Style.Success,
        title: todo.checked ? "Unchecked" : "Done",
        message: todo.text.slice(0, 50) + (todo.text.length > 50 ? "…" : ""),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  async function handleMarkAllInSessionDone(context: string) {
    if (!notesPath) return;
    const sessionTodos = bySession.get(context) ?? [];
    const unchecked = sessionTodos.filter((t) => !t.checked);
    if (unchecked.length === 0) return;
    try {
      await toggleAllTodosInFile(notesPath, unchecked);
      await mutate();
      await showToast({
        style: Toast.Style.Success,
        title: "Marked done",
        message: `${unchecked.length} todo${unchecked.length === 1 ? "" : "s"} in session`,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  async function onOpenProject() {
    await recordRecentProject(projectKey(basePath, projectName));
  }

  const hasSrc = hasSrcDir(projectPath);
  const obsidianUri = notesPath ? getObsidianUri(notesPath) : getObsidianUri(getNotesPath(projectPath));

  return (
    <List
      navigationTitle={projectName}
      isLoading={isLoading}
      searchBarPlaceholder="Search todos…"
      searchBarAccessory={
        <List.Dropdown
          tooltip="View"
          value={viewMode}
          onChange={(v) => setViewMode(v as TodoViewMode)}
        >
          <List.Dropdown.Item value="next" title="Next up" icon={Icon.ArrowRightCircleFilled} />
          <List.Dropdown.Item value="all" title="All todos" icon={Icon.List} />
        </List.Dropdown>
      }
      actions={
        <ActionPanel>
          <Action title="Refresh" onAction={revalidate} shortcut={{ modifiers: ["cmd"], key: "r" }} />
          {notes && (
            <Action.Push
              title="Add Todo"
              target={
                <AddTodoForm
                  projectName={projectName}
                  basePath={basePath}
                  onSuccess={mutate}
                />
              }
            />
          )}
        </ActionPanel>
      }
    >
      {todos.length === 0 ? (
        <List.EmptyView
          title={notes ? "No todos" : "No notes file"}
          description={
            notes
              ? "Add - [ ] task items in your session notes"
              : "Create a notes file in the project docs folder"
          }
          actions={
            <ActionPanel>
              <Action
                title="Create Notes File"
                onAction={async () => {
                  try {
                    await runPmWithPrefs(prefs, ["notes", "create", projectName]);
                    await showToast({ style: Toast.Style.Success, title: "Notes created" });
                    await mutate();
                  } catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
                  }
                }}
              />
              <Action
                title="Open in Finder"
                onAction={async () => {
                  await onOpenProject();
                  open(projectPath);
                }}
              />
              <Action.Push
                title="Add Session Note"
                target={<AddSessionNoteForm projectName={projectName} />}
              />
              {notes && (
                <Action.Push
                  title="Add Todo"
                  target={
                    <AddTodoForm
                      projectName={projectName}
                      basePath={basePath}
                      onSuccess={mutate}
                    />
                  }
                />
              )}
            </ActionPanel>
          }
        />
      ) : viewMode === "next" && nextTodo ? (
        <List.Section title="Next up">
          <List.Item
            key={`${nextTodoContext}-${nextTodo.rawLine}`}
            icon={Icon.ArrowRightCircleFilled}
            title={nextTodo.text}
            subtitle={nextTodoContext ?? undefined}
            actions={
              <ActionPanel>
                <Action
                  title="Mark Done"
                  onAction={() => handleToggle(nextTodo)}
                  shortcut={{ modifiers: ["cmd"], key: "t" }}
                />
                {nextTodoContext && (bySession.get(nextTodoContext) ?? []).some((t) => !t.checked) && (
                  <Action
                    title="Mark All in Session Done"
                    onAction={() => handleMarkAllInSessionDone(nextTodoContext)}
                  />
                )}
                <Action.CopyToClipboard content={nextTodo.text} title="Copy Todo" />
              </ActionPanel>
            }
          />
        </List.Section>
      ) : viewMode === "next" && uncheckedTodos.length === 0 ? (
        <List.Section title="Next up">
          <List.Item
            icon={Icon.CheckCircle}
            title="All done"
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
                  icon={todo.checked ? Icon.CheckCircle : Icon.ArrowRightCircleFilled}
                  title={todo.text}
                  accessoryTitle={todo.checked ? "done" : undefined}
                  actions={
                    <ActionPanel>
                      <Action
                        title={todo.checked ? "Mark Undone" : "Mark Done"}
                        onAction={() => handleToggle(todo)}
                        shortcut={{ modifiers: ["cmd"], key: "t" }}
                      />
                      {(bySession.get(context) ?? []).some((t) => !t.checked) && (
                        <Action
                          title="Mark All in Session Done"
                          onAction={() => handleMarkAllInSessionDone(context)}
                        />
                      )}
                      <Action.CopyToClipboard content={todo.text} title="Copy Todo" />
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
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Summary"
                  target={
                    <EditNotesSectionForm
                      notesPath={notesPath}
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
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Problem"
                  target={
                    <EditNotesSectionForm
                      notesPath={notesPath}
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
            icon={Icon.Target}
            subtitle={truncateSubtitle(notes.goals.filter(Boolean).join(", "))}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Goals"
                  target={
                    <EditGoalsForm
                      notesPath={notesPath}
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
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Approach"
                  target={
                    <EditNotesSectionForm
                      notesPath={notesPath}
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
            subtitle={notes.links.filter((l) => l.label || l.url).length + " links"}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Add Link"
                  target={
                    <AddLinkForm notesPath={notesPath} onSuccess={mutate} />
                  }
                />
              </ActionPanel>
            }
          />
          <List.Item
            title="Edit Learnings"
            icon={Icon.LightBulb}
            subtitle={truncateSubtitle(notes.learnings.filter(Boolean).join(", "))}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Learnings"
                  target={
                    <EditLearningsForm
                      notesPath={notesPath}
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
          icon="folder"
          actions={
            <ActionPanel>
              <Action
                title="Open in Finder"
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
            icon="terminal"
            actions={
              <ActionPanel>
                <Action
                  title="Open in Cursor"
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
          icon="document"
          actions={
            <ActionPanel>
              <Action
                title="Open in Obsidian"
                onAction={async () => {
                  await onOpenProject();
                  open(obsidianUri);
                }}
              />
            </ActionPanel>
          }
        />
        <List.Item
          title="Set as Focused Project"
          icon={Icon.Star}
          actions={
            <ActionPanel>
              <Action
                title="Set as Focused Project"
                onAction={async () => {
                  await setFocusedProject(basePath, projectName);
                  await showToast({ style: Toast.Style.Success, title: "Focused", message: projectName });
                }}
              />
            </ActionPanel>
          }
        />
        <List.Item
          title="Add Session Note"
          icon="plus"
          actions={
            <ActionPanel>
              <Action.Push
                title="Add Session Note"
                target={<AddSessionNoteForm projectName={projectName} />}
              />
            </ActionPanel>
          }
        />
        {notes && (
          <List.Item
            title="Add Todo"
            icon={Icon.ArrowRightCircleFilled}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Add Todo"
                  target={
                    <AddTodoForm
                      projectName={projectName}
                      basePath={basePath}
                      onSuccess={mutate}
                    />
                  }
                />
              </ActionPanel>
            }
          />
        )}
      </List.Section>
    </List>
  );
}
