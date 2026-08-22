# A shared contract for PM's surfaces

**Status:** the dispatcher, the manifest, all four adapters, and the mutation journal are built, 2026-08-22. `Sources/PmLib/Api/` is the implementation, `pm api describe` and `pm api call` the surface, `ApiTests.swift` the tests. What remains is listed under *Still to build*. Task identity is settled separately in [task-identity.md](task-identity.md), which this depends on.

## The problem

PM's domain is implemented once, in PmLib, and then spoken about in five different dialects.

| Surface | Reaches the domain by | Adds |
|---|---|---|
| `pm` CLI | argv → `NotesService` | JSON only from `notes show`; everything else is prose and an exit code |
| Raycast | `pm api call`, types generated from the manifest | nothing — the re-implemented logic is gone |
| Mac app | `PMContract` → the dispatcher, in-process | undo/redo, focus animation, project index, recents |
| App Intents | `PMContract` → the dispatcher, in-process | entities with stable ids, disambiguation |
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

`capture.parse` and `task.search` moved out of the macOS app into PmLib to be published. `capture.parse` reads a line the way the quick bar does — `due:friday`, `due:in 2w`, a trailing `@project` — so every surface accepts the same phrasing. `task.search` ranks on whole words rather than the subsequence matching that finds projects, because you remember a task as some of the words in it.

Both brought their vocabulary with them. The due-date presets — "Today", "This Weekend", "Next Week" — are now `PmLib.duePresets`, read by the parser *and* offered by the app's due menu, so the words a menu shows and the words a typed line is matched against cannot drift apart. `TaskSearch` ranks anything conforming to `SearchableTask`, so the app's warmed index and a fresh scan share one ranking; the app keeps its index, and the CLI and MCP pay one scan rather than maintaining one.

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

- **Raycast's re-derived domain logic gets deleted.** *Done.* `getEffectiveDue` reads the field the contract computes. `formatSessionDate` is gone: `session.start` is idempotent and reports the session it found or made, so nothing has to format today's date to look for it. `stripInlineDueFromText` is gone too — every call site passed it `todo.text`, which the parser has already stripped, so it was doing nothing. `getNextDueForProject` remains, a fold over `getEffectiveDue` rather than a second derivation.
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

### The Raycast client

Two files and a generator. `scripts/generate-api-types.mjs` reads `pm api describe` and writes `src/lib/pm-api.generated.ts` — an input type per action, a `Record` of tiers, and the contract version. `src/lib/pm-api.ts` is the transport and the envelope. `notes-api.ts` keeps its exported shape, so no command file changed, but every function in it is now one action name instead of a composition of `pm notes todo …` flags.

The generated file is committed, because `ray build` doesn't run codegen. What keeps it honest is a test that regenerates from whatever `pm` is installed and compares — so an action added to the contract and not regenerated here fails on the next test run rather than when something finally calls it. It skips when `pm` isn't on PATH, so the extension's tests still run without it.

What actually went away:

- **`getEffectiveDue`** walked the ancestor chain in TypeScript. It reads `effectiveDueDate` now — the field `todosWithEffectiveDueDates` already computes.
- **`todoAddress`** composed session/line/digest into CLI flags. Tasks are named by a `TaskRef` object.
- **The insert arithmetic.** `insertTodoViaCli` predicted where a new task would land (`anchorLine + 1`, with a comment explaining that `before` inserts into the anchor's own slot). The envelope reports the added task's reference, so the task is *found* by digest rather than calculated.
- **The whole-document write.** `writeNotes` sent the entire `ProjectNotes` to `pm notes write`, which falls back to a full re-serialize when it can't splice, dropping frontmatter. It diffs against what's on disk and sends one `notes.setDetail` per changed section; a change to something the contract can't set raises rather than silently not saving.
- **`Done: <task>`** as a HUD string. Completion shows the envelope's `summary`, which knows about the subtree that went with it and where focus landed.

There are seven integration tests that run the client against the real binary rather than a mock of it, because the unit tests only prove the extension is consistent with what it believes the wire format to be.

### The in-process adapter

`PMContract` in the app. Native types, no JSON, no subprocess — the panel redraws at 60fps and can't afford a process spawn per keystroke, which is why the contract was built so it doesn't have to.

It is the only adapter that can serve all three tiers. Mutations and queries go to `performApi` like everywhere else; affordances — `app.openWindow`, `app.openInFinder`, `app.openInObsidian`, `app.showPanel`, `app.settings` — are performed here, under the same names the manifest publishes and the headless adapters refuse.

**The reason to route the app's own writes through it isn't tidiness.** `PMStore` holds the tasks from its last read, and the notes file is markdown the user also edits in Obsidian and by hand. A click acts on what was on screen, which may not be what's on disk any more — the same defect Raycast had, with a shorter window. Every write now carries the task's digest, so that case is caught rather than written through. A refusal is turned into "That task changed on disk, so nothing was written. Reloading." rather than surfacing a raw error, because a race isn't a bug and shouldn't read like one.

App Intents carry the reference too. The digest is deliberately *not* folded into `TaskEntity.id`: Shortcuts persists the id and re-resolves through the query, so a digest baked in would make a saved shortcut fail to resolve rather than refuse clearly — and the current id format is one saved shortcuts already hold.

### What the app keeps

The boundary the second open question asked about. `PMStore` stays responsible for undo/redo, the focus-move classifier, the project index, recents, and its own phrasing — the quick bar's receipts are tuned to a narrow non-activating panel (truncated at 44 characters, withheld entirely for commands whose whole effect is a window opening), and the envelope's `summary` is written for a HUD with room. The contract supplies the sentence; a surface is still free to write its own.

Three mutations stay on `NotesService`, each because the contract has no action for them: `moveSubtree` (the panel's drag-reorder — two references, a side and a depth, resolved from a drop's coordinates), `setSessionNote` (sets a session's prose at an index; the contract only appends to today's), and `addTaskToSession` (appends to a named session rather than today's).

### Batches, and the revision

`task.complete`, `task.reopen`, `task.setDue` and `task.delete` take either a `task` or a list of `tasks` — exactly one, which a `required` list can't express, so the registry gained a small `oneOf` and the published schema says so. A batch is one read, one write, one journal entry, and one step to undo: a selection a person acted on in a single gesture comes back in a single gesture.

Within a batch, references are resolved against the text **as it evolves**, and a reference that no longer names anything is skipped rather than failing the batch. That is what "act on this selection" has to mean: completing a parent completes its children, deleting one removes them, so a child that came along in the same selection has already been dealt with by the time its turn arrives.

Skipping is also the reason `revision` exists, and why the two arrived together. A digest says *this task is still the task I saw*; it says nothing about the tasks around it. `revision` says *this is still the document I read*, and with it a skipped reference can only be the batch's own doing rather than an edit someone else made. It is checked once in the document pipeline rather than per action, because it is the same claim whatever the action — and **every read of a document now reports its revision**, since a guard a write can ask for is only worth having if the read tells you what to ask about.

`revision` is optional. Without it a batch still works and still carries per-task digests; with it, the write happens only if nothing has moved. The panel doesn't send one yet — it re-reads after every write, so its window is small — which is the remaining gap, noted below.

### The mutation journal

`~/.config/pm/journal.ndjson`, appended by the dispatcher after every successful write, with the content it replaced kept alongside in `~/.config/pm/journal/`. Two actions read it: `journal.list` and `journal.undo`.

**Snapshots are named by the hash of their content**, so a document that passes through the same state twice is stored once — and an entry's `revisionBefore` is already the name of the file holding it. The journal keeps the last 200 entries and drops snapshots nothing points at.

**Every adapter names itself.** `ApiOptions.source` is set by each — `cli`, `mcp`, `app`, `raycast` (via `pm api call --source`) — so "what did the model change?" is a question with an answer rather than an inference.

**Reversing is guarded by the revision.** An entry records the revision it produced; `journal.undo` reverses it only if the file is still exactly that. Anything else returns `conflict`, because reversing then would silently discard whatever was written since — including a line typed into Obsidian a minute ago.

**Undo walks back rather than oscillating.** A reversal is a write and is journaled as one, which is what makes it reversible in turn — but it is skipped when choosing what to undo next, as is anything already reversed. Undoing repeatedly therefore steps back through the history, across surfaces, and it works because reversing a write leaves the file at exactly the revision the write before it produced, so the next entry back is once again reversible.

This closes the hole the panel's undo stack left: it is in memory and app-only, so nothing could reverse a write made by Raycast, by `pm`, by a model — or by the app itself after a relaunch.

For MCP, `journal.undo` is grouped with the destructive actions. It is recoverable, since the reversal is itself journaled, but undoing somebody's work is not something a model should reach for unasked.

## Still to build

- **The panel sending a revision.** Its reads go through `NotesService`, not the contract, so it has no revision to send with a batch. Routing its reads through `notes.get` would close that, at the cost of encoding and decoding a payload it currently gets as native types.

## Open questions

**1. Display strings in the contract, or per-surface formatting?** Carrying them kills the `RelativeDue` / `format-relative-due` duplication, at the cost of a data contract that knows about words and needs `now` as an input. Recommendation: carry them. "in 2w" is domain vocabulary in this app — it is the same phrasing `QuickCaptureParser` reads *back*.

**2. How much of `PMStore` moves?** *Settled:* the document mutations moved; undo/redo, the focus-move classifier, the index, recents and the app's own phrasing stayed. Three mutations the contract has no action for stayed too, listed above.

**3. Does the MCP get write access by default?** *Settled:* no. Queries are unrestricted, `--allow-write` permits mutations, `--allow-destructive` permits the four that lose something. Every call is journaled under the source `mcp`, so what a model did is reviewable with `journal.list` and reversible with `journal.undo` afterwards.

**4. Where does the mutation journal live?** *Settled:* `~/.config/pm/journal.ndjson`, with content-addressed snapshots beside it, described above.
