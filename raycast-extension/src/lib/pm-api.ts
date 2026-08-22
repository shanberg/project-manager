/**
 * The typed client for pm's contract — `pm api call <action> <json>`.
 *
 * This file is the transport and the envelope; the *inputs* are generated from `pm api describe`
 * into `pm-api.generated.ts`, so what this extension believes an action takes is derived from what
 * the binary says it takes rather than maintained alongside it.
 *
 * Everything here that used to live in `notes-api.ts` as its own composition of `pm notes todo …`
 * flags now goes through one action name and one result shape. The envelope carries a `summary`
 * written by the domain, which is what a HUD should show — three surfaces phrasing "completed X and
 * 2 subtasks" three ways is exactly the drift this contract exists to end.
 */

import { runPmWithPrefs } from "./pm";
import type { PreferenceValues } from "./types";
import type { ApiActionName, ApiInputs } from "./pm-api.generated";

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

/**
 * How a task is named. `session` is its ISO date, `line` its ordinal among the session's task lines,
 * and `digest` a hash of its text.
 *
 * Send all three back exactly as they were read. The digest is what lets pm notice that the document
 * moved between the read and the write — a session started, a task inserted — and act on the task
 * meant rather than whatever now occupies that position. See docs/task-identity.md.
 */
export interface TaskRef {
  session?: string;
  sessionOrdinal?: number;
  line: number;
  digest?: string;
}

export type ApiChangeKind =
  | "added"
  | "removed"
  | "completed"
  | "reopened"
  | "retimed"
  | "renamed"
  | "moved"
  | "focused"
  | "unfocused";

export interface ApiChange {
  kind: ApiChangeKind;
  ref?: TaskRef | null;
  was?: string | null;
  now?: string | null;
}

/** What every action returns, whether it read, wrote, or only said what it would have written. */
export interface ApiResult<Data = JsonValue> {
  action: string;
  /** One sentence, from the domain. Show this rather than composing your own. */
  summary: string;
  /** Content hash of the notes file afterwards. */
  revision?: string | null;
  changed: ApiChange[];
  focus?: TaskRef | null;
  /** True when a task reference had to be healed against a document that moved underneath. */
  relocated: boolean;
  dryRun: boolean;
  data?: Data;
}

export type ApiErrorCode =
  | "unknownAction"
  | "unsupportedAction"
  | "missingField"
  | "invalidField"
  | "projectNotFound"
  | "ambiguousProject"
  | "notesNotFound"
  | "staleReference"
  | "invalidDue"
  | "emptyText"
  | "configNotFound"
  | "writeFailed";

/** A refusal with a code to branch on, rather than a sentence to match against. */
export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly detail?: JsonValue;

  constructor(code: ApiErrorCode, message: string, detail?: JsonValue) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.detail = detail;
  }

  /** True when the fix is to read the project again — the document moved under us. */
  get isStale(): boolean {
    return this.code === "staleReference";
  }
}

/** Decode what `pm api call` printed. Separate from running it so it can be tested on its own. */
export function parseApiResponse<Data = JsonValue>(
  stdout: string,
): ApiResult<Data> {
  const trimmed = stdout.trim();
  if (!trimmed) throw new ApiError("writeFailed", "pm returned nothing.");
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    throw new ApiError(
      "writeFailed",
      `pm returned something that isn't JSON: ${trimmed.slice(0, 200)}`,
    );
  }
  const object = parsed as Record<string, unknown>;
  if (object.error) {
    const error = object.error as {
      code?: string;
      message?: string;
      detail?: JsonValue;
    };
    throw new ApiError(
      (error.code as ApiErrorCode) ?? "writeFailed",
      error.message ?? "pm refused that.",
      error.detail,
    );
  }
  return object as unknown as ApiResult<Data>;
}

export interface CallOptions {
  /** Report what the action would do, without writing. The result is identical to the real call's. */
  dryRun?: boolean;
  signal?: AbortSignal;
}

/**
 * Run one action.
 *
 * The input type comes from the manifest, so a field this extension gets wrong is a compile error
 * rather than a refusal at runtime.
 */
export async function callApi<Action extends ApiActionName, Data = JsonValue>(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath"> &
    Partial<PreferenceValues>,
  action: Action,
  input: ApiInputs[Action],
  options: CallOptions = {},
): Promise<ApiResult<Data>> {
  const args = ["api", "call", action, JSON.stringify(input ?? {})];
  if (options.dryRun) args.push("--dry-run");
  const { stdout, stderr, code } = await runPmWithPrefs(
    prefs,
    args,
    options.signal,
  );
  // A refused action still prints its envelope and exits 1, so stdout is the thing to read; stderr
  // only matters when the process didn't get far enough to say anything.
  if (!stdout.trim() && code !== 0) {
    throw new ApiError(
      "writeFailed",
      stderr.trim() || `pm api call ${action} failed (exit ${code})`,
    );
  }
  return parseApiResponse<Data>(stdout);
}

/** The manifest the binary publishes. Handy for checking the contract version at runtime. */
export async function describeApi(
  prefs: Pick<PreferenceValues, "configPath" | "pmCliPath">,
): Promise<{
  contractVersion: string;
  actions: { name: string; tier: string }[];
}> {
  const { stdout } = await runPmWithPrefs(prefs, ["api", "describe"]);
  return JSON.parse(stdout.trim());
}
