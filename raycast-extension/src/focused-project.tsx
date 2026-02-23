import path from "path";
import { readFile } from "fs/promises";
import {
  Icon,
  MenuBarExtra,
  open,
  showToast,
  Toast,
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
import { getObsidianUri, hasSrcDir } from "./lib/utils";

export default function Command() {
  const { data, isLoading, revalidate } = useCachedPromise(
    async () => {
      const focusedKey = await getFocusedProject();
      if (!focusedKey) return null;
      const parsed = parseProjectKey(focusedKey);
      if (!parsed) return null;
      const { basePath, name } = parsed;
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(projectPath);
      if (!notesPath) return { projectPath, name, basePath, notesPath: null, todos: [] };
      const content = await readFile(notesPath, "utf-8");
      const notes = parseNotes(content);
      const todos = parseTodos(notes);
      return { projectPath, name, basePath, notesPath, todos };
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
      await showToast({ style: Toast.Style.Success, title: "Done", message: todo.text.slice(0, 40) });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  async function handleUndo() {
    if (!undoState) return;
    try {
      await toggleTodoInFile(undoState.notesPath, undoState.todo);
      await clearUndoState();
      await revalidate();
      await revalidateUndo();
      await showToast({ style: Toast.Style.Success, title: "Undone", message: undoState.todo.text.slice(0, 40) });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await showToast({ style: Toast.Style.Failure, title: "Error", message: msg });
    }
  }

  async function onOpenProject() {
    if (!data) return;
    await recordRecentProject(projectKey(data.basePath, data.name));
  }

  return (
    <MenuBarExtra
      icon={nextTodo ? Icon.ArrowRightCircleFilled : Icon.Ellipsis}
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
                    open(getObsidianUri(data.notesPath!));
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
                      open(getObsidianUri(data.notesPath!));
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
            {data.notesPath && (
              <MenuBarExtra.Item
                icon={Icon.Plus}
                title="Add task"
                onAction={() => open("raycast://extensions/stuarthanberg/project-manager/add-focused-todo")}
              />
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
                await clearFocusedProject();
                await showToast({ style: Toast.Style.Success, title: "Cleared" });
              }}
            />
          </MenuBarExtra.Section>
        </>
      )}
    </MenuBarExtra>
  );
}
