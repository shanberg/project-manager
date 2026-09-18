# Sessions and the work they leave open

**Status:** decided 2026-09-17. D6, dropped, the pick log with its contract, and the drawing (build order steps 1–3) built 2026-09-17; the app draws picks but can't make one yet (that's step 4). Follows [tile-sessions.md](tile-sessions.md), which fixed how a
card *enters* a session; this is about what a session *is*, and what happens to the work in the old ones.

## The problem

A session is doing two jobs. It is a **journal entry** — when you sat down, what you were thinking — and
it is **the only place a task can live**. So a task's home is fixed by the day it was written, and every
way of relating it to today costs something:

- **Moving it** into today's session (dragging it across a caption) keeps it current and strips it of
  the sentence that explains it. The prose it was written inside stays behind in a sitting that now
  reads as if the task never happened.
- **Leaving it** keeps its context and makes it invisible to today. Nothing about the current sitting
  says you picked it back up, and nothing about the old sitting says anyone did.
- **The Current preset** (`CanvasCardShows.current`) tries to do both — the latest prose, and open tasks
  from every sitting under their own captions. It holds for a project with two or three old sittings.
  At a dozen, each with one leftover task, it is twelve captions of noise around twelve tasks.

Underneath all three: a task's **origin** (where it was written, and why) and its **attention** (whether
you are working on it now) are one fact in the file, and they are two facts in your head.

A second gap sits beside it. An old task you have decided not to do has two exits, and both lie: tick it
(it wasn't done) or delete it (it was real, and the reasoning around it still mentions it). So old
sittings never close, and their leftovers are what fills the Current card.

## The model

**Tasks stay where they were written. Sessions gather what you worked on.**

A sitting's record is no longer only the lines under its heading. It is those lines, plus the older tasks
you **picked up** during it. Picking up doesn't move anything: the task stays at its origin, in its
sentence, and is *drawn* in the sitting that picked it up, carrying where it came from.

And a task can be **dropped**: closed, without being done.

## Decisions

### D1 — Tasks don't move between sessions by default

Dragging a task onto a different session **picks it up** into that session (D3) instead of moving the
line. Dragging within a session reorders, as now. **⌥-drag** still moves the line, for the rare case
where the task really belongs somewhere else — the same ⌥-means-the-stronger-sibling rule as ⌥ New
Session (tile-sessions D1). The drop indicator says which it will be: a gap between rows for a move, the
whole target session lit for a pick-up.

Picking up is only offered into the **current** sitting. Picking a task up into an old sitting would be
rewriting history, and that's what ⌥-drag is for.

### D2 — The record lives in a sidecar, beside the done log

`.pm-picked.ndjson` in each project folder, with the same properties
[done-report.md](done-report.md) argued for `.pm-done.ndjson`: append-only, per project (it travels with
renames and archiving, and syncs with the work), dot-prefixed so Obsidian and Finder ignore it, and
written under the same `flock` discipline. The notes stay prose. The price, accepted: Obsidian can't see
picks. The prose you write in today's session is still the place to say *why* you picked something up.

One event per line:

```json
{ "id": "…", "at": "2026-09-17T15:02:11Z", "event": "picked",
  "task":  { "session": "2026-09-02", "ordinal": 0, "digest": "3fa91c0e", "text": "Email Dana" },
  "into":  { "session": "2026-09-17", "ordinal": 1, "digest": "…" },
  "source": "app" }
```

- `task` is a `TaskRef`, `into` is a `SessionRef` ([task-identity.md](task-identity.md)). Both resolve
  with the usual three outcomes. A pick whose task or sitting has gone stale is **not drawn** rather than
  guessed at, and it is never an error. The log is a record of what happened, not a claim about the file.
- `released` cancels the latest `picked` of the same task into the same sitting, the way `reopened`
  cancels a completion. It carries `reverses: <id>`, so undo can name what it is taking back.
- `retargeted` (the task's old digest in `task`, the new one in `to`, and the ids of the picks it carries in
  `retargets`) is appended when `task.setText` edits a picked task, so a
  rename through PM keeps its pick. A rename made in Obsidian loses it: the pick goes stale and stops
  being drawn. That's the same price the done log pays for not hooking, and it's cheap here because
  picking again is one gesture.
- Never pruned. Entries are around 200 bytes.

A pick belongs to its sitting, like everything else in that sitting. A task picked up yesterday and
still open isn't in today's sitting unless it is picked up again. It shows in the open pile (D5), marked
as last picked up yesterday.

### D3 — Picking up: the gestures

| gesture | picks up into the current sitting |
|---|---|
| **Focus** — double-click a row, the row menu's Focus, the quick bar, the menubar | yes, when the task is from an older sitting (D4) |
| **Pick Up** — the row's contextual menu, and Task ▸ Pick Up | yes; on a selection it says the count: "Pick Up 3 Tasks" |
| drag onto the current sitting | yes (D1) |
| **Put Back** — contextual menu on a picked-up row | appends `released` |

The current sitting is `currentSessionPreservingFormat`'s answer, so picking up follows the same
join-or-start rule as every other write. Picking up into a cold project starts a sitting, and that
sitting's heading is written to the notes, the one change to the file a pick can make.

**Focus advancing on its own doesn't pick up.** When completing a task moves focus to the next leaf
(`selectNewCurrentAfterRemoval`) and that leaf is in an old sitting, it is focused and not picked up.
The app chose that task, and a pick is a record of what *you* chose. It gets picked up the moment you
act on it: focus it yourself, tick it, or edit it.

For the same reason, **ticking or editing an old task picks it up** first. Finishing something is the
clearest possible sign you worked on it in this sitting. This is also what lets a sitting show the old
things you finished in it.

Contract: `task.pick` and `task.release` (mutations; input is a task reference, plus an optional session
reference for `release`). `task.focus` gains `pick` (default `true`). Every task read gains `picked`:
`{ "into": "2026-09-17", "at": "…" }`, or absent, and a read lists every standing pick in `picks`.
Contract **1.12.0** has `task.pick`, `task.release` and `picked` (1.11.0 was `task.drop`); `task.focus`'s
`pick` arrives with the focus work in step 4, as **1.13.0**.

### D4 — Focus picks up, and undo takes it back as one step

Focus is navigation and stays off the undo stack (`PMStore.focus`, `recordsUndo: false`). A focus that
picks up has done something that isn't navigation, so it **goes on the stack**. That step is the whole
gesture, not half of it:

- **⌘Z** after a focus that picked up puts the focus marker back where it was **and** appends `released`.
  The Edit menu reads **Undo Pick Up**.
- **⌘⇧Z** re-applies both: the marker moves again and a new `picked` is appended. It's a new event, not
  a revival of the old one, because the log is append-only.
- A focus that didn't pick up (a task already in this sitting, or already picked up into it) stays
  navigation, as now, and costs no ⌘Z step.
- Pick Up, Put Back and a drag-to-pick are each one step. A tick that picked up is one step too: ⌘Z
  reopens the task and releases the pick, because the pick only happened as part of the tick.

To do that, `PMStore`'s stack changes from `[DocSnapshot]` to steps:

```swift
struct UndoStep {
    var document: DocSnapshot?     // bytes to restore, when the gesture changed the file
    var picks: [PickEvent]         // events to cancel (undo) or re-append (redo)
}
```

Undoing a step restores the document the way it does now, then appends the cancelling events.
**Document first, and all or nothing.** If restoring the document is refused (the file moved on under
it), the picks are left alone. Half an undo is worse than none.

**Across surfaces.** A focus from Raycast, `pm` or a model goes through `task.focus` and picks up just
the same, so the journal has to be able to reverse it. `JournalEntry` gains `sidecar`, the ids of the
events the write appended. Reversing an entry checks the document revision exactly as it does today, and
only if that passes appends the cancelling events. The same all-or-nothing rule applies. A pick with no
document change behind it (Pick Up on a task, into a sitting that already exists) has no revision to
check, and reversing it is always safe, because a `released` can only cancel the pick it names.

**Things undo deliberately leaves alone.** Undoing an edit that happens to delete a picked task doesn't
touch the log. The pick goes stale and stops being drawn, and redoing the edit's reversal brings it
back. Undoing a completion (the menubar's ⌥ Undo, `undoLast`) reopens the task and leaves its pick. You
did pick it up, you just didn't finish it.

### D5 — What a card draws

**A session** draws, in order: its prose, the tasks written in it, then **Picked up** — the older tasks
picked up into it, each with a quiet origin chip ("Sep 2"). Hovering the chip shows the sentence the
task was written in. Clicking it scrolls to the origin. Ticking a picked-up row ticks the origin line.
It's one task drawn in two places, and both places show its state.

**An old session** marks a task that has been picked up since, with a trailing "picked up Sep 17" in the
tertiary style the captions use. That way the old sitting says what became of its leftovers instead of
looking abandoned.

**Current** becomes *today and the pile*:

1. the current sitting's prose, its own tasks, and what it picked up;
2. **Still open**: every other open task in one group, not under per-session captions, each carrying
   its origin chip and, if it has one, its last pick-up. Newest origin first.

That's one caption in place of a dozen, and every leftover still one glance away from its context.
**Everything** is unchanged apart from the chips and the Picked up groups. **Tasks** draws the same
Still open group, with nothing above it, and without its caption, since it's the only thing on the card.

As built: a picked-up row and its own line are one task to the selection and the context menu, and two
rows to hover and inline editors, so an editor opens where you asked for it. Only the task's own line
can be dragged; dragging an old task onto today is D1, which comes with the drags. Clicking a chip whose
task has no line drawn on the card (Current's picked-up rows) opens the origin sitting's note.

### D6 — Dropped

A task can be **dropped**: closed without being done. It's written `- [-]`, the spelling the Obsidian
Tasks plugin uses for "cancelled", so the file reads correctly in a vault that has it. In one that
doesn't, Obsidian's own renderer treats any character in the box as checked. That's the right
approximation, and it should be confirmed against a stock vault while this is built.

- **Parsing.** Today `[-]` doesn't match the task pattern (`\[([ xX])\]`, in `NotesTodos.swift` and
  `NotesRawEdit.swift`), so a `- [-]` line is *prose*. Both patterns widen to `[ xX-]`, and `Todo` gains a
  `state` (`open`, `done`, `dropped`). `checked` stays, meaning **closed** (done or dropped), so every
  consumer that hides checked tasks hides dropped ones without changing: Raycast, the menubar,
  `task.whatsDue`, focus advancement, the Waiting list. An existing `- [-]` line in someone's notes
  becomes a dropped task, which is what it meant.
- **Contract.** `task.drop` (a mutation). Like `task.complete`, it takes open descendants with it and
  advances focus. `task.reopen` reopens either kind of closed task. Reads carry `state`. `task.progress`
  counts dropped tasks as *resolved*, not as done: a project whose leftovers you let go of is finished,
  and its progress bar should say so.
- **The done log.** The baseline goes from `[open, checked]` to `[open, done, dropped]`. An old
  two-element entry reads as zero dropped, so no migration is needed. A drop is logged as `dropped`. `pm
  done` and `task.done` leave dropped tasks out: the report is what got done. `--dropped` puts them back
  in, marked.
- **Drawing.** Struck through and tertiary, never green. The *open* scopes hide dropped tasks the way
  they hide done ones.
- **The command** is **Drop Task** (Task menu, and the row's contextual menu; on a selection, "Drop 3
  Tasks"). The name collides with drag-and-drop in an app full of drags. OmniFocus uses the same word
  for the same idea, and on a Task menu it's unambiguous, so it stays. The code says `dropped`, never
  `cancelled`.

Closing out an old sitting is then a selection away: select its leftovers and Drop them, or Pick Up the
one you still mean to do. That's the selection-and-contextual-menu pattern the app uses for every bulk
action, with no per-session "close out" button.

## Areas

Areas have sessions too, and picking up matters more there. A 1:1's action items are written in one
meeting and done in another. Nothing here distinguishes the two kinds of thing. Everything applies to
both.

## Build order

Each step ships on its own and leaves the app coherent.

1. **Dropped (D6).** Self-contained: the parser, `state`, `task.drop`, the done-log baseline, drawing, the
   command. `PmLib` tests for the tri-state round trip and the baseline upgrade.
2. **The pick log and contract (D2, D3's actions).** `PickLog` beside `DoneLog`, `task.pick` /
   `task.release`, `picked` on reads, `retargeted` on `setText`. Tests: resolve through a spliced-in
   sitting, a release cancelling only its own pick, a stale pick dropping out quietly.
3. **Drawing (D5).** Picked up groups, origin chips, "picked up" marks on old sittings, the new Current.
4. **Focus and undo (D3, D4).** Focus, tick and edit pick up; `UndoStep`; the journal's `sidecar`. The
   undo cases in D4 are each a `PMStore` test (it is already under test). The journal's
   refuse-the-whole-thing case is a `PmLib` test.
5. **Drags (D1).** A drop across sessions becomes a pick-up, and ⌥-drag moves. `TaskDropResolver` gains
   the whole-session target. Its geometry is pure and tested already, so this is an extension of that.

## Not in this pass

- **A day across projects.** "What did I sit down to today, everywhere" is the other half of relating
  old work to today, and the pick log together with the done log is exactly the data it needs. It's a
  view with nothing to decide about the model, so it waits until the model is built.
- **A sitting that runs past midnight** still becomes two, because `currentSessionPreservingFormat`
  considers only today's heading (tile-sessions.md). It's a small change to the same rule, and it's left
  for its own change so this one doesn't also move where writes land.
