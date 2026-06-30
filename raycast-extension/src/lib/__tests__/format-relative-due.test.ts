import { describe, expect, it } from "vitest";
import {
  formatRelativeDue,
  isDueOverdue,
  parseDueDate,
} from "../format-relative-due";

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

  it("parses due: prefix on ISO date", () => {
    const d = parseDueDate("due: 2025-03-15");
    expect(d?.getFullYear()).toBe(2025);
    expect(d?.getMonth()).toBe(2);
    expect(d?.getDate()).toBe(15);
  });

  it("parses due: prefix on D-M-YYYY", () => {
    const d = parseDueDate("due: 15-03-2025");
    expect(d?.getFullYear()).toBe(2025);
    expect(d?.getMonth()).toBe(2);
    expect(d?.getDate()).toBe(15);
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

describe("isDueOverdue", () => {
  it("is true for a past date", () => {
    const past = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const str = `${past.getFullYear()}-${String(past.getMonth() + 1).padStart(2, "0")}-${String(past.getDate()).padStart(2, "0")} 09:00`;
    expect(isDueOverdue(str)).toBe(true);
  });

  it("is false for a future date", () => {
    const future = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const str = `${future.getFullYear()}-${String(future.getMonth() + 1).padStart(2, "0")}-${String(future.getDate()).padStart(2, "0")} 09:00`;
    expect(isDueOverdue(str)).toBe(false);
  });

  it("is false for an unparseable date", () => {
    expect(isDueOverdue("not-a-date")).toBe(false);
  });
});
