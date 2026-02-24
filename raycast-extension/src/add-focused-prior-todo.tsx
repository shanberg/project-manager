import path from "path";
import { readFile } from "fs/promises";
import { List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import { parseNotes, parseTodos, resolveNotesPath } from "project-manager/notes";
import AddPriorTodoForm from "./add-prior-todo-form";

export default function Command() {
  const { data, isLoading } = useCachedPromise(
    async () => {
      const focusedKey = await getFocusedProject();
      if (!focusedKey) return null;
      const parsed = parseProjectKey(focusedKey);
      if (!parsed) return null;
      const { basePath, name } = parsed;
      const projectPath = path.join(basePath, name);
      const notesPath = await resolveNotesPath(projectPath);
      if (!notesPath) return null;
      const content = await readFile(notesPath, "utf-8");
      const notes = parseNotes(content);
      const todos = parseTodos(notes);
      const nextTodo = todos.filter((t) => !t.checked)[0] ?? null;
      return { notesPath, nextTodo };
    },
    [],
    { execute: true }
  );

  if (isLoading) return <List isLoading />;
  if (!data) {
    return (
      <List>
        <List.EmptyView
          title="No focused project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }
  if (!data.nextTodo) {
    return (
      <List>
        <List.EmptyView
          title="No active task"
          description="Add prior task requires an active task. Use Add Task first."
        />
      </List>
    );
  }

  return (
    <AddPriorTodoForm
      notesPath={data.notesPath}
      beforeTodo={data.nextTodo}
      onSuccess={() => {}}
    />
  );
}
