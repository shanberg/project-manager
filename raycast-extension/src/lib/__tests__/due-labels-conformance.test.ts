import { describe, it, expect } from "vitest";
import { formatRelativeDueShort } from "../format-relative-due";
import fixture from "./due-labels.fixture.json";

/**
 * The extension's due labels against PmLib's, which is the one that decides.
 *
 * Raycast keeps its own implementation on purpose: `formatRelativeDueShort` renders `nextDue` for
 * every row of the projects list, and asking the contract for each label would be a subprocess per
 * row — the exact cost the contract was designed not to impose. A copy is the right answer here. A
 * copy *nothing checks* is what went wrong before: this file's header used to claim it and the Swift
 * one "read identically", and they disagreed at eighteen of the fifty-nine day-offsets inside a month
 * because one floored its units and the other rounded them. A task eleven days out read "in 1w" in
 * the menubar and "in 2w" here.
 *
 * The fixture is generated from PmLib, by `pm due-table`, and checked in. Regenerate it with:
 *
 *     pm-swift/.build/debug/pm due-table > src/lib/__tests__/due-labels.fixture.json
 *
 * If this fails, the extension is the one that is wrong unless PmLib's rule deliberately changed.
 */
const table = fixture as { days: number; label: string }[];

/** A stored `due:` value `days` from today, the way a notes file spells one. */
function dueIn(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${mo}-${day}`;
}

describe("due labels match PmLib", () => {
  it("has a fixture covering every offset inside a month", () => {
    expect(table).toHaveLength(59);
    expect(table[0].days).toBe(-29);
    expect(table[table.length - 1].days).toBe(29);
  });

  it.each(table)("renders $days days out as $label", ({ days, label }) => {
    expect(formatRelativeDueShort(dueIn(days))).toBe(label);
  });

  /**
   * The specific offsets the two implementations used to disagree on, named rather than left to the
   * table — so the reason this file exists survives a regeneration of the fixture.
   */
  it("floors weeks rather than rounding them", () => {
    expect(formatRelativeDueShort(dueIn(11))).toBe("in 1w");
    expect(formatRelativeDueShort(dueIn(13))).toBe("in 1w");
    expect(formatRelativeDueShort(dueIn(14))).toBe("in 2w");
    expect(formatRelativeDueShort(dueIn(-11))).toBe("1w ago");
  });

  /**
   * Past a month it used to fall back to a bare "7/4", which is the one answer a badge cannot use —
   * a date you have to do arithmetic on, in the place whose whole point is that you don't.
   */
  it("stays relative past a month rather than showing a bare date", () => {
    expect(formatRelativeDueShort(dueIn(45))).toBe("in 1mo");
    expect(formatRelativeDueShort(dueIn(400))).toBe("in 1y");
    expect(formatRelativeDueShort(dueIn(-45))).toBe("1mo ago");
  });

  it("returns something readable for input it cannot parse", () => {
    expect(formatRelativeDueShort("not a date")).toBe("not a date");
  });
});
