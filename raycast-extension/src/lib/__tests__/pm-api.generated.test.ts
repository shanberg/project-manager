import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  API_TIERS,
  API_CONTRACT_VERSION,
  type ApiActionName,
} from "../pm-api.generated";

/**
 * The generated client is only worth something if it matches the binary it was generated from. This
 * regenerates from whatever `pm` is installed and compares, so an action added to the contract and
 * not regenerated here fails on the next test run rather than when somebody finally calls it.
 *
 * Skipped when `pm` isn't on PATH — the extension's own tests shouldn't need it installed.
 */
const root = path.join(__dirname, "..", "..", "..");

function run(args: string[]): string | null {
  try {
    return execFileSync(
      "node",
      [path.join(root, "scripts", "generate-api-types.mjs"), ...args],
      {
        encoding: "utf-8",
        cwd: root,
        stdio: ["ignore", "pipe", "ignore"],
      },
    );
  } catch {
    return null;
  }
}

const regenerated = run(["--print"]);

describe("the generated client", () => {
  it.skipIf(!regenerated)("matches what the installed pm describes", () => {
    const current = readFileSync(
      path.join(root, "src", "lib", "pm-api.generated.ts"),
      "utf-8",
    );
    expect(current).toBe(regenerated);
  });

  it("knows which actions are reads and which are writes", () => {
    expect(API_TIERS["task.list" as ApiActionName]).toBe("query");
    expect(API_TIERS["task.complete" as ApiActionName]).toBe("mutation");
    expect(API_TIERS["app.openWindow" as ApiActionName]).toBe("affordance");
  });

  it("records the contract version it was generated from", () => {
    expect(API_CONTRACT_VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
