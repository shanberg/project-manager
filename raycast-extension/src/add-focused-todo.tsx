import { List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import AddTodoForm from "./add-todo-form";

export default function Command() {
  const { data: focusedKey, isLoading } = useCachedPromise(
    getFocusedProject,
    [],
  );
  const parsed = focusedKey ? parseProjectKey(focusedKey) : null;

  if (isLoading) return <List isLoading />;
  if (!parsed) {
    return (
      <List>
        <List.EmptyView
          title="No Focused Project"
          description="Set a project as focused from List Projects"
        />
      </List>
    );
  }

  return <AddTodoForm projectName={parsed.name} onSuccess={() => {}} />;
}
