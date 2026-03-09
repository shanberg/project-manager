import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  getRecentProjectsByEdit,
  type FocusedProjectData,
} from "../recent-by-edit";
import type { PreferenceValues } from "../types";
import { getPmPaths, runPmWithPrefs } from "../pm";
import { getNotes, resolveNotesPath } from "../notes-api";
import { stat } from "fs/promises";

vi.mock("../pm", () => ({
  getPmPaths: vi.fn(),
  runPmWithPrefs: vi.fn(),
}));

vi.mock("../notes-api", () => ({
  getNotes: vi.fn(),
  resolveNotesPath: vi.fn(),
}));

vi.mock("fs/promises", () => ({
  stat: vi.fn(),
}));

const prefs: Pick<PreferenceValues, "configPath" | "pmCliPath"> = {
  configPath: "/tmp/config",
  pmCliPath: "pm",
};

const LIST_ALL_STDOUT = `Active:
  proj-a
  proj-b
  proj-c
  proj-d
  proj-e
  proj-f
  proj-g
  proj-h
  proj-i
  proj-j
  proj-k
  proj-l
  proj-m
  proj-n
  proj-o
  proj-p
  proj-q
  proj-r
  proj-s
  proj-t
Archive:
  (none)
`;

function makeNotesResponse(projectName: string, doneCount = 0, totalCount = 3) {
  return {
    notes: {
      title: projectName,
      summary: "",
      problem: "",
      goals: [],
      approach: "",
      links: [],
      learnings: [],
      sessions: [],
    },
    todos: Array.from({ length: totalCount }, (_, i) => ({
      text: `Task ${i + 1}`,
      checked: i < doneCount,
      rawLine: `- [${i < doneCount ? "x" : " "}] Task ${i + 1}`,
      context: "",
    })),
  };
}

beforeEach(() => {
  vi.mocked(getNotes).mockClear();
  vi.mocked(getPmPaths).mockResolvedValue({
    activePath: "/active",
    archivePath: "/archive",
  });
  vi.mocked(runPmWithPrefs).mockImplementation(async (_, args) => {
    if (args[0] === "list" && args[1] === "--all") {
      return { stdout: LIST_ALL_STDOUT, stderr: "", code: 0 };
    }
    return { stdout: "", stderr: "", code: 0 };
  });
  vi.mocked(resolveNotesPath).mockResolvedValue("/notes/project.md");
  vi.mocked(stat).mockResolvedValue({ mtime: 1000 } as ReturnType<typeof stat>);
  vi.mocked(getNotes).mockImplementation(async (_, projectName: string) =>
    makeNotesResponse(projectName),
  );
});

describe("getRecentProjectsByEdit", () => {
  it("calls getNotes only for top 10 projects when no excludeKey", async () => {
    const result = await getRecentProjectsByEdit(prefs, 10);

    expect(result).toHaveLength(10);
    expect(vi.mocked(getNotes).mock.calls.length).toBe(10);
    const projectNamesCalled = vi.mocked(getNotes).mock.calls.map(
      (c) => c[1] as string,
    );
    expect(projectNamesCalled).toEqual([
      "proj-a", "proj-b", "proj-c", "proj-d", "proj-e",
      "proj-f", "proj-g", "proj-h", "proj-i", "proj-j",
    ]);
  });

  it("calls getNotes only for top 11 when excludeKey is set (then returns 10 after filtering)", async () => {
    const excludeKey = "/active:proj-c";
    const result = await getRecentProjectsByEdit(prefs, 10, excludeKey);

    expect(result).toHaveLength(10);
    expect(result.every((p) => `${p.basePath}:${p.name}` !== excludeKey)).toBe(
      true,
    );
    expect(vi.mocked(getNotes).mock.calls.length).toBe(11);
  });

  it("returns exactly 10 items when excludeKey is set and focused is in top 11", async () => {
    const excludeKey = "/active:proj-a";
    const result = await getRecentProjectsByEdit(prefs, 10, excludeKey);

    expect(result).toHaveLength(10);
    const keys = result.map((p) => `${p.basePath}:${p.name}`);
    expect(keys).not.toContain(excludeKey);
    expect(result[0].name).toBe("proj-b");
  });

  it("does not call getNotes for focused project when focusedProjectData is provided", async () => {
    const excludeKey = "/active:proj-c";
    const focusedProjectData: FocusedProjectData = {
      name: "proj-c",
      basePath: "/active",
      done: 1,
      total: 3,
      nextDue: null,
      notes: {
        summary: "Focused",
        problem: "",
        goals: [],
        approach: "",
      },
    };

    const result = await getRecentProjectsByEdit(
      prefs,
      10,
      excludeKey,
      focusedProjectData,
    );

    expect(result).toHaveLength(10);
    const getNotesCalls = vi.mocked(getNotes).mock.calls.map((c) => c[1]);
    expect(getNotesCalls).not.toContain("proj-c");
    expect(getNotesCalls.length).toBe(10);
  });

  it("returns correct shape (name, basePath, mtime, done, total, nextDue, notes) for each item", async () => {
    const result = await getRecentProjectsByEdit(prefs, 10);

    for (const p of result) {
      expect(p).toMatchObject({
        name: expect.any(String),
        basePath: "/active",
        mtime: 1000,
        done: expect.any(Number),
        total: expect.any(Number),
      });
      expect("nextDue" in p).toBe(true);
      expect("notes" in p).toBe(true);
      if (p.notes) {
        expect(p.notes).toMatchObject({
          summary: expect.any(String),
          problem: expect.any(String),
          goals: expect.any(Array),
          approach: expect.any(String),
        });
      }
    }
  });

  it("sorts by mtime descending (most recent first)", async () => {
    let callIndex = 0;
    vi.mocked(stat).mockImplementation(() => {
      callIndex += 1;
      return Promise.resolve({
        mtime: 1000 + callIndex,
      } as ReturnType<typeof stat>);
    });

    const result = await getRecentProjectsByEdit(prefs, 3);

    expect(result).toHaveLength(3);
    expect(result[0].mtime).toBeGreaterThanOrEqual(result[1].mtime);
    expect(result[1].mtime).toBeGreaterThanOrEqual(result[2].mtime);
  });
});
