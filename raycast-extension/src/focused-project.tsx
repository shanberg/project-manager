import path from "path";
import { getPreferenceValues } from "@raycast/api";
import { Color, Icon, MenuBarExtra, open, showHUD } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getNotes,
  getEffectiveDue,
  resolveNotesPath,
  setFocusToTodoInNotes,
  toggleTodoInNotes,
  completeAndAdvanceInNotes,
  undoCompleteInNotes,
} from "./lib/notes-api";
import type { Todo } from "./lib/notes-api";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import { saveUndoState, getUndoState, clearUndoState } from "./lib/undo-todo";
import {
  getTaskTiming,
  setTaskTiming,
  clearTaskTiming,
  taskKey as taskTimingKey,
} from "./lib/task-timing";
import {
  getObsidianUri,
  buildObsidianOptions,
  ensureTodaySession,
} from "./lib/utils";
import { formatRelativeDue, formatDueForMenubar } from "./lib/format-relative-due";
import { refreshMenubar } from "./lib/menubar-refresh";
import type { PreferenceValues } from "./lib/types";

function breadcrumbForNowTask(todos: Todo[], nowTask: Todo): string {
  const sameContext = todos.filter((t) => t.context === nowTask.context);
  const path: Todo[] = [];
  for (const t of sameContext) {
    if (t.depth === path.length) {
      path.push(t);
      if (t === nowTask) break;
    }
  }
  return [nowTask.context, ...path.map((t) => t.text)].join(" » ");
}

async function fetchFocusedProjectData(
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
  if (!notesPath) {
    await clearTaskTiming();
    return {
      name,
      basePath,
      projectPath: path.join(basePath, name),
      notesPath: null as null,
      todos: [] as Todo[],
      notes: null as null,
      iconColor: undefined,
    };
  }
  try {
    const out = await getNotes(prefs, name);
    const notes = out.notes;
    const todos = out.todos;
    const openTodos = todos.filter((t) => !t.checked);
    const nextTodo = openTodos.find((t) => t.isFocused) ?? openTodos[0] ?? null;
    let iconColor: typeof Color.Yellow | typeof Color.Red | undefined;
    if (nextTodo) {
      const key = taskTimingKey(notesPath, nextTodo.rawLine);
      const stored = await getTaskTiming();
      const now = Date.now();
      if (stored?.taskKey === key) {
        const elapsedHours = (now - stored.seenAt) / (1000 * 60 * 60);
        if (elapsedHours >= 2) iconColor = Color.Red;
        else if (elapsedHours >= 1) iconColor = Color.Yellow;
      } else {
        await setTaskTiming(key);
      }
    } else {
      await clearTaskTiming();
    }
    return {
      name,
      basePath,
      projectPath: path.join(basePath, name),
      notesPath,
      todos,
      notes,
      iconColor,
    };
  } catch {
    await clearTaskTiming();
    return {
      name,
      basePath,
      projectPath: path.join(basePath, name),
      notesPath: null,
      todos: [],
      notes: null,
      iconColor: undefined,
    };
  }
}

type FocusedProjectData = Awaited<ReturnType<typeof fetchFocusedProjectData>>;

export default function Command() {
  const prefs = getPreferenceValues<PreferenceValues>();
  const { data, isLoading, revalidate } = useCachedPromise(
    fetchFocusedProjectData,
    [prefs.configPath, prefs.pmCliPath],
    { execute: true },
  ) as {
    data: FocusedProjectData | undefined;
    isLoading: boolean;
    revalidate: () => void;
  };
  const { data: undoState, revalidate: revalidateUndo } = useCachedPromise(
    getUndoState,
    [],
    { execute: true },
  );

  const openTodos = (data?.todos ?? []).filter((t) => !t.checked);
  const focusedTodo = openTodos.find((t) => t.isFocused) ?? null;
  const nextTodo = focusedTodo ?? openTodos[0] ?? null;
  const contextOrder: string[] = [];
  const byContext = new Map<string, Todo[]>();
  for (const t of openTodos) {
    if (!byContext.has(t.context)) {
      contextOrder.push(t.context);
    }
    const list = byContext.get(t.context) ?? [];
    list.push(t);
    byContext.set(t.context, list);
  }

  const effectiveDue =
    nextTodo != null
      ? (nextTodo.effectiveDueDate ??
        (data?.todos ? getEffectiveDue(data.todos, nextTodo) : null) ??
        nextTodo.dueDate) ??
      null
      : null;
  const dueMenubar = effectiveDue ? formatDueForMenubar(effectiveDue) : "";
  const title = nextTodo
    ? nextTodo.text.slice(0, 40) + (nextTodo.text.length > 40 ? "…" : "") + (dueMenubar ? ` • ${dueMenubar}` : "")
    : "No Tasks";
  const tooltip = data
    ? nextTodo
      ? `${data.name}: ${breadcrumbForNowTask(data.todos, nextTodo)}`
      : data.name
    : "No Focused Project";

  async function handleMarkDone(todo: Todo) {
    if (!data?.notesPath || !data?.notes) return;
    try {
      await saveUndoState(data.notesPath, data.name, todo);
      if (todo === nextTodo) {
        await completeAndAdvanceInNotes(
          prefs,
          data.name,
          data.notes,
          data.todos,
          todo,
        );
      } else {
        await toggleTodoInNotes(prefs, data.name, data.notes, todo);
      }
      await revalidate();
      await revalidateUndo();
      await showHUD(`Done: ${todo.text.slice(0, 40)}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showHUD(`Error: ${msg}`);
    }
  }

  async function handleFocusTask(todo: Todo) {
    if (!data?.notesPath || !data?.notes || todo.isFocused) return;
    try {
      const fresh = await getNotes(prefs, data.name);
      await setFocusToTodoInNotes(prefs, data.name, fresh.notes, todo);
      await revalidate();
      await refreshMenubar();
      await showHUD(`Focus: ${todo.text.slice(0, 40)}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showHUD(`Error: ${msg}`);
    }
  }

  async function handleUndo() {
    if (!undoState) return;
    try {
      const out = await getNotes(prefs, undoState.projectName);
      await undoCompleteInNotes(
        prefs,
        undoState.projectName,
        out.notes,
        undoState.todo,
      );
      await clearUndoState();
      await revalidate();
      await revalidateUndo();
      await showHUD(`Undone: ${undoState.todo.text.slice(0, 40)}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showHUD(`Error: ${msg}`);
    }
  }

  async function onOpenProject() {
    if (!data) return;
    await recordRecentProject(projectKey(data.basePath, data.name));
  }

  return (
    <MenuBarExtra
      icon={
        nextTodo
          ? data?.iconColor
            ? {
              source: Icon.ArrowRightCircleFilled,
              tintColor: data?.iconColor,
            }
            : Icon.ArrowRightCircleFilled
          : Icon.Ellipsis
      }
      title={title}
      tooltip={tooltip}
      isLoading={isLoading}
    >
      {data ? (
        <>
          <MenuBarExtra.Section>
            {nextTodo ? (
              <MenuBarExtra.Item
                icon={Icon.CheckCircle}
                title="Complete"
                onAction={() => handleMarkDone(nextTodo)}
                alternate={
                  undoState ? (
                    <MenuBarExtra.Item
                      icon={Icon.Undo}
                      title="Undo"
                      onAction={handleUndo}
                    />
                  ) : undefined
                }
              />
            ) : (
              <>
                <MenuBarExtra.Item icon={Icon.CheckCircle} title="All Done" />
                <MenuBarExtra.Item icon={Icon.Circle} title="No Tasks" />
              </>
            )}
            {data.notesPath && (
              <MenuBarExtra.Item
                icon={Icon.Plus}
                title="Narrow Focus"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-todo",
                  )
                }
              />
            )}
            {nextTodo && (
              <>
                <MenuBarExtra.Item
                  icon={Icon.ArrowDown}
                  title="Add After"
                  onAction={() =>
                    open(
                      "raycast://extensions/shanberg/project-manager/add-focused-after-todo",
                    )
                  }
                  alternate={
                    <MenuBarExtra.Item
                      icon={Icon.ArrowUp}
                      title="Add Before"
                      onAction={() =>
                        open(
                          "raycast://extensions/shanberg/project-manager/add-focused-prior-todo",
                        )
                      }
                    />
                  }
                />
                <MenuBarExtra.Item
                  icon={Icon.TextCursor}
                  title="Edit"
                  onAction={() =>
                    open(
                      "raycast://extensions/shanberg/project-manager/edit-focused-task",
                    )
                  }
                  alternate={
                    <MenuBarExtra.Item
                      icon={Icon.Layers}
                      title="Wrap"
                      onAction={() =>
                        open(
                          "raycast://extensions/shanberg/project-manager/wrap-focused-task",
                        )
                      }
                    />
                  }
                />
              </>
            )}
          </MenuBarExtra.Section>
          {data.notesPath && (
            <MenuBarExtra.Section>
              <MenuBarExtra.Item
                title="Add Session Note"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-session-note",
                  )
                }
              />
              <MenuBarExtra.Item
                title="Add Link"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-link",
                  )
                }
              />
              <MenuBarExtra.Item
                title="View Project"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/view-focused-project",
                  )
                }
              />
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
                    onAction={() => open(data.projectPath)}
                  />
                }
              />
            </MenuBarExtra.Section>
          )}
          {contextOrder.map((context) => (
            <MenuBarExtra.Section key={context} title={context}>
              {(byContext.get(context) ?? []).map((todo, i) => {
                const isFocused = todo === nextTodo;
                const indent = "  ".repeat(todo.depth ?? 0);
                const dueSuffix = (todo.effectiveDueDate ?? todo.dueDate)
                  ? ` (${formatRelativeDue(todo.effectiveDueDate ?? todo.dueDate ?? "")})`
                  : "";
                const displayTitle = indent + todo.text + dueSuffix;
                const alternateTitle =
                  indent +
                  (todo.text.length + dueSuffix.length > 35
                    ? todo.text.slice(0, 32) + "…" + dueSuffix
                    : todo.text + dueSuffix);
                return (
                  <MenuBarExtra.Item
                    key={`${todo.sessionIndex ?? 0}-${todo.lineIndex ?? 0}-${todo.text}`}
                    icon={isFocused ? Icon.ArrowRightCircleFilled : Icon.Circle}
                    title={displayTitle}
                    onAction={() =>
                      isFocused ? handleMarkDone(todo) : handleFocusTask(todo)
                    }
                    alternate={
                      !isFocused ? (
                        <MenuBarExtra.Item
                          icon={Icon.CheckCircle}
                          title={alternateTitle}
                          onAction={() => handleMarkDone(todo)}
                        />
                      ) : undefined
                    }
                  />
                );
              })}
            </MenuBarExtra.Section>
          ))}
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
