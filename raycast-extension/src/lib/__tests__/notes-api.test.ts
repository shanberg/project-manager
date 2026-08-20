import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  addTodoAfterInNotes,
  addTodoBeforeInNotes,
  addTodoAsChildInNotes,
  addTodoToTodaySession,
  appendNoteToTodaySession,
  editTodoInNotes,
  updateDueDateInNotes,
  wrapTodoInNotes,
  toggleAllTodosInNotes,
  stripInlineDueFromText,
  type NotesShowOutput,
  type ProjectNotes,
  type Todo,
} from "../notes-api";
import type { PreferenceValues } from "../types";
import { runPmWithPrefs } from "../pm";

vi.mock("../pm", () => ({
  buildEnv: vi.fn(() => ({})),
  runPmWithPrefs: vi.fn(),
  runPmWithStdin: vi
    .fn()
    .mockResolvedValue({ stdout: "", code: 0, stderr: "" }),
  syncObsidianPrefsToPmConfig: vi.fn().mockResolvedValue(undefined),
}));

const prefs: PreferenceValues = { configPath: "/tmp/config", pmCliPath: "pm" };

function makeTodo(lineIndex: number, text: string, extra: Partial<Todo> = {}) {
  return {
    rawLine: `- [ ] ${text}`,
    text,
    checked: false,
    context: "",
    depth: 0,
    sessionIndex: 0,
    lineIndex,
    ...extra,
  } satisfies Todo;
}

const notes: ProjectNotes = {
  title: "Test",
  summary: "",
  problem: "",
  goals: [],
  approach: "",
  links: [],
  learnings: [],
  sessions: [{ date: "Mon, Mar 3, 2025", label: "", body: "- [ ] First" }],
};

/** What `pm notes show` returns. focusedKey is set so getNotes doesn't auto-focus. */
let showOutput: NotesShowOutput = {
  notes,
  todos: [makeTodo(0, "First")],
  focusedKey: "0:0",
};

beforeEach(() => {
  showOutput = { notes, todos: [makeTodo(0, "First")], focusedKey: "0:0" };
  vi.mocked(runPmWithPrefs).mockReset();
  vi.mocked(runPmWithPrefs).mockImplementation(async (_prefs, args) => {
    if (args[0] === "notes" && args[1] === "show") {
      return { stdout: JSON.stringify(showOutput), stderr: "", code: 0 };
    }
    return { stdout: "", stderr: "", code: 0 };
  });
});

/** Args of every pm invocation, in order, excluding `notes show` reads. */
function writeCalls(): string[][] {
  return vi
    .mocked(runPmWithPrefs)
    .mock.calls.map((c) => c[1] as string[])
    .filter((args) => !(args[0] === "notes" && args[1] === "show"));
}

describe("updateDueDateInNotes", () => {
  it("sets the due via pm notes todo due", async () => {
    await updateDueDateInNotes(
      prefs,
      "p",
      notes,
      makeTodo(1, "Child"),
      "2026-03-15 00:00",
    );
    expect(writeCalls()).toEqual([
      ["notes", "todo", "due", "p", "0", "1", "2026-03-15 00:00"],
    ]);
  });

  it("clears the due with --clear", async () => {
    await updateDueDateInNotes(prefs, "p", notes, makeTodo(0, "Task"), null);
    expect(writeCalls()).toEqual([
      ["notes", "todo", "due", "p", "0", "0", "--clear"],
    ]);
  });

  it("surfaces the CLI's error message", async () => {
    vi.mocked(runPmWithPrefs).mockResolvedValue({
      stdout: "",
      stderr: "Invalid due value: nope\n",
      code: 1,
    });
    await expect(
      updateDueDateInNotes(prefs, "p", notes, makeTodo(0, "Task"), "nope"),
    ).rejects.toThrow("Invalid due value: nope");
  });
});

describe("editTodoInNotes", () => {
  it("edits text via pm notes todo text", async () => {
    await editTodoInNotes(prefs, "p", notes, makeTodo(2, "Old"), "  New  ");
    expect(writeCalls()).toEqual([
      ["notes", "todo", "text", "p", "0", "2", "New"],
    ]);
  });

  it("ignores an empty edit", async () => {
    await editTodoInNotes(prefs, "p", notes, makeTodo(2, "Old"), "   ");
    expect(writeCalls()).toEqual([]);
  });
});

describe("wrapTodoInNotes", () => {
  it("wraps via pm notes todo wrap", async () => {
    await wrapTodoInNotes(prefs, "p", notes, makeTodo(1, "Child"), "Parent");
    expect(writeCalls()).toEqual([
      ["notes", "todo", "wrap", "p", "0", "1", "Parent"],
    ]);
  });
});

describe("addTodoToTodaySession", () => {
  it("quick-adds via pm notes todo add", async () => {
    await addTodoToTodaySession(prefs, "p", "New task");
    expect(writeCalls()).toEqual([["notes", "todo", "add", "p", "New task"]]);
  });

  it("passes the due through as --due", async () => {
    await addTodoToTodaySession(prefs, "p", "New task", "2026-03-15 09:00");
    expect(writeCalls()).toEqual([
      ["notes", "todo", "add", "p", "New task", "--due", "2026-03-15 09:00"],
    ]);
  });
});

describe("appendNoteToTodaySession", () => {
  it("appends via pm notes session note", async () => {
    await appendNoteToTodaySession(prefs, "p", "  Shipped the fix.  ");
    expect(writeCalls()).toEqual([
      ["notes", "session", "note", "p", "Shipped the fix."],
    ]);
  });

  it("does nothing for a blank note", async () => {
    await appendNoteToTodaySession(prefs, "p", "   \n ");
    expect(writeCalls()).toEqual([]);
  });

  it("throws with the CLI's message when the command fails", async () => {
    vi.mocked(runPmWithPrefs).mockResolvedValueOnce({
      stdout: "",
      stderr: "Project not found: p",
      code: 1,
    });
    await expect(appendNoteToTodaySession(prefs, "p", "Note")).rejects.toThrow(
      "Project not found: p",
    );
  });
});

describe("addTodoAfterInNotes", () => {
  it("inserts with --after and returns the inserted todo from the refreshed notes", async () => {
    const anchor = makeTodo(1, "Second");
    showOutput = {
      notes,
      todos: [
        makeTodo(0, "First"),
        anchor,
        makeTodo(2, "New task"),
        makeTodo(3, "Third"),
      ],
      focusedKey: "0:0",
    };

    const result = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "New task",
    );

    expect(writeCalls()).toEqual([
      ["notes", "todo", "add", "p", "New task", "--after", "0", "1"],
    ]);
    expect(result.insertedTodo.lineIndex).toBe(2);
    expect(result.insertedTodo.text).toBe("New task");
  });

  it("chaining: the returned todo is the next anchor", async () => {
    const anchor = makeTodo(0, "Anchor");
    showOutput = {
      notes,
      todos: [anchor, makeTodo(1, "First added")],
      focusedKey: "0:0",
    };
    const first = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "First added",
    );
    expect(first.insertedTodo.lineIndex).toBe(1);

    showOutput = {
      notes,
      todos: [anchor, makeTodo(1, "First added"), makeTodo(2, "Second added")],
      focusedKey: "0:0",
    };
    const second = await addTodoAfterInNotes(
      prefs,
      "p",
      first.notes,
      first.insertedTodo,
      "Second added",
    );
    expect(writeCalls().at(-1)).toEqual([
      "notes",
      "todo",
      "add",
      "p",
      "Second added",
      "--after",
      "0",
      "1",
    ]);
    expect(second.insertedTodo.lineIndex).toBe(2);
  });

  it("passes the due through as --due", async () => {
    await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      makeTodo(1, "Child"),
      "New sibling",
      "2026-03-12 00:00",
    );
    expect(writeCalls()[0]).toEqual([
      "notes",
      "todo",
      "add",
      "p",
      "New sibling",
      "--due",
      "2026-03-12 00:00",
      "--after",
      "0",
      "1",
    ]);
  });
});

describe("addTodoBeforeInNotes", () => {
  it("inserts with --before and returns the anchor at its new position", async () => {
    const anchor = makeTodo(1, "Second");
    showOutput = {
      notes,
      todos: [
        makeTodo(0, "First"),
        makeTodo(1, "New task"),
        makeTodo(2, "Second"),
      ],
      focusedKey: "0:0",
    };

    const result = await addTodoBeforeInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "New task",
    );

    expect(writeCalls()).toEqual([
      ["notes", "todo", "add", "p", "New task", "--before", "0", "1"],
    ]);
    expect(result.nextBeforeTodo.lineIndex).toBe(2);
    expect(result.nextBeforeTodo.text).toBe("Second");
  });
});

describe("addTodoAsChildInNotes", () => {
  it("inserts with --child (pm focuses the new child)", async () => {
    await addTodoAsChildInNotes(
      prefs,
      "p",
      notes,
      makeTodo(0, "Parent"),
      "Child task",
    );
    expect(writeCalls()).toEqual([
      ["notes", "todo", "add", "p", "Child task", "--child", "0", "0"],
    ]);
  });
});

describe("toggleAllTodosInNotes", () => {
  it("completes each open todo without advancing focus", async () => {
    const todos = [
      makeTodo(0, "One"),
      makeTodo(1, "Two", { checked: true }),
      makeTodo(2, "Three"),
    ];
    await toggleAllTodosInNotes(prefs, "p", notes, todos);
    expect(writeCalls()).toEqual([
      ["notes", "todo", "complete", "p", "0", "0", "--no-advance"],
      ["notes", "todo", "complete", "p", "0", "2", "--no-advance"],
    ]);
  });
});

describe("stripInlineDueFromText", () => {
  it("strips a canonical due and focus marker", () => {
    expect(stripInlineDueFromText("Task due: 2026-03-15 09:00 @")).toBe("Task");
  });

  it("strips a legacy due written after the focus marker", () => {
    expect(stripInlineDueFromText("Task @ due: 2026-03-15 09:00")).toBe("Task");
  });

  it("leaves plain text alone", () => {
    expect(stripInlineDueFromText("Email bob@example.com")).toBe(
      "Email bob@example.com",
    );
  });
});
