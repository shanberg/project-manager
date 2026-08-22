# Task identity across surfaces

**Status:** implemented in PmLib, the `pm` CLI, and the Raycast extension, 2026-08-22. `TaskRef.swift` is the implementation and `TaskRefTests.swift` the tests; this page is the reasoning behind them. The panel is unconverted on purpose — see below. This settles how a task is addressed before the shared API contract (UI / Raycast / MCP) is built on top of it — see [api-contract.md](api-contract.md).

## What identity is today

A task is addressed by its **position**: `sessionIndex:lineIndex`.

- `sessionIndex` is the task's session's index in `notes.sessions`.
- `lineIndex` is the task's ordinal **among task lines** in that session's body — blank lines and prose don't count.

Both are assigned by `parseTodos` (`pm-swift/Sources/PmLib/NotesTodos.swift`), and `spliceTaskLines` walks the raw markdown the same way to write back, which is what makes format-preserving edits possible. The pair shows up as `focusedKey` in `NotesShowOutput`, as `PMStore.focusedKey` and `lastCompletedKey`, inside `TaskEntity.id`, and as the two positional arguments to every `pm notes todo …` subcommand.

Positional identity is correct when the reader and the writer are the same process and the gap between them is one runloop turn. That describes the Mac app, which reloads after every mutation. It stops being correct as soon as a reader is *slow*: a Raycast list rendered minutes ago, or a model that reads a task list, thinks, and then acts.

## The defect this has today

`sessionAddPreservingFormat` (`pm-swift/Sources/PmLib/NotesRawEdit.swift:562`) inserts a new session **immediately after the `## Sessions` heading**. Sessions are newest-first, so today is always `sessionIndex 0`. And quick add creates today's session when it doesn't exist (`pm-swift/Sources/PmLib/NotesService.swift:270`).

So **the first capture of the day shifts every task in the document** from `(n, l)` to `(n+1, l)`.

That is not a theoretical race. Demonstrated against the real transforms:

```
BEFORE — as Raycast lists it at 09:00
  (0,0) Draft the summary
  (0,1) Email Dana about pricing
  (0,2) Pull last quarter's numbers
  (0,3) Review the contract        ← the row the user will click
  (0,4) Book the venue

AFTER — a session started and four things captured
  (0,0) Call the printer
  (0,1) Reply to Sam
  (0,2) Book travel
  (0,3) Check the invoice          ← what (0,3) means now
  (1,3) Review the contract        ← what the user meant
```

Clicking the stale row completes **"Check the invoice"**. No error, no warning; the write succeeds against a real task that the user never selected. When today's session has fewer tasks than the stale line index, the same call fails out of range instead — harmless, and the reason this hasn't been noticed.

## The design

### The reference

```
TaskRef = { project, session, sessionOrdinal = 0, line, digest }
```

Returned by every read, accepted by every write. `session` is an ISO date, not an index. `digest` is the first 8 hex characters of SHA-256 over the task's text, NFC-normalized.

### The session coordinate is a date

`sessionIndex` is not part of the reference. Sessions are newest-first and a new one is spliced in at the top, so the index of every existing session changes whenever a session starts — which is the defect above. A session's *date* doesn't move.

The reference carries an **ISO date** (`2026-08-22`). The heading on disk is a display format — `### Fri, Aug 22, 2026 planning`, written by `formatSessionDate` with the locale pinned to `en_US` and the timezone to UTC, so it is deterministic but not something a contract should be passing around. Both conversions already exist: `parseSessionDateArgument` reads ISO, `formatSessionDate` writes the heading form, and they round-trip.

`sessionOrdinal` disambiguates two sessions sharing a date, and is 0 in every ordinary case. Duplicates are reachable: the app's `openTodaySession` checks `todaySessionIndex` before creating one, but `pm notes session add` calls `sessionAddPreservingFormat` unconditionally, so running it twice in a day produces two `### Fri, Aug 22, 2026` headings — as does hand-editing the file. The parser keeps both as separate sessions, so the reference has to be able to name either.

**This changes the contract boundary only.** PmLib's transforms keep taking `sessionIndex`; resolution maps date and ordinal to an index at the edge and everything below is untouched. A session heading that doesn't match the parser's pattern is skipped rather than becoming a malformed session, so every session that exists has a well-formed date to key on.

### What gets hashed, and why it's the text

`TaskContent.split` already yields the right input: `Todo.text` is the line's content with the inline `due:` and the trailing ` @` focus marker removed and whitespace trimmed. Hashing the **raw line** instead would be useless, because focus moves on nearly every completion and would invalidate every reference in the document each time.

Hashing the text means the reference survives exactly the mutations that don't change what the task *is*:

| Mutation | Digest |
|---|---|
| Complete / reopen | holds |
| Focus moves onto or off it | holds |
| Set or clear a due date | holds |
| Wrap, unwrap, move subtree | holds — depth is deliberately not hashed |
| Tasks inserted or deleted above it | holds — position shifts, identity doesn't |
| A session started above it | holds — and with a date coordinate the position no longer moves either |
| **Rename** | **breaks — intended** |

Rename is the one case where the thing the caller was looking at genuinely became something else. A client that read "Review the contract" and asks to complete it must not complete "Review the contract with legal" because a human retitled it in the meantime.

### Resolving a reference

```
resolve(ref) →
  date + ordinal -> sessionIndex, or refuse if no such session
  HIT        the task at (session, line) carries that digest        → act
  RELOCATED  the digest appears exactly once elsewhere              → act there, report the move
  STALE      not found, or found more than once                     → refuse
```

`RELOCATED` is what makes this more than a checksum. References repair themselves against ordinary drift rather than erroring on it, so a list from ten minutes ago stays clickable after three tasks have been added above it. The relocation is reported in the result envelope so it is visible rather than magic.

"Found more than once" refuses on purpose. Duplicate task text is normal — "Follow up" twice in one project — and once the position check has already failed, any healing is a guess. The error carries the candidates, what is actually at the requested position, and the document's current revision, so a client can recover in one round trip. A cleverer version could disambiguate by neighbouring tasks; it isn't worth building until something needs it.

### Optional in the schema, required for MCP

The digest is optional. Omitting it means "I'm not asserting anything, just do it", which keeps `pm notes todo complete W-1 0 3` usable by a human at a terminal and makes the whole change additive to the CLI.

The MCP adapter's generated schema marks it **required**. A model is precisely the caller that reads slowly, acts later, and has no eyes on the file. Same dispatcher, stricter published schema.

### Why not a document-level etag

Because Obsidian edits this file, and so does the user by hand. Under strict document-level optimistic concurrency every write would fail whenever anything else touched the file, which here is constant and legitimate. Per-task digests put the check at the granularity where conflicts actually matter: this task, not this document.

Document revision (mtime + content hash) still has one job — **bulk operations**. `toggleAll`, `setDueAll`, and subtree deletes need to know the *children* haven't changed, which a digest on the root doesn't attest. Those take an optional `revision` and check it. Single-task operations don't.

### Cost

Around 200 tasks per project, SHA-256 over short strings; microseconds, and about 1.6 KB added to a `notes show` payload.

### What it enables

- **Dry run** resolves references too, so previewing a stale reference shows the staleness instead of a confident wrong diff.
- **The mutation journal** gets before/after digests per entry at no extra cost, which is what would make cross-surface undo safe — undo can verify the world hasn't moved before reversing.

## What has to migrate

Almost nothing, because task references are barely persisted.

- `focused.json` holds `{"projectKey": "<basePath>:<name>"}` — a *project*, not a task. Which task is focused lives in the markdown itself, as the single ` @` marker, and `focusedKey` is recomputed from it on every read. Nothing to migrate.
- `task-timing.json` is the only file on disk carrying a task position: `{"task_key": "<notesPath>::0:2", …}`, the record of when the focused task was first seen. It drives the menubar's stale tint and the stale-task notification. A key it doesn't recognise resets the clock, which is what already happens whenever focus moves, so it can change format without a migration step.
- `PMStore.focusedKey`, `lastCompletedKey`, and the `"si:li"` strings in the quick bar are per-launch and in memory. They change where they cross the contract boundary and nowhere else.
- `TaskEntity.id` is `"<sessionIndex>:<lineIndex>\u{1F}<projectKey>"`, handed to Siri and Shortcuts. Existing saved shortcuts holding an old id would resolve to a stale reference and refuse, which is the correct behaviour and the one place a user could notice the change.

## What is deliberately not converted

- **The panel.** It links PmLib in-process and re-reads after every write, so its positions are never more than a runloop old. It goes on calling the positional overloads, which build a digest-less reference and behave exactly as before.
- **`moveSubtree`.** Drag-reorder inside the panel, with no slow caller. It still takes raw positions.
- **Bulk operations** (`toggleAll`, `setDueAll`, subtree deletes). A digest on one task doesn't attest that its children are unchanged; those want a document revision, which belongs with the contract work.

## Open question

**Silent healing, or visible relocation?** Currently the CLI writes a `note:` line to stderr when a reference relocated, and the write proceeds. That's the cheapest thing that isn't silent. Whether a surface should show it — and whether relocation should instead be a field in a structured result — is a question for the contract's result envelope.

## Verification

Both the defect and the design were checked by running the real PmLib transforms — `sessionAddPreservingFormat`, `appendTaskToSession`, `insertTaskRelative`, `completeTodoWithDescendants`, `applyFocusToTodoAt`, `setDueOnTodoAt`, `setTextOnTodoAt` — against fixtures and diffing, with resolution implemented exactly as specified above. 13/13 checks passed, covering: the ISO/heading round trip; a date-based reference resolving as a clean `HIT` through the session shift that sends the index-based one to a different real task; an insert within the session forcing a `RELOCATED`; two sessions created on one date via the CLI path; and refusal on both a rename and a date with no session. Digest stability was confirmed separately across completion, focus moving, and due dates being set and cleared.

The harness is scratch. It should become a test in `pm-swift/Tests/pmTests` when this is implemented.
