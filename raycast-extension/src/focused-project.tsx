import path from "path";
import { readFile } from "fs/promises";
import { getPreferenceValues } from "@raycast/api";
import {
  Alert,
  Color,
  Icon,
  MenuBarExtra,
  open,
  confirmAlert,
  showHUD,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import {
  parseNotes,
  parseTodos,
  resolveNotesPath,
  toggleTodoInFile,
} from "project-manager/notes";
import type { Todo } from "project-manager/notes";
import {
  getFocusedProject,
  parseProjectKey,
  clearFocusedProject,
} from "./lib/focused-project";
import { recordRecentProject, projectKey } from "./lib/recent-projects";
import {
  saveUndoState,
  getUndoState,
  clearUndoState,
} from "./lib/undo-todo";
import {
  getTaskTiming,
  setTaskTiming,
  clearTaskTiming,
  taskKey as taskTimingKey,
} from "./lib/task-timing";
import { getObsidianUri, hasSrcDir, buildObsidianOptions, ensureTodaySession } from "./lib/utils";
import type { PreferenceValues } from "./lib/types";

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
      if (!notesPath) {
        await clearTaskTiming();
        return { projectPath, name, basePath, notesPath: null, todos: [], notes: null, iconColor: undefined };
      }
      const content = await readFile(notesPath, "utf-8");
      const notes = parseNotes(content);
      const todos = parseTodos(notes);
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
      return { projectPath, name, basePath, notesPath, todos, notes, iconColor };
    },
    [],
    { execute: true }
  );
  const { data: undoState, revalidate: revalidateUndo } = useCachedPromise(
    getUndoState,
    [],
    { execute: true }
  );

  const openTodos = data?.todos.filter((t) => !t.checked) ?? [];
  const nextTodo = openTodos[0] ?? null;
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
    if (!data?.notesPath) return;
    try {
      await saveUndoState(data.notesPath, todo);
      await toggleTodoInFile(data.notesPath, todo);
      await revalidate();
      await revalidateUndo();
      await showHUD(`Done: ${todo.text.slice(0, 40)}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showHUD(`Error: ${msg}`);
    }
  }

  async function handleUndo() {
    if (!undoState) return;
    try {
      await toggleTodoInFile(undoState.notesPath, undoState.todo);
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
          ? data.iconColor
            ? { source: Icon.ArrowRightCircleFilled, tintColor: data.iconColor }
            : Icon.ArrowRightCircleFilled
          : Icon.Ellipsis
      }
      title={title}
      tooltip={tooltip}
      isLoading={isLoading}
    >
      {data && (
        <>
          <MenuBarExtra.Section title={data.name}>
            {undoState && (
              <MenuBarExtra.Item
                icon={Icon.Undo}
                title="Undo"
                onAction={handleUndo}
              />
            )}
            {nextTodo ? (
              <>
                <MenuBarExtra.Item
                  icon={Icon.CheckCircle}
                  title="Mark Done"
                  onAction={() => handleMarkDone(nextTodo)}
                />
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
              </>
            ) : (
              <>
                <MenuBarExtra.Item icon={Icon.CheckCircle} title="All done" />
                <MenuBarExtra.Item icon={Icon.Circle} title="No tasks" />
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
              </>
            )}
            <MenuBarExtra.Item
              icon={Icon.Eye}
              title="View Project"
              onAction={() => open("raycast://extensions/stuarthanberg/project-manager/view-focused-project")}
            />
            <MenuBarExtra.Item
              icon={Icon.Plus}
              title="New Project"
              onAction={() => open("raycast://extensions/stuarthanberg/project-manager/new-project")}
            />
            {data.notesPath && (
              <>
                <MenuBarExtra.Item
                  icon={Icon.Plus}
                  title="Add task"
                  onAction={() => open("raycast://extensions/stuarthanberg/project-manager/add-focused-todo")}
                />
                {nextTodo && (
                  <MenuBarExtra.Item
                    icon={Icon.ArrowUp}
                    title="Add prior task"
                    onAction={() => open("raycast://extensions/stuarthanberg/project-manager/add-focused-prior-todo")}
                  />
                )}
              </>
            )}
          </MenuBarExtra.Section>
          {contextOrder.map((context) => (
            <MenuBarExtra.Section key={context} title={context}>
              {(byContext.get(context) ?? []).map((todo, i) => (
                <MenuBarExtra.Item
                  key={`${i}-${todo.rawLine}`}
                  icon={todo === nextTodo ? Icon.ArrowRightCircleFilled : Icon.Circle}
                  title={todo.text}
                  onAction={() => handleMarkDone(todo)}
                />
              ))}
            </MenuBarExtra.Section>
          ))}
          <MenuBarExtra.Section>
            <MenuBarExtra.Item
              icon={Icon.Folder}
              title="Open in Finder"
              onAction={async () => {
                await onOpenProject();
                open(data.projectPath);
              }}
            />
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
