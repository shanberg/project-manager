import path from "path";
import { getPreferenceValues } from "@raycast/api";
import { Color, Icon, MenuBarExtra, open, showHUD } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  getNotes,
  resolveNotesPath,
  setFocusToTodoInNotes,
  toggleTodoInNotes,
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
import type { PreferenceValues } from "./lib/types";

async function fetchFocusedProjectData(
  activePath: string,
  archivePath: string,
  configPath: string | undefined,
  pmCliPath: string | undefined,
) {
  const prefs = { activePath, archivePath, configPath, pmCliPath };
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
    const nextTodo = openTodos[0] ?? null;
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
    [prefs.activePath, prefs.archivePath, prefs.configPath, prefs.pmCliPath],
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

  if (!data && !isLoading) return null;

  const title = nextTodo
    ? nextTodo.text.slice(0, 40) + (nextTodo.text.length > 40 ? "…" : "")
    : "No tasks";
  const tooltip = data
    ? nextTodo
      ? `${data.name}: ${nextTodo.text}`
      : data.name
    : "No focused project";

  async function handleMarkDone(todo: Todo) {
    if (!data?.notesPath || !data?.notes) return;
    try {
      await saveUndoState(data.notesPath, data.name, todo);
      await toggleTodoInNotes(prefs, data.name, data.notes, todo);
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
      await setFocusToTodoInNotes(prefs, data.name, data.notes, todo);
      await revalidate();
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
      await toggleTodoInNotes(
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
      {data && (
        <>
          <MenuBarExtra.Section>
            {nextTodo ? (
              <MenuBarExtra.Item
                icon={Icon.CheckCircle}
                title="Mark Done"
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
                <MenuBarExtra.Item icon={Icon.CheckCircle} title="All done" />
                <MenuBarExtra.Item icon={Icon.Circle} title="No tasks" />
              </>
            )}
            {data.notesPath && (
              <>
                <MenuBarExtra.Item
                  icon={Icon.Plus}
                  title="Add Task"
                  onAction={() =>
                    open(
                      "raycast://extensions/shanberg/project-manager/add-focused-todo",
                    )
                  }
                />
                {nextTodo && (
                  <MenuBarExtra.Item
                    icon={Icon.ArrowUp}
                    title="Add Prior Task"
                    onAction={() =>
                      open(
                        "raycast://extensions/shanberg/project-manager/add-focused-prior-todo",
                      )
                    }
                  />
                )}
              </>
            )}
          </MenuBarExtra.Section>
          {data.notesPath && (
            <MenuBarExtra.Section>
              <MenuBarExtra.Item
                icon={Icon.Plus}
                title="Add Session Note"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-session-note",
                  )
                }
              />
              <MenuBarExtra.Item
                icon={Icon.Link}
                title="Add Link"
                onAction={() =>
                  open(
                    "raycast://extensions/shanberg/project-manager/add-focused-link",
                  )
                }
              />
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
              />
            </MenuBarExtra.Section>
          )}
          {contextOrder.map((context) => (
            <MenuBarExtra.Section key={context} title={context}>
              {(byContext.get(context) ?? []).map((todo, i) => {
                const isFocused = todo === nextTodo;
                const completeTitle =
                  todo.text.length > 35
                    ? `Complete ${todo.text.slice(0, 32)}…`
                    : `Complete ${todo.text}`;
                return (
                  <MenuBarExtra.Item
                    key={`${i}-${todo.rawLine}`}
                    icon={isFocused ? Icon.ArrowRightCircleFilled : Icon.Circle}
                    title={todo.text}
                    onAction={() =>
                      isFocused ? handleMarkDone(todo) : handleFocusTask(todo)
                    }
                    alternate={
                      !isFocused ? (
                        <MenuBarExtra.Item
                          icon={Icon.CheckCircle}
                          title={completeTitle}
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
      )}
    </MenuBarExtra>
  );
}
