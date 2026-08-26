import { describe, it, expect } from "vitest";
import { parseListAllOutput, isAreaFolder, getNotesPath } from "../utils";

describe("isAreaFolder", () => {
  it("reads the kind off the folder name, the way PmLib does", () => {
    expect(isAreaFolder("W-12 Website Refresh")).toBe(false);
    expect(isAreaFolder("H-004 Maxwell Carmody")).toBe(false);
    expect(isAreaFolder("Team 1:1s")).toBe(true);
    expect(isAreaFolder("Hiring")).toBe(true);
  });

  it("does not mistake a hyphenated name for a code prefix", () => {
    expect(isAreaFolder("On-call rotation")).toBe(true);
    expect(isAreaFolder("W-12")).toBe(true);
  });
});

describe("getNotesPath", () => {
  it("keeps an unprefixed name whole", () => {
    // Splitting on the first space made this "docs/Notes - 1:1s.md".
    expect(getNotesPath("/PARA/areas/Team 1:1s")).toBe(
      "/PARA/areas/Team 1:1s/docs/Notes - Team 1:1s.md",
    );
  });

  it("still strips a real code prefix", () => {
    expect(getNotesPath("/PARA/active/W-12 Website Refresh")).toBe(
      "/PARA/active/W-12 Website Refresh/docs/Notes - Website Refresh.md",
    );
  });
});

describe("parseListAllOutput", () => {
  it("reads all three sections", () => {
    const stdout = [
      "Active:",
      " W-1 Website Refresh",
      " W-2 Other Thing",
      "",
      "Areas:",
      " Hiring",
      " Team 1:1s",
      "",
      "Archive:",
      " W-4 Old Thing",
    ].join("\n");

    expect(parseListAllOutput(stdout)).toEqual({
      active: ["W-1 Website Refresh", "W-2 Other Thing"],
      areas: ["Hiring", "Team 1:1s"],
      archive: ["W-4 Old Thing"],
    });
  });

  it("handles empty sections", () => {
    const stdout = [
      "Active:",
      "  (none)",
      "",
      "Areas:",
      "  (none)",
      "",
      "Archive:",
      " W-4 Old",
    ].join("\n");
    const out = parseListAllOutput(stdout);
    expect(out.active).toEqual([]);
    expect(out.areas).toEqual([]);
    expect(out.archive).toEqual(["W-4 Old"]);
  });

  it("still reads output from a pm that has no Areas section", () => {
    const stdout = ["Active:", " W-1 A", "", "Archive:", " W-4 B"].join("\n");
    expect(parseListAllOutput(stdout)).toEqual({
      active: ["W-1 A"],
      areas: [],
      archive: ["W-4 B"],
    });
  });
});
