import { List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { getFocusedProject, parseProjectKey } from "./lib/focused-project";
import ProjectView from "./project-view";

export default function Command() {
  const { data: focusedKey, isLoading } = useCachedPromise(
    getFocusedProject,
    [],
  );

  const parsed = focusedKey ? parseProjectKey(focusedKey) : null;
  const projectName = parsed?.name ?? null;
  const basePath = parsed?.basePath ?? "";

  if (isLoading) return <List isLoading />;
  if (!projectName) {
    return (
      <List>
        <List.EmptyView
          title="No focused project"
          description="Set a project as focused from List Projects or View Project"
        />
      </List>
    );
  }

  return <ProjectView projectName={projectName} basePath={basePath} />;
}
