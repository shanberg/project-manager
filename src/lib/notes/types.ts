export interface LinkEntry {
  label?: string;
  url?: string;
  children?: LinkEntry[];
}

export interface Session {
  date: string;
  label: string;
  body: string;
}

export interface Todo {
  text: string;
  checked: boolean;
  rawLine: string;
  context: string;
}

export interface ProjectNotes {
  title: string;
  summary: string;
  problem: string;
  goals: string[];
  approach: string;
  links: LinkEntry[];
  learnings: string[];
  sessions: Session[];
}

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
