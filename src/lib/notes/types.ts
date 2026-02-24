import type { LinkEntry, ProjectNotes, Session, Todo } from "@shanberg/project-schema";

export type { LinkEntry, ProjectNotes, Session, Todo };

export function createEmptyNotes(title: string): ProjectNotes {
  return {
    title,
    summary: "",
    problem: "",
    goals: ["", "", ""],
    approach: "",
    links: [{ label: undefined, url: undefined }],
    learnings: [""],
    sessions: [],
  };
}
