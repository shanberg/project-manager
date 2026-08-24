import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  getNotes,
  addTodoToTodaySession,
  updateDueDateInNotes,
  completeAndAdvanceInNotes,
  toggleTodoInNotes,
  getEffectiveDue,
  writeNotes,
  type Todo,
} from "../notes-api";
import { ApiError, callApi } from "../pm-api";
import type { PreferenceValues } from "../types";

/**
 * The client against the real binary, rather than against a mock of it.
 *
 * The unit tests prove this extension is consistent with what it believes the wire format to be;
 * only this proves that belief is right. Skipped when `pm` isn't installed.
 */
/**
 * The repo's own build before whatever is installed, for the same reason the generator prefers it:
 * this suite is checking the client against the contract *in this tree*, and a stale global `pm`
 * would have it pass or fail for reasons unrelated to the change being made.
 */
const built = path.join(
  __dirname,
  "..",
  "..",
  "..",
  "..",
  "pm-swift",
  ".build",
  "debug",
  "pm",
);
const binary = process.env.PM_CLI_PATH || (existsSync(built) ? built : "pm");

/**
 * Set up at module scope, not in `beforeAll` — `describe.skipIf` is evaluated when the suite is
 * defined, so a flag set later is always false and the whole file skips silently.
 */
function seed(): PreferenceValues | null {
  try {
    execFileSync(binary, ["api", "describe"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
  const root = mkdtempSync(path.join(tmpdir(), "pm-client-"));
  const config = path.join(root, "config");
  const active = path.join(root, "active");
  const archive = path.join(root, "archive");
  for (const dir of [config, active, archive])
    mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(config, "config.json"),
    JSON.stringify({
      activePath: active,
      archivePath: archive,
      domains: { W: "Work" },
      subfolders: ["docs"],
    }),
  );
  const env = { ...process.env, PM_CONFIG_HOME: config };
  execFileSync(
    binary,
    [
      "api",
      "call",
      "project.create",
      JSON.stringify({ title: "Redesign", domain: "W" }),
    ],
    { env },
  );
  for (const text of ["Review the contract", "Book the venue"]) {
    execFileSync(
      binary,
      ["api", "call", "task.add", JSON.stringify({ project: "W-1", text })],
      { env },
    );
  }
  return { configPath: config, pmCliPath: binary };
}

const seeded = seed();
const available = seeded !== null;

describe.skipIf(!available)("the client against a real pm", () => {
  const prefs = seeded as PreferenceValues;

  it("reads tasks that carry what it takes to write them back", async () => {
    const data = await getNotes(prefs, "W-1");
    const todo = data.todos.find((t) => t.text === "Review the contract");
    expect(todo).toBeDefined();
    expect(todo?.digest).toBeTruthy();
    expect(todo?.sessionISODate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("writes a due date and reads it back", async () => {
    const before = await getNotes(prefs, "W-1");
    const todo = before.todos.find((t) => t.text === "Book the venue") as Todo;
    await updateDueDateInNotes(prefs, "W-1", before.notes, todo, "2026-12-01");
    const after = await getNotes(prefs, "W-1");
    const written = after.todos.find((t) => t.text === "Book the venue");
    expect(written?.dueDate).toContain("2026-12-01");
    // The field the extension used to walk the ancestor chain for itself. Absent when nothing is
    // due — Swift omits nil optionals — which is why getEffectiveDue falls back rather than reads.
    expect(getEffectiveDue(after.todos, written as Todo)).toContain(
      "2026-12-01",
    );
  });

  it("adds a task to today's session", async () => {
    await addTodoToTodaySession(prefs, "W-1", "Draft the reply");
    const data = await getNotes(prefs, "W-1");
    expect(data.todos.map((t) => t.text)).toContain("Draft the reply");
  });

  it("returns the domain's own sentence for a completion", async () => {
    const data = await getNotes(prefs, "W-1");
    const todo = data.todos.find((t) => t.text === "Draft the reply") as Todo;
    const summary = await completeAndAdvanceInNotes(
      prefs,
      "W-1",
      data.notes,
      data.todos,
      todo,
    );
    expect(summary).toContain("Draft the reply");
    expect(summary.startsWith("Completed")).toBe(true);
  });

  it("re-opens a completed task", async () => {
    const data = await getNotes(prefs, "W-1");
    const done = data.todos.find((t) => t.checked) as Todo;
    await toggleTodoInNotes(prefs, "W-1", data.notes, done);
    const after = await getNotes(prefs, "W-1");
    expect(after.todos.find((t) => t.text === done.text)?.checked).toBe(false);
  });

  it("refuses a reference to a task that has changed, with a code to branch on", async () => {
    const data = await getNotes(prefs, "W-1");
    const todo = data.todos[0];
    await expect(
      callApi(prefs, "task.complete", {
        project: "W-1",
        task: {
          session: todo.sessionISODate ?? "",
          line: todo.lineIndex ?? 0,
          digest: "deadbeef",
        },
      }),
    ).rejects.toSatisfy(
      (error: unknown) => error instanceof ApiError && error.isStale,
    );
  });

  it("writes a detail section without sending the whole document", async () => {
    const before = await getNotes(prefs, "W-1");
    await writeNotes(prefs, "W-1", {
      ...before.notes,
      summary: "A contract for every surface.",
    });
    const after = await getNotes(prefs, "W-1");
    expect(after.notes.summary).toBe("A contract for every surface.");
    // The sessions and tasks the whole-document path used to put at risk are untouched.
    expect(after.todos.length).toBe(before.todos.length);
    expect(after.notes.sessions.length).toBe(before.notes.sessions.length);
  });

  it("previews without writing", async () => {
    const data = await getNotes(prefs, "W-1");
    const todo = data.todos.find((t) => !t.checked) as Todo;
    const preview = await callApi(
      prefs,
      "task.complete",
      {
        project: "W-1",
        task: {
          session: todo.sessionISODate ?? "",
          line: todo.lineIndex ?? 0,
          digest: todo.digest ?? "",
        },
      },
      { dryRun: true },
    );
    expect(preview.dryRun).toBe(true);
    expect(preview.summary.startsWith("Would complete")).toBe(true);
    const after = await getNotes(prefs, "W-1");
    expect(after.todos.find((t) => t.text === todo.text)?.checked).toBe(false);
  });
});
