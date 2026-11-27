# Stale tasks: fold them, then catch up

**Status:** built 2026-11-27. Not yet run on a Mac.

## The problem

A task doesn't age on its own. Its age is the date of the sitting it was written in, and nothing else
about it changes until you touch it. A project card's Current and Tasks draw every open task from every
older sitting in one **Still open** group ([sessions.md](sessions.md) D5), with no limit. The dock's card
and the menubar read the same pile. So a project you haven't sat down to in a month opens with its
whole backlog at full weight, and that is what makes coming back to it hard.

Drop ([sessions.md](sessions.md) D6) was the answer to "how do I let a task go", and Leftovers
([views.md](views.md)) to "what have I left open, everywhere". Neither helps at the moment of coming
back: Drop is a selection you have to make, and Leftovers is a list you have to go and look at.

## Decisions

### D1 — Stale means untouched for three weeks

A tree is **stale** when every open line in it is open, undated, not focused, and untouched for 21 days
(`taskStaleAfter`). Touched is what PM already records, and nothing is stamped onto task lines:

- **written**: the day of its sitting, counted from the end of that day;
- **picked up**: its tree's latest pick (`Todo.picked`), which focusing, ticking, editing or setting a
  date on an old task also writes;
- **kept**: its tree's latest keep (`Todo.kept`, D3).

Whichever is latest. A dated task isn't stale: its date already says when it matters, and Coming up
shows it. Waiting tasks can be stale: three weeks waiting on someone is worth a look. A task under a
heading PM can't date is never stale.

The rule is `TaskStaleness` in PmLib. It isn't a field on reads: every read already carries
`sessionISODate`, `picked` and `kept`, so any surface can apply it.

Three weeks keeps the week before last in plain sight and folds last month. It's a constant, not a
setting, until a reason to change it turns up.

### D2 — Fold stale work on the surfaces you glance at

- **A project card's pile** (Current and Tasks) draws fresh
  rows as before, then one quiet line at its foot: "14 older tasks, untouched for 3+ weeks", with
  **Catch Up…** beside it. Clicking the count shows the stale trees under it; clicking again folds them.
  A find unfolds everything, since it is looking for something.
- **The dock's card** is the same card, so it folds the same way. Its cap of 5 counts fresh rows only.
- **The menubar** leaves stale tasks out of its list and adds **Catch Up on N Older Tasks…**.
- **The keyboard** doesn't walk onto folded rows.

Nothing is written by folding. The notes and the logs are exactly as they were.

### D3 — Keep is a new event in the pick log, not a pick

A review needs a "yes, but not now" answer that makes a task fresh without saying you worked on it.
Picking it up would say that, and would fill today's **Picked up** with a list of things you only
looked at. So `.pm-picked.ndjson` gains a `kept` event: the task (as a pick names it, by its tree's
root), when, and no `into`. A `released` naming it in `reverses` cancels it, and reversing that release
keeps the task again, so undo and redo work as they do for picks. Reads carry `kept` on every line of a
kept tree, the way they carry `picked`.

`task.keep` (contract 1.25.0) takes `task` or `tasks`, writes the events, and changes nothing in the
notes. It is journaled, so `journal.undo` takes it back from any surface.

### D4 — Catch Up goes through stale trees one at a time

Catch Up is a small window (`StaleReviewWindowController`) over one project. It takes the trees that
were stale when it opened, the longest-forgotten first, and shows each with the date of its sitting, its
last pick-up or keep, its open subtasks, and the sentence it was written beside. It asks one question:
still meant?

- **Keep** (Return): `task.keep`. Fresh for another three weeks.
- **Pick Up** (P): the ordinary pick into the current sitting.
- **Drop** (D): the ordinary drop, open subtasks with it.
- **Skip** (→): nothing written; it stays stale.
- **Back** (←): asks the previous one again. Its answer stays written until ⌘Z in the project.
- **Drop the Rest…**: drops every tree not yet answered, as one step, after a confirmation.

Each answer is the store's own verb, so each is one ⌘Z step in the project. The window holds its
project's store until it closes, so answers land however the card that offered it went away.

Catch Up opens from the fold line, the menubar, and a Projects card row's menu (**Catch Up on …**),
which is where a quiet project is noticed.

## Not in this pass

- **Leftovers doesn't fold.** It is the list you go to *for* old work, so hiding it there would be
  backwards. It could mark stale rows, or offer Catch Up per project.
- **Catch Up across projects.** One project at a time for now. A cross-project review would walk
  `task.leftovers` the same way.
- **Raycast and the CLI** get `task.keep` and `kept` through the contract, but no fold or review of their
  own yet.
