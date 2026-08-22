# Task focus flow

This doc describes how the **focused task** (the single “now” task per project) is represented and how focus moves from task to task.

## Representation

- **In notes:** One task line in the project notes file ends with ` @` (space + `@`). No other task line has this suffix. The parser treats the first such line (by session order, then line order) as focused; any others are normalized away.
- **In code:** The focused task is the one with `isFocused: true` (parsed from that line). The CLI’s `notes show` output includes `focusedKey` (e.g. `"sessionIndex:lineIndex"`).

That `sessionIndex:lineIndex` pair is positional, and it is not stable across writes from another surface — see [task-identity.md](task-identity.md).

### Line format

A task line is `<indent>- [ ] <text> due: <date> @` — the inline `due:` comes **before** the focus marker, and the marker is always last. `TaskContent` (`pm-swift/Sources/PmLib/NotesTodos.swift`) is the single place that reads and writes this; it also accepts the reverse order (`<text> @ due: <date>`) so a line written by an older client still parses, and re-emits it canonically, repairing the line the next time the notes are edited.

Writing the tokens the other way round is what a raw `hasSuffix(" @")` check misses: the line still *displays* correctly (the parser strips the due first), but the next edit doesn’t see a focus marker and drops it. Every mutation therefore goes through `TaskContent.split` / `render` rather than trimming suffixes itself.

### Who writes task lines

Only the Swift layer. The panel calls `PmLib` in-process; the Raycast extension shells out to `pm notes todo <add|due|text|wrap|complete|undo|focus>`, which splices single lines and leaves the rest of the file byte-for-byte. `pm notes write` (whole-document JSON) is for the detail sections only — it falls back to a full re-serialize when sessions differ, which would drop frontmatter and anything else the model doesn’t capture.

## When focus advances (completing a task)

When you **complete the focused task** (Complete Focused Task, or marking the focused task done in the menubar / View Focused Project), the extension calls the CLI; the Swift layer **advances focus by default** and picks the **next** focused task using a fixed order of candidates. Use `--no-advance` to complete without advancing.

### Next-focus rule (“now-style”)

Within the **same session** as the completed task, candidates are considered in this order:

1. **Parent’s first leaf**  
   If the completed task has a parent (shallower depth), focus moves to the first leaf of that parent’s subtree (first descendant by document order, or the parent itself if it’s a leaf), excluding the task being completed and its descendants. We “dive in” again on the parent branch. Root-level tasks have no parent, so this step is skipped.

2. **Next sibling’s first leaf**  
   If there is a next sibling, focus moves to the first leaf of that sibling’s subtree (first descendant by document order, or the sibling if it’s a leaf).

3. **Parent**  
   If the completed task has a parent (shallower depth), focus moves to that parent.

From these candidates, any task that is being completed in the same operation (the task itself or its descendants) is excluded. Among the remaining candidates, the **first unchecked** task is chosen; if all are checked, the first candidate is used.

### Fallback

If no candidate is found from the rule above (e.g. no siblings or parent in that session), focus moves to the **first open (unchecked) leaf** that is not in the set of tasks being completed—possibly in another session.

### Edge cases

- **Single root task, complete it:** No siblings or parent → no next focus; focus is cleared (all done).
- **Only child, complete it:** Only candidate is parent → focus moves to parent.
- **First of three roots, complete it:** Next sibling’s first leaf → focus moves to next root (or its first leaf if it has children).

Implementation: `pm-swift/Sources/PmLib/NotesTodos.swift` → `selectNewCurrentAfterRemoval`, used by `completeTodoWithDescendants(..., advanceFocus: true)`. The Raycast extension invokes this via `completeAndAdvanceInNotes` → `pm notes todo complete <project> <session> <line>` (advance is default; use `--no-advance` to skip advancing).

## When focus is set manually

- **Dive In:** Moves focus to the first leaf under the current focused task, or to the first leaf in the tree if nothing is focused.
- **Clicking a task** in the Focused Project menubar or View Focused Project: focus moves to that task.
- **Set focus in notes:** Implemented by the CLI as `pm notes todo focus <project> <sessionIndex> <lineIndex>`. Both the panel and the Raycast extension call this; it moves the ` @` to the chosen task’s line and strips it from all others.

## When a new task gets focus

- **Add todo** (as child or at same level): the **new** task gets focus (and the previous focused task loses it).
- **Wrap task:** the **wrapped** (child) task keeps focus; the new parent does not.

## When there is no focus

- If there are open tasks but no line has ` @`, the Raycast `getNotes` path can **best-effort** set focus to the first open leaf and re-fetch, so the UI always has a “next” task. If that write fails, the current data is returned without focus.

## Undo

- **Undo complete:** The task is toggled back to unchecked and the focus marker ` @` is moved back onto that task’s line (one write). Implemented by the CLI as `pm notes todo undo <project> <sessionIndex> <lineIndex>`; both the panel and the Raycast extension use this command.

## Summary diagram (advance on complete)

```
Complete focused task (advance by default)
         │
         ▼
  Same session: get parent (if any), siblings, and parent
         │
         ├─► 1) Parent? → focus = parent's first leaf (else skip)
         ├─► 2) Next sibling?     → focus = its first leaf
         └─► 3) Parent?           → focus = parent
         │
         │   (exclude tasks being completed; prefer first unchecked)
         │
         ▼
  No candidate? → focus = first open leaf not in completed set (any session)
  No open tasks? → focus cleared
```
