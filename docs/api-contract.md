# A shared contract for PM's surfaces

**Status:** the dispatcher, the manifest, and the argv and MCP adapters are built, 2026-08-22. `Sources/PmLib/Api/` is the implementation, `pm api describe` and `pm api call` the surface, `ApiTests.swift` the tests. The remaining adapters — the Raycast client and the in-process one — are not. Task identity is settled separately in [task-identity.md](task-identity.md), which this depends on.

## The problem

PM's domain is implemented once, in PmLib, and then spoken about in five different dialects.

| Surface | Reaches the domain by | Adds |
|---|---|---|
| `pm` CLI | argv → `NotesService` | JSON only from `notes show`; everything else is prose and an exit code |
| Raycast | spawning `pm`, parsing stdout | **re-implements domain logic in TypeScript** |
| Mac app | linking PmLib in-process | undo/redo, focus animation, project index, recents |
| App Intents | linking PmLib in-process | entities with stable ids, disambiguation |
| MCP (`pm mcp`) | the dispatcher, directly | a stricter published schema |
| `pm api` | the dispatcher, directly | nothing — transport only |

Alongside them, `~/.config/pm/` holds `focused.json`, `recent-projects.json`, `task-timing.json` and `panel-settings.json` — an unversioned bus that three of the five read and write directly, with no shared definition of what's in it.

### The drift is already measurable

- `pm-mac/PM/Model/RelativeDue.swift` states in its own header that it was "ported from the Raycast extension's `format-relative-due.ts` so both surfaces read identically". Two implementations of one function, kept in agreement by hand.
- `raycast-extension/src/lib/notes-api.ts` hand-mirrors `Todo`, `ProjectNotes` and `NotesShowOutput` as TypeScript interfaces, then re-derives `getEffectiveDue` — which is `todosWithEffectiveDueDates` in Swift, already written and already tested. Forgetting to apply that exact function is what produced spurious retiming marks in the quick bar preview last week.
- `formatSessionDate` and `stripInlineDueFromText` exist on both sides; the latter duplicates `TaskContent.split`, the file that exists precisely so nothing re-derives task-line structure itself.
- `TaskTiming.swift` says it "shares its schema with the Raycast extension's `task-timing`". It doesn't: the Raycast module writes to Raycast's `LocalStorage` rather than the config dir, keys on `notesPath::rawLine` where Swift keys on `notesPath::sessionIndex:lineIndex`, and has no callers anywhere in `src/`. A sharing claim in a comment is not a contract.

There are also four spellings of two identities in circulation: `basePath:name` for a project, `sessionIndex:lineIndex` for a task, `sessionIndex:lineIndex\u{1F}projectKey` inside `TaskEntity.id`, and `notesPath::…` for timing.

None of this is carelessness. It's what happens when the only shared artifact is a binary whose output format is documented by reading its source.

## Shape: one dispatcher, four adapters

A single entry point in PmLib:

```
perform(action, input, options) -> Result
```

Everything else is an adapter over it.

- **In-process** — the Mac app and App Intents call the dispatcher with native Swift types. No JSON, no subprocess. The app keeps calling PmLib directly, which is what lets it animate; the contract must not turn a function call into a process spawn.
- **argv / JSON** — `pm api call task.complete '{…}'`, used by Raycast, plus the existing human-facing subcommands kept as aliases.
- **stdio JSON-RPC** — `pm api serve`. The MCP server is this process, or a thin wrapper spawning it.
- **URL scheme** — `pmpanel://`, for the tier-3 affordances below.

`PMStore` becomes a cache, an undo stack and a focus-move classifier layered over the dispatcher, rather than a second implementation of the same operations.

## The binary describes itself

`pm api describe` returns a manifest: every entity, every action, and a JSON Schema for each action's input and result.

The MCP tool list is **generated** from that manifest at startup. So are the CLI's flags, and Raycast's typed client. An MCP tool cannot drift from the CLI, because one is derived from the other rather than maintained beside it. This is the mechanism that makes "the same contract everywhere" a property of the system instead of a discipline — and discipline is exactly what the four bullets above show doesn't hold.

The manifest carries a contract version. Clients assert a minimum and fail with "update pm" in one place, replacing the silent-fallback pattern in `getPmConfig`, which currently degrades to reading `config.json` when the CLI is too old and tells nobody.

## Actions, in three tiers

Only tiers 1 and 2 are published to every adapter.

**Tier 1 — mutations.** Pure domain, work headless, mean the same thing everywhere.

```
task.add          task.complete    task.reopen      task.focus
task.diveIn       task.setDue      task.setText     task.wrap
task.unwrap       task.move        task.delete
session.start     session.note     session.rename   session.delete   session.prune
notes.setDetails  notes.addLink
project.create    project.rename   project.archive  project.unarchive  project.focus
config.set
```

**Tier 2 — queries.** No side effects.

```
project.list   project.get     notes.get      task.list
task.search    task.whatsDue   task.progress  focus.get
capture.parse  config.get
```

`capture.parse` exposes `QuickCaptureParser` — the `due:` and trailing `@project` shorthand — as a pure function, so a model can use the same phrasing the quick bar accepts instead of inventing its own.

**Tier 3 — affordances.** Requests to a running app, not domain operations: `openWindow`, `openInFinder`, `openInObsidian`, `showPanel`, `settings`. Published only to the in-process and URL adapters. MCP does not get them.

This means `pm api describe` will list fewer things than the quick bar's `>` menu shows, which is correct: that menu deliberately mixes doing with going.

## Every mutation returns the same envelope

```
{
  revision,                        // mtime + content hash of the notes file
  summary,                         // one human sentence
  changed: [ { ref, was, now } ],  // structured diff
  focus,                           // where focus ended up, if it moved
  relocated                        // a TaskRef healed against drift; see task-identity.md
}
```

`summary` is the Mac app's receipt line, Raycast's HUD, and the sentence a model reads back. `changed` is what a UI draws.

**And `dryRun: true` on any mutation returns that same envelope without writing.** The quick bar preview already does this by hand — it runs the real transform against a copy and diffs — which is why the preview can't disagree with the write. Promoting it into the contract makes that property available to every surface: Raycast can show a change before committing it, and a model can check its own reference before acting.

## Errors are typed

Today: `PmError`, exit 1, prose on stderr. Published instead as a code, a message, and structured data:

```
projectNotFound    ambiguousProject (with candidates)   notesNotFound
staleReference     conflict                             invalidDue
emptyText          configNotFound                       unsupportedAction
```

`ambiguousProject` carrying its candidates is what lets a model disambiguate in one round trip instead of failing. `staleReference` is defined in [task-identity.md](task-identity.md).

## Vocabulary collisions to settle first

These are tolerable in a menu, where context disambiguates. They are a real failure mode when they become tool names a model picks between.

| Word | Means | Proposed |
|---|---|---|
| `undo` | reopen a completed task (`undoTodo`) | `task.reopen` |
| `undo` | the app's document undo stack (`PMStore.undo`) | `history.undo` |
| `focus` | which project is current | `project.focus` |
| `focus` | which task is "now" | `task.focus` |
| `add` / `narrow` / `dive in` | three verbs, overlapping meanings | keep all three, define each in the manifest description |

The App Intents names are already user-facing English and mostly right; where the CLI and the quick bar disagree with them, the Intents spelling wins and the others become aliases.

## Transport, and why not a daemon

Stateless, one process per call, no long-lived server.

The notes file is markdown that the user also edits in Obsidian and by hand. No process can claim ownership of it, so a serving daemon would be asserting something untrue about the world. Statelessness plus per-task digests is the honest model. If streaming is ever wanted, it's `pm api watch` emitting NDJSON — not a daemon holding state.

## What has to give

- **Raycast's re-derived domain logic gets deleted** — `getEffectiveDue`, `getNextDueForProject`, `stripInlineDueFromText`, `formatSessionDate`. These become fields on the contract's payloads.
- **Display strings move into the contract.** Payloads carry both `due: "2026-09-01"` and `dueDisplay: "in 2w"`, computed with a caller-supplied `now`. This is the one place the design deliberately mixes data and presentation, and it's the trade recorded below.
- **The config-dir files get schema'd** and read through the contract (`focus.get`, `project.list`) rather than by three separate JSON parsers.
- **`pm notes write`'s whole-document path** stays internal. It falls back to a full re-serialize that drops frontmatter, so it should never be a published action.

## What is built

`performApi(action, input, options)` in `Sources/PmLib/Api/`, with `pm api describe` and `pm api call <action> <json> [--dry-run]` over it. 35 actions: 22 mutations, 8 queries, 5 affordances that are listed and refused.

Three decisions worth recording, because they are what makes the rest hold together.

**The document pipeline composes the pure transforms, not the service layer.** `NotesService` reads, mutates and writes in one step, which is right for a caller that wants the write. The dispatcher needs the middle of that sandwich alone, so it reads once, applies a `String -> String` transform from `NotesRawEdit`/`NotesTodos`, diffs, and writes unless `dryRun`. That is why a dry run is the same code path minus its last step rather than a prediction of it — the property the panel's preview already relies on, now available to every surface.

**Validation reads the same table the schema is published from.** `ApiRegistry.actions` describes each action's fields once; `inputSchema` renders it as JSON Schema and `validate` checks against it. A test asserts the two agree for every action — that the published `required` list is exactly what a call with empty input complains about. A schema maintained beside the check it describes is a schema that eventually disagrees with it.

**The summary is derived from the diff.** No action describes its own effects, so completing a task reports the subtree it took with it and where focus went, because that is what the before/after comparison shows. Summaries carry both tenses: a dry run has to say what *would* happen, and English won't let you derive "Would complete" from "Completed" by lowercasing it. An action with nothing to do returns a statement instead, which has no future tense to take.

### The MCP adapter

`pm mcp` speaks JSON-RPC over stdio. It lives in the `pm` binary rather than an npm package, so wiring it up is one line against a command the user already has, with no second runtime to install and nothing to keep at the same version as the first:

```json
{ "command": "pm", "args": ["mcp", "--allow-write"] }
```

Its tool list is generated from `ApiRegistry` at startup, so a tool cannot describe itself differently from the action it calls — there is only one description. Three things it adds on the way out:

**Tool names replace dots with underscores.** `task.complete` becomes `task_complete`. MCP tool names are conventionally `[a-zA-Z0-9_-]` and clients reject what falls outside it. The mapping is total in both directions because an action name is dotted lowercase and never contains an underscore of its own.

**A task reference must carry its digest.** The contract leaves it optional — a human typing indices at a terminal is asserting nothing — but a model is exactly the caller that reads a list, thinks, and acts later. The generated schema marks it required *and* the adapter enforces it, because publishing a requirement and not checking it leaves the promise to whichever client happens to validate.

**Every mutation gains `dryRun`.** The envelope it returns is identical to the write's, so a model can see what it is about to do and then decide.

Scopes answer the third open question below: queries are always available, `--allow-write` adds the actions that change a project, and `--allow-destructive` adds the ones that lose something — `task.delete`, `session.delete`, `project.archive`, `config.set`. A tool that is withheld says so when called, rather than pretending not to exist, so a model can tell "you may not" from "no such thing" and report the difference to the user.

Failures come back as content with `isError` rather than a JSON-RPC error, since the call reached the tool and the tool refused — something the model should act on, not a transport fault. The message leads with the error code, because `staleReference` means read again and retry, which is a different move from a project that doesn't exist.

## Still to build

- **The in-process adapter**, so the panel and App Intents call the dispatcher instead of `NotesService`. This is where the `PMStore` boundary question below gets answered.
- **The Raycast client**, generated or hand-written against the manifest, replacing its own spawn-and-parse.
- **`capture.parse` and `task.search`**, which live in the app (`QuickCaptureParser`, `TaskSearch`) and would have to move into PmLib to be published.
- **Bulk operations and the document revision.** `revision` is in the envelope and nothing consumes it yet; `toggleAll`, `setDueAll` and subtree deletes are the actions that need it.
- **The mutation journal.**

## Open questions

**1. Display strings in the contract, or per-surface formatting?** Carrying them kills the `RelativeDue` / `format-relative-due` duplication, at the cost of a data contract that knows about words and needs `now` as an input. Recommendation: carry them. "in 2w" is domain vocabulary in this app — it is the same phrasing `QuickCaptureParser` reads *back*.

**2. How much of `PMStore` moves?** The mutations clearly do. Undo/redo, the focus-move classifier and the project index are app concerns and should stay. The boundary needs drawing before any code moves.

**3. Does the MCP get write access by default?** *Settled:* no. Queries are unrestricted, `--allow-write` permits mutations, `--allow-destructive` permits the four that lose something. Still unpaired with a mutation journal, so a model's writes can be seen in the envelope it returns but not reviewed afterwards.

**4. Where does the mutation journal live?** `~/.config/pm/journal.ndjson`, appended by the dispatcher, before/after digests per entry. It closes a real hole — undo is currently in-memory and app-only, so nothing can reverse a write made by Raycast, the CLI, or a model. Retrofitting it later means the journal starts with gaps.
