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
  getEffectiveDue,
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

/** Tasks carry the digest the contract reads them with, and send it back on every write. */
function makeTodo(lineIndex: number, text: string, extra: Partial<Todo> = {}) {
  return {
    rawLine: `- [ ] ${text}`,
    text,
    checked: false,
    context: "",
    depth: 0,
    sessionIndex: 0,
    lineIndex,
    sessionISODate: "2026-03-03",
    digest: `d-${text.replace(/\s+/g, "-").toLowerCase()}`,
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

/** What `notes.get` returns. focusedKey is set so getNotes doesn't auto-focus. */
let showOutput: NotesShowOutput = {
  notes,
  todos: [makeTodo(0, "First")],
  focusedKey: "0:0",
};

/** An envelope shaped like the dispatcher's, for whatever the action added. */
function envelope(added?: string) {
  return {
    action: "test",
    summary: "Did the thing.",
    revision: "abc123",
    changed: added
      ? [
          {
            kind: "added",
            ref: {
              session: "2026-03-03",
              line: 9,
              digest: `d-${added.replace(/\s+/g, "-").toLowerCase()}`,
            },
            now: added,
          },
        ]
      : [],
    relocated: false,
    dryRun: false,
  };
}

/** The text of the task an `api call task.add` was asked to add, for the mocked envelope. */
function addedText(args: string[]): string | undefined {
  if (args[2] !== "task.add") return undefined;
  return (JSON.parse(args[3]) as { text?: string }).text;
}

beforeEach(() => {
  showOutput = { notes, todos: [makeTodo(0, "First")], focusedKey: "0:0" };
  vi.mocked(runPmWithPrefs).mockReset();
  vi.mocked(runPmWithPrefs).mockImplementation(async (_prefs, args) => {
    if (args[0] === "api" && args[1] === "call" && args[2] === "notes.get") {
      return {
        stdout: JSON.stringify({ ...envelope(), data: showOutput }),
        stderr: "",
        code: 0,
      };
    }
    if (args[0] === "api") {
      return {
        stdout: JSON.stringify(envelope(addedText(args))),
        stderr: "",
        code: 0,
      };
    }
    if (args[0] === "notes" && args[1] === "show") {
      return { stdout: JSON.stringify(showOutput), stderr: "", code: 0 };
    }
    return { stdout: "", stderr: "", code: 0 };
  });
});

/** Every action the extension asked for, decoded — the contract's own vocabulary rather than argv. */
function actions(): { action: string; input: Record<string, unknown> }[] {
  return vi
    .mocked(runPmWithPrefs)
    .mock.calls.map((c) => c[1] as string[])
    .filter(
      (args) =>
        args[0] === "api" && args[1] === "call" && args[2] !== "notes.get",
    )
    .map((args) => ({ action: args[2], input: JSON.parse(args[3] ?? "{}") }));
}

/** The reference a write sent for a task, which must be the one the read gave it. */
const refFor = (todo: Todo) => ({
  session: todo.sessionISODate,
  line: todo.lineIndex,
  digest: todo.digest,
});

describe("updateDueDateInNotes", () => {
  it("sets the due, naming the task by date and digest", async () => {
    const todo = makeTodo(1, "Child");
    await updateDueDateInNotes(prefs, "p", notes, todo, "2026-03-15 00:00");
    expect(actions()).toEqual([
      {
        action: "task.setDue",
        input: { project: "p", task: refFor(todo), due: "2026-03-15 00:00" },
      },
    ]);
  });

  it("clears the due with clearDue", async () => {
    const todo = makeTodo(0, "Task");
    await updateDueDateInNotes(prefs, "p", notes, todo, null);
    expect(actions()).toEqual([
      {
        action: "task.setDue",
        input: { project: "p", task: refFor(todo), clearDue: true },
      },
    ]);
  });

  it("surfaces the contract's own refusal", async () => {
    vi.mocked(runPmWithPrefs).mockResolvedValue({
      stdout: JSON.stringify({
        error: { code: "invalidDue", message: "Invalid due value: nope" },
      }),
      stderr: "",
      code: 1,
    });
    await expect(
      updateDueDateInNotes(prefs, "p", notes, makeTodo(0, "Task"), "nope"),
    ).rejects.toThrow("Invalid due value: nope");
  });
});

describe("editTodoInNotes", () => {
  it("renames via task.setText", async () => {
    const todo = makeTodo(2, "Old");
    await editTodoInNotes(prefs, "p", notes, todo, "  New  ");
    expect(actions()).toEqual([
      {
        action: "task.setText",
        input: { project: "p", task: refFor(todo), text: "New" },
      },
    ]);
  });

  it("ignores an empty edit", async () => {
    await editTodoInNotes(prefs, "p", notes, makeTodo(2, "Old"), "   ");
    expect(actions()).toEqual([]);
  });
});

describe("wrapTodoInNotes", () => {
  it("wraps via task.wrap", async () => {
    const todo = makeTodo(1, "Child");
    await wrapTodoInNotes(prefs, "p", notes, todo, "Parent");
    expect(actions()).toEqual([
      {
        action: "task.wrap",
        input: { project: "p", task: refFor(todo), text: "Parent" },
      },
    ]);
  });
});

describe("addTodoToTodaySession", () => {
  it("quick-adds via task.add", async () => {
    await addTodoToTodaySession(prefs, "p", "New task");
    expect(actions()).toEqual([
      { action: "task.add", input: { project: "p", text: "New task" } },
    ]);
  });

  it("passes the due through", async () => {
    await addTodoToTodaySession(prefs, "p", "New task", "2026-03-15 09:00");
    expect(actions()).toEqual([
      {
        action: "task.add",
        input: { project: "p", text: "New task", due: "2026-03-15 09:00" },
      },
    ]);
  });
});

describe("appendNoteToTodaySession", () => {
  it("appends via session.note", async () => {
    await appendNoteToTodaySession(prefs, "p", "  Shipped the fix.  ");
    expect(actions()).toEqual([
      {
        action: "session.note",
        input: { project: "p", prose: "Shipped the fix." },
      },
    ]);
  });

  it("does nothing for a blank note", async () => {
    await appendNoteToTodaySession(prefs, "p", "   \n ");
    expect(actions()).toEqual([]);
  });

  it("throws with the contract's message when the action fails", async () => {
    vi.mocked(runPmWithPrefs).mockResolvedValueOnce({
      stdout: JSON.stringify({
        error: {
          code: "projectNotFound",
          message: "No project found matching: p",
        },
      }),
      stderr: "",
      code: 1,
    });
    await expect(appendNoteToTodaySession(prefs, "p", "Note")).rejects.toThrow(
      "No project found matching: p",
    );
  });
});

describe("addTodoAfterInNotes", () => {
  it("inserts after the anchor and returns the task the contract says it added", async () => {
    const anchor = makeTodo(1, "Second");
    const inserted = makeTodo(2, "New task");
    showOutput = {
      notes,
      todos: [makeTodo(0, "First"), anchor, inserted, makeTodo(3, "Third")],
      focusedKey: "0:0",
    };

    const result = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "New task",
    );

    expect(actions()).toEqual([
      {
        action: "task.add",
        input: {
          project: "p",
          text: "New task",
          anchor: refFor(anchor),
          position: "after",
        },
      },
    ]);
    // Found by the digest the envelope reported, not by arithmetic on the anchor's line number.
    expect(result.insertedTodo.text).toBe("New task");
    expect(result.insertedTodo.lineIndex).toBe(2);
  });

  it("chaining: the returned todo is the next anchor", async () => {
    const anchor = makeTodo(0, "Anchor");
    const first = makeTodo(1, "First added");
    showOutput = { notes, todos: [anchor, first], focusedKey: "0:0" };
    const one = await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "First added",
    );
    expect(one.insertedTodo.text).toBe("First added");

    const second = makeTodo(2, "Second added");
    showOutput = { notes, todos: [anchor, first, second], focusedKey: "0:0" };
    const two = await addTodoAfterInNotes(
      prefs,
      "p",
      one.notes,
      one.insertedTodo,
      "Second added",
    );
    expect(actions().at(-1)).toEqual({
      action: "task.add",
      input: {
        project: "p",
        text: "Second added",
        anchor: refFor(first),
        position: "after",
      },
    });
    expect(two.insertedTodo.text).toBe("Second added");
  });

  it("passes the due through", async () => {
    const anchor = makeTodo(1, "Child");
    await addTodoAfterInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "New sibling",
      "2026-03-12 00:00",
    );
    expect(actions()[0]).toEqual({
      action: "task.add",
      input: {
        project: "p",
        text: "New sibling",
        anchor: refFor(anchor),
        position: "after",
        due: "2026-03-12 00:00",
      },
    });
  });
});

describe("addTodoBeforeInNotes", () => {
  it("inserts before the anchor and returns the anchor, found by its digest", async () => {
    const anchor = makeTodo(1, "Second");
    // The anchor is pushed down a line by the insert; its digest is unchanged, which is how it's
    // found rather than recalculated.
    const moved = makeTodo(2, "Second");
    showOutput = {
      notes,
      todos: [makeTodo(0, "First"), makeTodo(1, "New task"), moved],
      focusedKey: "0:0",
    };

    const result = await addTodoBeforeInNotes(
      prefs,
      "p",
      notes,
      anchor,
      "New task",
    );

    expect(actions()).toEqual([
      {
        action: "task.add",
        input: {
          project: "p",
          text: "New task",
          anchor: refFor(anchor),
          position: "before",
        },
      },
    ]);
    expect(result.nextBeforeTodo.text).toBe("Second");
    expect(result.nextBeforeTodo.lineIndex).toBe(2);
  });
});

describe("addTodoAsChildInNotes", () => {
  it("inserts as a child (the contract focuses the new child)", async () => {
    const parent = makeTodo(0, "Parent");
    await addTodoAsChildInNotes(prefs, "p", notes, parent, "Child task");
    expect(actions()).toEqual([
      {
        action: "task.add",
        input: {
          project: "p",
          text: "Child task",
          anchor: refFor(parent),
          position: "child",
        },
      },
    ]);
  });
});

describe("toggleAllTodosInNotes", () => {
  it("completes the whole selection in one write", async () => {
    const one = makeTodo(0, "One");
    const three = makeTodo(2, "Three");
    await toggleAllTodosInNotes(prefs, "p", notes, [
      one,
      makeTodo(1, "Two", { checked: true }),
      three,
    ]);
    // One action, not one per task — one write, one journal entry, one step to undo.
    expect(actions()).toEqual([
      {
        action: "task.complete",
        input: {
          project: "p",
          tasks: [refFor(one), refFor(three)],
          advanceFocus: false,
        },
      },
    ]);
  });

  it("does nothing when everything is already complete", async () => {
    await toggleAllTodosInNotes(prefs, "p", notes, [
      makeTodo(0, "One", { checked: true }),
    ]);
    expect(actions()).toEqual([]);
  });
});

describe("getEffectiveDue", () => {
  it("reads what the contract computed rather than walking ancestors again", () => {
    const todo = makeTodo(1, "Child", {
      effectiveDueDate: "2026-04-01",
      dueDate: null,
    });
    expect(getEffectiveDue([todo], todo)).toBe("2026-04-01");
  });

  it("falls back to the task's own due", () => {
    const todo = makeTodo(0, "Task", { dueDate: "2026-05-05" });
    expect(getEffectiveDue([todo], todo)).toBe("2026-05-05");
  });

  it("is null when nothing is due", () => {
    expect(getEffectiveDue([], makeTodo(0, "Task"))).toBeNull();
  });
});
