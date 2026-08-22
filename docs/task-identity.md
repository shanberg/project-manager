# Task identity across surfaces

**Status:** proposed, 2026-08-22. Nothing here is implemented yet. This settles how a task is addressed before the shared API contract (UI / Raycast / MCP) is built on top of it — see [api-contract.md](api-contract.md).

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
TaskRef = { project, session, line, digest }
```

Returned by every read, accepted by every write. `digest` is the first 8 hex characters of SHA-256 over the task's text, NFC-normalized.

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
| A session started above it | holds |
| **Rename** | **breaks — intended** |

Rename is the one case where the thing the caller was looking at genuinely became something else. A client that read "Review the contract" and asks to complete it must not complete "Review the contract with legal" because a human retitled it in the meantime.

### Resolving a reference

```
resolve(ref) →
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

## Open questions

**1. Should the session coordinate be the date rather than the index?**

Sessions are already keyed by date in practice — `addTodo` finds today's with `sessions.firstIndex(where: { $0.date == today })`. Dates don't renumber when a session is prepended, so using the date removes the dominant instability class outright instead of detecting it afterwards; digests would then only have to absorb inserts and deletes *within* a session.

Cost: it touches `focusedKey`, `TaskEntity.id`, `lastCompletedKey`, and the `"si:li"` strings threaded through the quick bar, and needs a migration for the `focused.json` already on disk. Wrinkle: two sessions can share a date (`### 2026-08-22 morning` / `### 2026-08-22 evening`); the code already resolves that by taking the first, so a date plus an ordinal-within-date — almost always 0 — matches existing behaviour.

**2. Silent healing, or visible relocation?** Recommendation: report it in the envelope and let each surface decide. The Mac app probably says nothing; MCP probably tells the model.

**3. Land the digest independently of the contract work?** It converts today's silent wrong-write into a clean error on its own, without any of the rest.

## Verification

The transcript above and the digest stability table were produced by running the real PmLib transforms — `sessionAddPreservingFormat`, `appendTaskToSession`, `completeTodoWithDescendants`, `applyFocusToTodoAt`, `setDueOnTodoAt`, `setTextOnTodoAt` — against a fixture and diffing. 12/12 checks passed. The harness is scratch, not in the repo; it should become a test in `pm-swift/Tests/pmTests` when this is implemented.
