import { describe, expect, it } from "vitest";
import { formatRelativeDue, parseDueDate } from "../format-relative-due";

describe("parseDueDate", () => {
  it("parses YYYY-MM-DD", () => {
    const d = parseDueDate("2025-03-15");
    expect(d).toBeInstanceOf(Date);
    expect(d?.getFullYear()).toBe(2025);
    expect(d?.getMonth()).toBe(2);
    expect(d?.getDate()).toBe(15);
  });

  it("parses YYYY-MM-DD HH:mm", () => {
    const d = parseDueDate("2025-03-15 14:30");
    expect(d).toBeInstanceOf(Date);
    expect(d?.getHours()).toBe(14);
    expect(d?.getMinutes()).toBe(30);
  });

  it("returns null for invalid input", () => {
    expect(parseDueDate("invalid")).toBeNull();
  });
});

describe("formatRelativeDue", () => {
  it("returns raw string when parse fails", () => {
    expect(formatRelativeDue("invalid")).toBe("invalid");
  });

  it("formats future date relatively", () => {
    const in48Hours = new Date(Date.now() + 48 * 60 * 60 * 1000);
    const str = `${in48Hours.getFullYear()}-${String(in48Hours.getMonth() + 1).padStart(2, "0")}-${String(in48Hours.getDate()).padStart(2, "0")}`;
    expect(formatRelativeDue(str)).toBe("in 2 days");
  });
});
