import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  addTodoAfterInNotes,
  addTodoBeforeInNotes,
  addTodoAsChildInNotes,
  type ProjectNotes,
  type Session,
  type Todo,
} from "../notes-api";
import type { PreferenceValues } from "../types";
import { runPmWithStdin } from "../pm";

vi.mock("../pm", () => ({
  buildEnv: vi.fn(() => ({})),
  runPmWithPrefs: vi.fn(),
  runPmWithStdin: vi.fn().mockResolvedValue({ code: 0, stderr: "" }),
  syncObsidianPrefsToPmConfig: vi.fn().mockResolvedValue(undefined),
}));

beforeEach(() => {
  vi.mocked(runPmWithStdin).mockResolvedValue({ code: 0, stderr: "" });
});

const prefs: PreferenceValues = { configPath: "/tmp/config", pmCliPath: "pm" };

function makeNotes(body: string): ProjectNotes {
  const session: Session = {
    date: "2025-03-03",
    label: "Mon, Mar 3, 2025",
    body,
  };
  return {
    title: "Test",
    summary: "",
    problem: "",
    goals: [],
    approach: "",
    links: [],
    learnings: [],
    sessions: [session],
  };
}

describe("addTodoAfterInNotes", () => {
  it("inserts a new task after the given todo and returns updated notes and insertedTodo", async () => {
    const body = "- [ ] First\n- [ ] Second\n- [ ] Third";
    const notes = makeNotes(body);
    const afterTodo: Todo = {
      rawLine: "- [ ] Second",
      text: "Second",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 1,
    };

    const result = await addTodoAfterInNotes(
      prefs,
      "my-project",
      notes,
      afterTodo,
      "New task",
    );

    expect(result.notes.sessions[0].body).toBe(
      "- [ ] First\n- [ ] Second\n- [ ] New task\n- [ ] Third",
    );
    expect(result.insertedTodo.rawLine).toBe("- [ ] New task");
    expect(result.insertedTodo.sessionIndex).toBe(0);
    expect(result.insertedTodo.lineIndex).toBe(2);
    expect(result.insertedTodo.text).toBe("New task");
  });

  it("chaining: second add uses returned notes so first task is preserved", async () => {
    const body = "- [ ] Anchor";
    const notes = makeNotes(body);
    const anchor: Todo = {
      rawLine: "- [ ] Anchor",
      text: "Anchor",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    const first = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "First added",
    );
    expect(first.notes.sessions[0].body).toBe(
      "- [ ] Anchor\n- [ ] First added",
    );

    const second = await addTodoAfterInNotes(
      prefs,
      "p",
      first.notes,
      first.insertedTodo,
      "Second added",
    );
    expect(second.notes.sessions[0].body).toBe(
      "- [ ] Anchor\n- [ ] First added\n- [ ] Second added",
    );
  });

  it("preserves list prefix/indent from anchor", async () => {
    const body = "  - [ ] Indented";
    const notes = makeNotes(body);
    const afterTodo: Todo = {
      rawLine: "  - [ ] Indented",
      text: "Indented",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    const result = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      afterTodo,
      "Child",
    );
    expect(result.notes.sessions[0].body).toBe(
      "  - [ ] Indented\n  - [ ] Child",
    );
  });

  it("works with rawLine-only todo (no sessionIndex/lineIndex)", async () => {
    const body = "- [ ] Only";
    const notes = makeNotes(body);
    const afterTodo: Todo = {
      rawLine: "- [ ] Only",
      text: "Only",
      checked: false,
      context: "",
    };

    const result = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      afterTodo,
      "After only",
    );
    expect(result.notes.sessions[0].body).toBe(
      "- [ ] Only\n- [ ] After only",
    );
    expect(result.insertedTodo.rawLine).toBe("- [ ] After only");
  });

  it("adds tasks in sequence at same hierarchy level as focused task", async () => {
    const body = "- [ ] Root\n  - [ ] Focused child";
    const notes = makeNotes(body);
    const focused: Todo = {
      rawLine: "  - [ ] Focused child",
      text: "Focused child",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 1,
    };

    const first = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      focused,
      "First",
    );
    expect(first.notes.sessions[0].body).toBe(
      "- [ ] Root\n  - [ ] Focused child\n  - [ ] First",
    );

    const second = await addTodoAfterInNotes(
      prefs,
      "p",
      first.notes,
      first.insertedTodo,
      "Second",
    );
    expect(second.notes.sessions[0].body).toBe(
      "- [ ] Root\n  - [ ] Focused child\n  - [ ] First\n  - [ ] Second",
    );

    const third = await addTodoAfterInNotes(
      prefs,
      "p",
      second.notes,
      second.insertedTodo,
      "Third",
    );
    expect(third.notes.sessions[0].body).toBe(
      "- [ ] Root\n  - [ ] Focused child\n  - [ ] First\n  - [ ] Second\n  - [ ] Third",
    );
    expect(third.notes.sessions[0].body).toContain("  - [ ] First");
    expect(third.notes.sessions[0].body).toContain("  - [ ] Second");
    expect(third.notes.sessions[0].body).toContain("  - [ ] Third");
  });
});

describe("addTodoBeforeInNotes", () => {
  it("inserts a new task before the given todo and returns updated notes and nextBeforeTodo", async () => {
    const body = "- [ ] First\n- [ ] Second\n- [ ] Third";
    const notes = makeNotes(body);
    const beforeTodo: Todo = {
      rawLine: "- [ ] Second",
      text: "Second",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 1,
    };

    const result = await addTodoBeforeInNotes(
      prefs,
      "my-project",
      notes,
      beforeTodo,
      "New task",
    );

    expect(result.notes.sessions[0].body).toBe(
      "- [ ] First\n- [ ] New task\n- [ ] Second\n- [ ] Third",
    );
    expect(result.nextBeforeTodo.rawLine).toBe("- [ ] Second");
    expect(result.nextBeforeTodo.sessionIndex).toBe(0);
    expect(result.nextBeforeTodo.lineIndex).toBe(2);
  });

  it("chaining: second add uses returned notes so first task is preserved", async () => {
    const body = "- [ ] Anchor";
    const notes = makeNotes(body);
    const anchor: Todo = {
      rawLine: "- [ ] Anchor",
      text: "Anchor",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    const first = await addTodoBeforeInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "First added",
    );
    expect(first.notes.sessions[0].body).toBe(
      "- [ ] First added\n- [ ] Anchor",
    );

    const second = await addTodoBeforeInNotes(
      prefs,
      "p",
      first.notes,
      first.nextBeforeTodo,
      "Second added",
    );
    expect(second.notes.sessions[0].body).toBe(
      "- [ ] First added\n- [ ] Second added\n- [ ] Anchor",
    );
  });

  it("adds tasks in sequence (1, then 2, then 3) before the anchor", async () => {
    const body = "- [ ] Anchor";
    const notes = makeNotes(body);
    const anchor: Todo = {
      rawLine: "- [ ] Anchor",
      text: "Anchor",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    const first = await addTodoBeforeInNotes(prefs, "p", notes, anchor, "1");
    expect(first.notes.sessions[0].body).toBe("- [ ] 1\n- [ ] Anchor");

    const second = await addTodoBeforeInNotes(
      prefs,
      "p",
      first.notes,
      first.nextBeforeTodo,
      "2",
    );
    expect(second.notes.sessions[0].body).toBe(
      "- [ ] 1\n- [ ] 2\n- [ ] Anchor",
    );

    const third = await addTodoBeforeInNotes(
      prefs,
      "p",
      second.notes,
      second.nextBeforeTodo,
      "3",
    );
    expect(third.notes.sessions[0].body).toBe(
      "- [ ] 1\n- [ ] 2\n- [ ] 3\n- [ ] Anchor",
    );
  });
});

describe("addTodoAsChildInNotes", () => {
  beforeEach(() => {
    vi.mocked(runPmWithStdin).mockClear();
  });

  it("inserts child under parent and sets focus marker on new child", async () => {
    const body = "- [ ] Parent";
    const notes = makeNotes(body);
    const parentTodo: Todo = {
      rawLine: "- [ ] Parent",
      text: "Parent",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    await addTodoAsChildInNotes(
      prefs,
      "p",
      notes,
      parentTodo,
      "Child task",
    );

    const lastCall = vi.mocked(runPmWithStdin).mock.calls.at(-1);
    expect(lastCall).toBeDefined();
    const written = JSON.parse(lastCall![3] as string) as ProjectNotes;
    expect(written.sessions[0].body).toBe(
      "- [ ] Parent\n  - [ ] Child task @",
    );
  });

  it("strips focus from parent when adding child", async () => {
    const body = "- [ ] Parent @\n  - [ ] Sibling";
    const notes = makeNotes(body);
    const parentTodo: Todo = {
      rawLine: "- [ ] Parent @",
      text: "Parent",
      checked: false,
      context: "",
      sessionIndex: 0,
      lineIndex: 0,
    };

    await addTodoAsChildInNotes(
      prefs,
      "p",
      notes,
      parentTodo,
      "New child",
    );

    const lastCall = vi.mocked(runPmWithStdin).mock.calls.at(-1);
    expect(lastCall).toBeDefined();
    const written = JSON.parse(lastCall![3] as string) as ProjectNotes;
    expect(written.sessions[0].body).toContain("- [ ] Parent\n");
    expect(written.sessions[0].body).toContain("  - [ ] New child @");
  });
});
