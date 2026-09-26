# Views: cards that answer a question

**Status:** proposed 2026-09-18. Build steps 1 (start times), 2 (`session.list`, `pm day`), 3 (the Day card), 4 (acting from a row), 5 (Waiting and Search), 6 (Leftovers), 7 (Coming up, Projects, Copy as Text) and 9 (Time) are built. Follows [sessions.md](sessions.md), whose "Not in this
pass" left *a day across projects* waiting until the pick log existed. Generalises it: the day is the
first of a small set of cards that draw an answer rather than a document. Checked against a wider set of
goals (at the end) so that it isn't built only for the day. **Calendars** are decided (below); steps 1 (PmLib), 2 (the app) and 3 (the views) are built. An inbox was considered and decided against.

## The problem

Every card on a board today is a **thing**: a project's notes, a folder, a page, a picture, some text.
A project card is a lens on one document ([canvas-workspaces.md](canvas-workspaces.md) §6), and the
lens has got good — Current, Tasks, the Picked up groups, origin chips.

But the questions you actually sit down with don't have one document as their answer:

- *What did I do today?* Across four projects and a 1:1.
- *What have I left open?* Twelve old sittings, each with one leftover task, in nine projects.
- *What am I waiting on?* Answered already, in its own window ([links.md](links.md)).
- *What got done this week?* Answered already, in the CLI and nowhere you can see it
  ([done-report.md](done-report.md), "Not yet: a view in Folio").

PM already answers two of these through the contract, and each answer lives on a different surface:
a window, a CLI command, the menubar. The board, which is the place you work, can't hold any of
them. And the one question the sessions work set up, the day, has nowhere to go at all.

## The model

**A view is a card that draws the answer to one question about the backbone.** It is not a query
builder, and it is not a document. It's a named, designed answer with two settings, **which projects**
and **when**, and, for the views that are about time, a third: **how time is laid out** (D9).

Three rules keep that general without it turning into a query language:

1. **Every view is a contract query first.** The card is one adapter, the way the Waiting window is one
   adapter over `waitingBuckets`. So `pm`, Raycast and a model over MCP get every view as it's built,
   and nothing a card shows is the app's private opinion. *One question, every surface*, which is the
   rule [links.md](links.md) already keeps.
2. **Rows are the things themselves.** A task row carries a `TaskRef`, a sitting carries a
   `SessionRef`, a project carries its key. So anything a row shows can be acted on from the row, the
   way a folder card's rows can be opened and dragged off.
3. **One row vocabulary, drawn by the pieces the project card already has.** A task row, a sitting
   block, a caption and an origin chip are drawn by the same views that draw them on a project card,
   plus one addition: a **project chip**. A new view is a new query and a layout. It is never a new
   way to draw a task.

## Decisions

### D1 — A closed set of views, not a query builder

The same arithmetic that turned five flags into four presets (`CanvasCardShows`) applies here, harder.
A filter-and-group builder over tasks, sittings, dates, projects and states reaches hundreds of
renderings, and nobody designed any of them. The ask is for *well-designed* views, and a design is
an answer to a particular question.

Considered and passed over:

- **Obsidian's own query layer** (Bases, and the Dataview and Tasks plugins). They query *notes and
  their properties*, or *task lines with dates written on them*. A PM project is one note with
  sittings and tasks inside it, its dates are headings, and its history is in sidecars that Obsidian
  can't see. None of them could express "sittings today" at all. They would only fit if PM stamped
  dates onto task lines, and [done-report.md](done-report.md) has already argued against that.
- **Scriptable cards** (an HTML file on the board with the contract bridged in). This is the right
  escape hatch if the closed set turns out to be too small. It is wrong as the *first* answer, because
  its rows wouldn't be the same pieces, it wouldn't respect engagement, and it wouldn't join the undo
  stacks. It's under "Not in this pass" rather than rejected.

So the set, each view named by the question it answers:

| view | the question | query | exists? |
|---|---|---|---|
| **Day** | What did I sit down to? | `session.list` | new |
| **Leftovers** | What have I left open, and where did I write it? | `task.leftovers` | new, over existing data |
| **Coming up** | What's due, and when? | `task.whatsDue`, widened to a range | mostly |
| **Projects** | Which projects are moving, and which have gone quiet? | `project.list`, plus last activity | mostly |
| **Waiting** | What am I blocked on? | `task.waiting` | yes: the Waiting window's answer |
| **Search** | Where did I say *that*? | `task.search` | yes |
| **Time** | Where did the time go? | `time.spent` | new ([time-tracking.md](time-tracking.md)) |

**Day** and **Leftovers** are the pair that matters, for the same reason `current` and `tasks` were the
pair that mattered on a project card: one is *time*-scoped and one is *state*-scoped. Day is the
journal read across projects. Leftovers is the pile read across projects, and it's the view that makes
Drop useful at scale. **Coming up** is the deadline horizon, the only view about the future. **Projects**
is the portfolio: its rows are projects, not tasks, each showing when it was last worked on (its
newest sitting, or the notes file's last write), what's open and what's next due. That covers the weekly review's "what did nothing happen in?",
which no task list can answer because a neglected project has nothing new in it to list.
**Waiting** and **Search** are cheap because their queries exist. They're there
to prove that the card is general before a second new query is written.

A candidate that must earn its place: **Next** ("what could I pick up now?", the hero task per project
plus what's due). The menubar and the focus panel already answer it for the focused project. It gets
built if a board of six projects keeps asking it.

### D2 — Which projects, and when

**Projects** (`pmProjects` on the node):

- absent: **everything**, meaning active projects and areas, since a 1:1 is where a day's meetings
  live ([areas.md](areas.md));
- `board`: **the projects with a card on this board**. This is what a board of six projects wants,
  and it follows the board as cards come and go;
- a list of `[[links]]`: resolved the way [links.md](links.md) resolves them, leniently and invisible
  to renames. Naming a master includes its members, since a master already rolls its members up on
  its card ([combining-projects.md](combining-projects.md)).

One project is simply a list of one. A Day card on W-1's own board, set to This Week, is W-1's weekly
review. No second feature is needed for it.

**When** (`pmPeriod`): `today` (the default), `yesterday`, `week`, a date, or a range of dates. A
relative period **follows the clock**, so a Today card left on a board is today's tomorrow. A pinned
date makes it a page of the journal instead. Both are useful, and the difference is one menu item:
View ▸ Today / Yesterday / This Week / Choose Date…. Days are local and weeks follow the reader's first
weekday, as in `task.done`.

A period can also be **anchored to a sitting**: `since:[[Team 1:1s]]` means "since the last sitting
in Team 1:1s began". This is the 1:1-prep period: a Day or Leftovers card set to it shows everything
that has happened, across the chosen projects, since you last met. It costs nothing new, because the
sittings are already known. With calendars (below), the anchor could be an event as well as a
sitting.

Leftovers reads *when* as "older than". Its default is sittings before today, and before this week is
the weekly-review setting (as built: step 6). Waiting ignores it, and Search takes `pmQuery`.

The contract's field is `projects`, not `scope`: `task.done` already uses `scope` for
active/archive/all, and one word shouldn't mean two things in one manifest.

### D3 — Where a view lives: a text card, on the node

JSON Canvas has four node types, and a fifth is a bet on what Obsidian does with a type it doesn't know (unverified, and not worth finding out). So a view is
a **text node** carrying `pmView` (and `pmProjects`, `pmPeriod`, `pmQuery`), stored on the node in the
`.canvas` for the same reason `pmShows`, `pmZoom` and `pmAutoplay` are: it is something you *set*, and a
board opened in Obsidian carrying it is a feature.

The node's text is one line that PM writes when the card is made and never touches again, e.g.
*"Today, across projects: a Folio view."* That way Obsidian shows a card that says what it is,
rather than a blank rectangle.

PM does **not** write the answer into the node, or into the vault, so that Obsidian can see it. A
Today card rewriting the `.canvas` every time you tick something is churn in a file that syncs, noise
on the board's undo stack, and a second truth about the day that can disagree with the notes. The
notes stay the truth about *what is*, and the logs stay the record of *what happened*. A view is only
ever read from them.

An unknown `pmView` (a typo, or a view from a newer build) draws the node's text as an ordinary text
card, the same forgiving fallback `CanvasCardShows.parse` uses.

### D4 — Every sitting says when it began, in its heading

[sessions.md](sessions.md) said the pick log and the done log are "exactly the data" a day across
projects needs. They aren't, and the gap is the one that decides what the view looks like: **nothing
records when a sitting began.** A heading carries a date. Only the second and later sittings of a day
carry a time (`sessionTimeLabel`), so that a project worked on once a day never grows a decoration.
The notes file's modification time says only when it was *last* touched. So a day across four
projects can be grouped, but it can't be put in order.

**Measured, 2026-09-18** (spike step 1: a read-only script over the vault on the personal Mac, 14
days). There were 9 dated sittings in 5 projects, and **none could be given a start time**: no heading
carried one, and the done and pick logs had nothing in range, because both are days old. Even full,
those logs only record ticks and picks, and four of the nine sittings had no tick in them.

**Decided, 2026-09-18: every new sitting's heading carries the time it began.** That reverses
tile-sessions.md's "the first of a day carries no label". The decoration argument was about a heading
with no use for a time, and a day across projects is that use. It's also the simplest way to keep the
record: it sits in the file, it's true in Obsidian and on a second Mac, and it needs no sidecar. A
separate activity log (`.pm-activity.ndjson`, spans stamped on every write) was designed here first and
is set aside. See Not in this pass.

The heading keeps the time and a name apart, because today they're one field. The time *is* the label,
so naming a sitting (`session.rename`, `session.start`'s `label`) throws the time away:

```markdown
### Thu, Sep 18, 2026 9:10 AM
### Thu, Sep 18, 2026 9:10 AM · Week in review
### Thu, Sep 18, 2026 Week in review        ← an older named sitting: a name, no time
### Thu, Sep 18, 2026                        ← an older first sitting: no time
```

- **Parsed from the label, not by a new pattern.** The heading pattern already captures everything
  after the date. A label that opens with `h:mm AM/PM` has a time, and whatever follows ` · ` is its
  name. Every heading PM or a person has ever written still parses, and means what it meant.
- **Renaming changes the name and keeps the time.** Clearing the name leaves the time.
- **Local time**, as `sessionTimeLabel` already writes it: it names the moment you sat down, not a
  coordinate anything matches on. The date stays the matched part.
- **A sitting without a time** (everything written before this) is drawn under one "Earlier" mark on
  its day, in project order. It wears off within a day of use.

With start times in the file, the rest of the day follows from the logs PM already has:

- **Order**: by start time.
- **A completion or a pick belongs to** the latest sitting in its project that began before it, that
  day. Otherwise it goes under Also finished.
- **"Now"**: the project's newest sitting, when its notes were written within the idle window.

**Two findings from the same run, for D5 and D9.** Four of the nine sittings had no prose. They were
task lists started by capture, so a sitting with only tasks is drawn as its tasks, with no empty prose
slot. And prose is *sometimes* structured: some sittings open on `####` subheadings and bullets, and
some are plain sentences. So a sitting's one-line summary in Week is: its name, if it has one; else
its first subheading; else its first sentence. (The run also found fewer than one sitting a day. That
machine has only personal work, about a third of the pace of a work day, so it says nothing about
whether Day or Week carries more weight.)

### D5 — What Day draws

In order, down a time rail:

```
Today · Fri, Sep 18                          4 sittings · 7 done · 1 dropped
──────────────────────────────────────────────────────────────────────────
 9:10  ● Redesign
       Came back to the nav. Dana's reply settles the breakpoint question, so
       the spec can go ahead without the second round.
       ☑ Email Dana                                        Sep 2 · picked up
       ☐ Draft the nav spec
       ⊘ Second round of breakpoint review                        dropped
11:00  ● Team 1:1s
       Priya: …
 2:15  ● Folio                                                        now
       …
       Also finished   ☑ Renew passport · Home                 4:02 PM
```

- **A sitting** is the time it began, the project chip (its `pm-color` dot or icon, then its name),
  its prose **in full** and then its tasks. The prose is the journal, and a day is short enough to
  read whole. Its tasks are the ones written in it, those picked up into it (with their origin chip,
  as in sessions.md D5), and those finished or dropped in it. A task finished during a sitting counts
  as the sitting's even when it was written in another: the done log has the time, and D4 has the
  sitting.
- **The rail shows only when a sitting began**, which is what the heading records. There are no
  durations. A column of them would read as a timesheet, and PM isn't for time-tracking.

  *Amended 2026-09-22 by [time-tracking.md](time-tracking.md) D6.* Half of this was right and half of
  it was an overreach. The right half: nothing on the rail is ever **sized** by duration, and durations
  are **off by default**, because a column nobody asked for is exactly the timesheet this was refusing.
  The overreach: "PM isn't for time-tracking" ruled out answering *where did Tuesday go* when you go
  looking, which is a different thing from putting a number beside every sitting whether you want one
  or not. A sitting may now say how long it ran, under a setting, and `pm time` answers the question
  properly.
- **A sitting that is still going** says *now* (D4).
- **Also finished**: completions from the done log that fall in no sitting that day, such as a tick
  from the menubar, Raycast or Obsidian in a project you never sat down to. Each carries its project
  chip and time.
- **The summary line** counts sittings, done and dropped, separately, since sessions.md D6 decided
  dropped is not done. It's also the card's one line at board zoom (`CanvasDetail.simplifiedBelow`):
  *Today: 4 sittings, 7 done*.
- **An empty day** says so quietly, the way an empty session does (tile-sessions.md), and offers
  nothing. Starting work is done in a project, not here.

**Week** is the same card with days as captions, and each sitting drawn as its **lede**: the first
paragraph of its prose, plus its counts ("3 done · 1 picked up"). Seven days of full prose is a
document, not a view, and the lede is where you wrote what you sat down to do. Clicking a sitting
opens it (D6), and there you have all of it. This is done-report.md's "Not yet: session prose": the
week read back as more than a checklist.

**A sitting that ran past midnight** is drawn on the day its heading names. A completion after
midnight within the idle window of that sitting's last completion still belongs to it, so the evening's
work reads as one sitting. The file still gets a new heading for the next write, which is the problem
sessions.md deferred and this doesn't solve.

### D6 — A view is a place you work

[canvas-workspaces.md](canvas-workspaces.md) §2's rule holds: a card you have stepped into is where you
work, and engagement is the whole safety story. A view's rows act the way the same rows do on a project
card:

- **Tick, Drop, Pick Up, Put Back, Focus, edit.** Each goes to the row's project through
  `StoreRegistry`, acquired when you act and not held for every project in view. A Day across forty
  projects mustn't open forty stores to draw itself. The action is on that project's undo stack, and
  the board's `lastEditedProject` becomes that project, so ⌘Z takes it back through
  `CanvasUndoRoute`'s project route, as a tick on a project card does.
- **Clicking a sitting opens its note** in the card as a takeover (`SessionNoteTakeover`, keyed by its
  `SessionRef`, over that project's store). Back returns you to the view. It's the same piece, and it
  gets the undo stack of its own that the session note got in this week's undo fix.
- **Dragging a row or a sitting off a view makes a card** of it, as a folder card's rows do (D7).
- **Pick Up from Leftovers** picks the task into *its own* project's current sitting. There is no
  cross-project picking up. A pick belongs to a sitting, and a sitting belongs to a project.

The row's contextual menu is the project card's menu for that row, and it gains **Go to Project**.

### D7 — A sitting can be a card of its own

Dragging a sitting out of a view makes a project card that draws **one sitting**: a new lens,
`pmShows: "sitting"`, with `pmSitting` holding its `SessionRef` (not `pmSession`, which already names a web card's browser session). This is what an area wants most: last
week's 1:1 pinned beside this week's. A stale ref draws the project, the same fallback a lens with a
typo gets. It isn't a view, since it is one document. It's listed here because the drag is how it
comes to exist.

### D8 — The contract

| action | kind | fields | returns |
|---|---|---|---|
| `session.list` | query | `period`, `since`, `until`, `projects` | sittings dated in range, newest day first and in time order within a day: project, `SessionRef`, start time, prose, and tasks by role (`written`, `picked`, `finished`, `dropped`); plus `elsewhere`, the completions in no sitting |
| `task.leftovers` | query | `before`, `projects` | open tasks from sittings older than `before`, grouped by project and then by sitting, oldest first, each with its sitting's lede and its last pick-up |

Rows carry digests, so everything returned can be written back. Like `task.waiting`, both run their own
scan rather than reading `ProjectIndex`: this is a card someone put on a board on purpose. The scan is
kept cheap by a rule the logs make true. **A project whose notes and sidecars haven't been written
since the period began can't have anything in it**, so a Today view stats every project and parses
only the handful touched today. Like `task.done`, each query looks at the projects it reads first, so
an Obsidian edit an hour ago is in the answer.

`pm day [today|yesterday|week|DATE]` is the CLI's `pm done` with the prose kept in, and Raycast gets
a Today command for free. Contract **1.14.0**.

**As built (step 2).** `SittingList.swift`. The rules D4 and D5 left open were settled this way:

- **Roles overlap on purpose.** A task written in a sitting and finished in it is in both `written` and
  `finished`. Every role then means one thing, and a renderer dedupes by `ref`, as `pm day` does. A
  finished task carries the `ref` of its line *now*, or none when the line has been tidied away.
- **An untimed sitting** owns what happened on its day before the first timed sitting began. It is the
  "Earlier" mark, and it sorts first within its day.
- **The midnight rule** measures from the sitting's last completion, and that completion may fall on
  the day before the span. So Today reads events from the previous day on, and it lists only the
  ones owned by today's sittings or by nobody. A 12:40 AM tick that belongs to last night's sitting is
  last night's work and doesn't show in Today.
- **The archive is included** when `projects` is absent. The staleness rule makes it nearly free, and
  a project archived today had sittings today.
- `period` gained `yesterday` (on `DoneRange`, so `task.done` could take it later).
- **`projects`** is a list field, the contract's first (`stringList`). `[[links]]` are unwrapped and
  masters bring their members.

Coming up needs `task.whatsDue` to take a range, not just "soon". Projects needs `project.list` to carry
`lastActivity`: the later of its newest sitting's start and the notes file's modification time.

### D9 — Time can be laid out, not only filtered

Sittings have dates, D4 gives them times, and due dates are dates. So a view that is about time can be
drawn *on* time, not only as a list filtered by it. There are four layouts (`pmLayout`), and each view
offers only the ones that answer its question:

| layout | what it is | offered by |
|---|---|---|
| **list** | the default: grouped, in order | every view |
| **rail** | one day down a time gutter (D5) | Day, for a single day |
| **week** | seven columns, each sitting a block placed at its start time, due tasks pinned to the top of their day | Day, Coming up |
| **month** | a grid of days, each marked with its sittings (as project-colour dots) and what fell due. Clicking a day opens it as a Day | Day, Coming up |

This is still not a builder. The four layouts are designed, a view that can't use one doesn't offer
it, and there are about ten real combinations rather than every product of every choice. **Month on
Day is the journal's calendar**, and it's the view that makes a sessions-as-journal model feel like a
journal: a year of sittings you can see the shape of.

The week and month layouts are also where calendar events (below) would be drawn, and they're designed
so there is room for them.

### D10 — Every view reads as text

A good share of what these views are for ends somewhere else: the standup, the weekly update to a
client, a project handed to someone else. So every view has a **markdown rendering**, the same answer
laid out as a document. It's available from **Copy as Text** on the card, and as `--markdown` on the
view's CLI command. Because every view is a contract query first (the model's rule 1), this is one
formatter per view in PmLib, not a second implementation. It is plain markdown with `[[links]]`,
so pasting it into Obsidian gives you links that work.

### As built (step 3)

`CanvasViewSpec` (the node's settings), `CanvasDayCard` (the model and the drawing) and
`CanvasViewNodeView` (the card on the board).

- **Made from the add list** as **New Day View**: Today, across everything, 360×480. Its menu is
  **Period** (Today, Yesterday, This Week, and a pinned date when the file has one) and **Projects**
  (All Projects, Projects on This Board). Both are one undoable change to the node, like Shows.
  Choose Date… and naming projects in the menu aren't built. A pinned date or a `pmProjects` list
  written in the file works.
- **Polled, every 20 seconds while the card exists.** A day moves in files the app never opens, and
  nothing announces all of them. The same poll rolls a Today card over at midnight and takes *now*
  off a sitting that has gone quiet. A card scrolled off the board stops polling, as a project card
  lets go of its store.
- **One list, not the rail yet.** A day is drawn as D5's list: the start time in a gutter, the project
  chip, prose in full, tasks. A week is a caption per day and a lede per sitting. The chip already
  carries the sitting's name, so a week's lede comes from the prose, and one that only repeats the name
  is left out. The rail, week and month layouts are D9's.
- **The chip** is the project's `pm-icon` where it can be drawn, else its `pm-color` as a dot. So
  `session.list` now carries `projectColor` and `projectIcon`.
- **Rows** are the project card's parts (`TaskStatusIcon`, `RenderedNote`, the origin chip's look),
  drawn from `SittingTask` rather than from `Todo`, since a view holds no store. A task that's both
  written and finished in the sitting is drawn once, deduped by `ref`.
- **Clicking a project chip** opens that project.
- Zoomed out, the card is one line: *Today: 4 sittings · 7 done*.

### As built (step 4)

`CanvasDayActions`, and the rows in `CanvasDayCard`.

- **A row's box ticks and unticks it**, and its contextual menu offers the row's verbs: Complete or
  Reopen, Drop Task, Focus, Pick Up (from a sitting that isn't the project's current one), Put Back (on
  a tree picked up into the current one), Edit Task… (retyped in place, Return to save, Esc to leave),
  and Go to *Project*. The menu comes from what the row knows (`CanvasDayAction.offered`). The store
  has the last word when the act lands, so Pick Up on a task the store says can't be picked up does
  nothing.
- **Acquired on the act.** The first act on a project's row takes that project's store from
  `StoreRegistry`, and the card keeps it until the card goes, since letting go would throw away the
  history ⌘Z needs. A view that's only looked at holds nothing open.
- **⌘Z** takes the act back through `CanvasUndoRoute`'s project route: an act that leaves a step on
  its store makes that store the board's `lastEditedProject`, as a tick on a project card does.
- **The act lands on the line the row read, or not at all.** The row's `ref` is resolved against the
  store's own read with its digest. A line changed since the view last looked is refused with a beep,
  and the card looks again.
- **Drawn ahead of the scan.** A tick, untick or drop draws in its new state at once, and stays so
  until a scan that began after the write lands.
- **A view card takes its first click**, as a project card does, so the box ticks on it.
- **Selection is one sitting's rows** (`CanvasDaySelection`). A click selects, ⇧ extends, ⌘ toggles,
  and a right-click moves the highlight onto its row, as on a project card. A click in another sitting
  starts over there whatever keys are held. A sitting is one project, so everything a selection is
  told to do is one write and one ⌘Z. The menu counts what each item touches (*Drop 2 Tasks*,
  *Pick Up 1 Task* for a parent and its subtask), and adds Copy. Double-click focuses an open task
  and retypes a closed one, or any task with ⌥.
- **Retyping has its own ⌘Z.** The field (`TokenClickField`, shared with the project card's inline
  editors) keeps a typing history of its own, and `CanvasUndoRoute.typingUndo` makes it the editor
  route while the caret is in it. Before, ⌘Z mid-edit went past the typing to the project on a project
  card, and to the board's canvas stack on a Day row.
- **Dragging a row off** carries it (or the selection it's in) as markdown, and it lands as a text
  card, as a task dragged off a project card does. **Dragging a sitting off** by its time or its chip
  makes the D7 card: a project card with `pmShows: "sitting"` and `pmSitting`. It draws that one
  sitting, its prose and all its tasks and picks. A pin finds its sitting by label among that day's
  sittings, then by position, so renaming the sitting keeps the card. A day with no such sitting draws
  the whole project. One Sitting isn't in the Shows menu, since it needs a sitting to name, and
  choosing another lens takes `pmSitting` off.
- **Not yet:** opening a sitting's note in the card.

### As built (step 5)

`CanvasTaskLists` (the answer as groups and rows), `CanvasTaskListCard` (the model and the drawing), and
`CanvasViewRow`, the one task row every view draws, split out of the Day card so the three can't drift.

- **Made from the add list** as **New Waiting View** and **New Search View**. `pmView` is `waiting` or
  `search`, and a search keeps its words in `pmQuery`. Their menu is **Projects** only: Waiting is
  about now and a search is about words, so neither has a Period.
- **Waiting** draws `task.waiting`'s groups as the Waiting window does: the target as the heading,
  released first, in green, with "This landed". **Search** draws `task.search`'s ranking for what's in
  its field, the best 50. It searches as you type, and keeps the words on the node, as one undoable
  change, when you press Return or leave the field.
- **Each row carries its project's chip** after it (the `pm-color` dot or icon, then the name, and a
  due date when it has one). So `task.search` and `task.waiting` rows now carry `projectColor` and
  `projectIcon`, as `session.list`'s sittings do.
- **Acting is step 4's.** Complete, Drop, Focus, Edit Task… and Copy, plus **Stop Waiting** on a row
  whose own line says what it waits on. There's no Pick Up or Put Back, since there's no sitting in
  view to pick into. A selection is one project's rows, the way a Day's is one sitting's, so it's still
  one store and one ⌘Z. ⇧ extends through that project's rows across groups.
- **The contract (1.15.0).** `task.search` and `task.waiting` take `projects`, read as `session.list`
  reads it (`projectFolders(named:)`). On Waiting it narrows the *tasks*, and what they wait on still
  resolves anywhere. Hits carry `sessionOrdinal`, so a ref names the sitting whole.
- **Found on the way, and fixed: a write could land in the wrong sitting.** A task named by date alone
  means that day's *first* sitting. The store's references (`Todo.reference`) and the Waiting window's
  never sent the ordinal, so a tick on a task in a day's second sitting went to the first sitting's line
  of the same number whenever the two said the same thing. `Todo` now knows its `sessionOrdinal` from
  the parse, and every reference the app writes with carries it.
- **Polled every 30 seconds**, not 20: these walks read every project, where a Day only reads the
  ones touched in its span.

### As built (step 6)

`Leftovers.swift` in PmLib (the query), and the Waiting and Search card grown a third kind rather than a
new card: `CanvasTaskGroup` now holds items, each a hit plus the depth and pick that only Leftovers has.

- **What counts.** An open task whose line is in a dated sitting older than the cut-off. A task in no
  sitting has no "where did I write it", so it isn't listed. Waiting tasks are listed, since a wait is
  still something you left open.
- **A picked-up task is still left over.** Picking something up says you're on it, not that it's done,
  and the pile is where you see that you've picked it up three sittings running. Each task carries its
  last pick-up (`PickMark`), and the row says "picked up Sep 15" or "picked up today".
- **Depth counts listed ancestors only.** A subtask of a finished task starts a tree of its own rather
  than hanging indented under nothing.
- **Order.** Projects by their oldest leftover, oldest first, so the one left longest leads. Within a
  project, sittings oldest first, and within a day the earlier sitting first.
- **`before`** is `today` (the default), `yesterday`, `week` or a date. **`week` means before this
  week**, from the reader's first weekday, not seven days ago (D2 said "a week ago"). That way a
  Leftovers card set to it and a Day card set to This Week split the time between them with no gap and
  no overlap, which is the weekly review. The card's Period menu says **Before Today / Before Yesterday
  / Before This Week** when only Leftovers cards are chosen.
- **Projects.** Absent, it's active projects and areas: an archived project's open tasks were put down,
  not left. Named, an archived project is read too, since you asked for it. There's no cheap skip rule
  as `session.list` has, because a leftover is old by definition, so it reads every project, as
  `task.waiting` does.
- **The card** heads each project with its mark and name (a way to it), then each sitting with its
  date, time and lede. A sitting's heading drags off as a card of that one sitting (D7), as a Day's does.
  Rows offer step 4's verbs plus **Pick Up**, which goes into the task's own project's current sitting
  (starting one if it has none), and **Put Back** on a tree picked up today. A selection is one
  project's rows, across its sittings.
- **The contract (1.16.0)** adds `task.leftovers` with `before` and `projects`. `LeftoverProject.hit`
  turns a leftover into the `TaskSearchHit` every task-list surface draws.

### As built (step 7)

`DueList.swift`, `ProjectActivity.swift` and `ViewMarkdown.swift` in PmLib; `CanvasProjectsCard` in the
app, with Coming up as a fourth kind on the task-list card.

- **Coming up is `task.due`, not a widened `task.whatsDue`.** `whatsDue` answers for one project, as
  `Todo`s, and defaults to the focused project. A cross-project answer needs each task's project, so
  widening it would make one action return two shapes depending on its fields. `task.due` takes
  `until` and `projects` and returns `TaskSearchHit`s, like every other cross-project list.
- **A line's own date.** A subtask under a dated task inherits the date, and listing a task and its five
  steps as six things due Friday would be one deadline said six times. So a line is listed when it
  states a date itself. **Overdue is always in.**
- **Coming up's `week` is the next seven days**, not the calendar week: on a Friday the calendar week
  ends tomorrow, and Monday's deadline matters on Friday. Its menu says **Due Today / Next 7 Days**
  (no Yesterday), and a new card starts at Next 7 Days. The card groups by day: **Overdue** in red,
  then Today, Tomorrow and the date. Only an overdue row repeats its date.
- **Projects is `project.list` with `activity: true`**, which reads each project for `lastActivity` (the
  later of its newest sitting's start and its notes' last write, as D8 said), its newest sitting and
  lede, how many tasks are open, and the soonest due. It's opt-in because it reads every project, and
  a plain list shouldn't pay for that. `project.list` also takes `projects`.
- **Moving and Quiet.** The card splits at two weeks untouched (`projectQuietAfter`), newest first in
  each. A row says "3 days ago" and "12 open · next due Sep 19". Clicking goes to the project, dragging
  makes its card, and hovering shows the last sitting's lede. Its menu has **Projects** only.
- **Copy as Text** is on every view card's menu (**Copy 3 Views as Text** for several, joined). Each
  view has one formatter in `ViewMarkdown`, over the contract's answer: `##` for the view, `###` for its
  groups, task lines with their boxes, projects as `[[folder]]` (the way PM writes a project anywhere
  else), and dates written out rather than "today", since text is read later than it's copied. The
  CLI has the same words: `pm day --markdown`, and new `pm leftovers` and `pm due`. Waiting, Search and
  Projects have no CLI command of their own yet.
- **The contract (1.17.0)** adds `task.due`, and `activity` and `projects` on `project.list`.

### As built (step 8)

`CanvasViewCalendar.swift` (what each layout covers, and where things land, kept pure for the tests) and
`CanvasViewLayouts.swift` (the rail, a Day's week, and the month grid Day and Coming up share). No new
query and no contract change: every layout draws an answer the view already had, over a wider span.

- **`pmLayout`** on the node: `list` (the default, not written), `rail`, `week`, `month`. The card's menu
  has **Layout**, offering what every selected card offers. A layout a view doesn't have draws its list,
  and so does the rail on more than one day, but what's set is kept, so a card set back to one day is
  back on its rail. Choosing Week or Month grows a card to what it needs (780×480, 560×500) in the same
  undoable step.
- **The rail** places each sitting at least as far below the last as the time between their starts
  (0.8 pt a minute), so a morning of sittings back to back reads as one, and a quiet afternoon is empty
  rail. Blocks are measured, not sized by time: a block's height says what it holds, never how long the
  sitting ran (D5, as amended by [time-tracking.md](time-tracking.md) D6 — a sitting may *say* how long
  it ran, under a setting; nothing is ever *sized* by it). A completion in no sitting sits on the rail
  at its own time, where the list puts it under Also finished.
- **A Day's week and month are the calendar's**, found around the period's first day. So a Today card
  as a month is this month, and a card pinned to a June date is June. The header pages back and on
  with ‹ ›, which pins the period to that span's first day. Paging back to the span today is in returns
  to Today, following the clock, and **Today** in the header does the same in one click.
- **The week** is seven columns on an hour grid: the working day, 9 to 5, widened for an early or late
  sitting. Each sitting is a block at its start, in its project's colour, showing its time, project and
  lede. Two sittings too close together to both fit are stacked. A sitting with no time goes in a strip
  above the grid. Clicking a block goes to the project, dragging it makes a card of the sitting (D7),
  and clicking a day's heading opens that day as a Day card beside this one. Stray completions aren't
  drawn on the week; the list and the rail have them.
- **The month** is whole weeks, each day marked with a dot per sitting in its project's colour, and
  the sittings listed in the help. The days either side of the month are faint. **Clicking a day opens
  it as a Day card** pinned to that date, across the same projects, beside the calendar, so the month
  stays where it was.
- **Coming up rolls, as its period does.** Its week is the next seven days, today first, and its month
  is five weeks from the start of this one — the same `Period` a list draws from (`dueCutoff`), not a
  second calculation the grid makes on its own. Choosing Layout: Week or Month sets Period to match, in
  the same undoable step, so switching back to List shows what the grid was actually showing rather than
  whatever Period happened to say before. The Period menu is hidden there because a grid is one horizon,
  not a choice among several. In the week, what's due is pinned to its day as the list's own rows, which
  tick, drop and open as they do there, and what's overdue heads today in red. In the month, each day
  lists what fits and then "+N more", today leads with "N overdue", and days already past are faint.
- **Day's month doesn't show what fell due.** That's Coming up's question, and a board wanting both
  puts the two cards side by side. Calendar events (below) are decided but not yet drawn.
- **Copy as Text** is the same document in every layout: the answer over the span drawn.
- **A bigger card says more** (`CanvasCalendarDetail`). The layout doesn't just stretch: sizes are
  measured in the card's own units, before its zoom, and each day or block says what fits.
  - **Day's week.** The hours stretch to fill the card's height. Each block takes what it needs of
    the room before the next one begins: first a line of lede, then what came of the sitting, then
    the tasks it finished, then up to three lines of lede. It never runs into the next block. How
    tall it's drawn reflects what it says, not how long the sitting ran (D5).
  - **Day's month.** A day with room shows a line per sitting (its project, plus the time when the
    day is wide). With twice the room it adds each sitting's lede. Cramped, it shows dots.
  - **Coming up's week.** Columns go from compact rows with the project's mark, to full-size rows,
    to rows with the project's name, as the list has them.
  - **Coming up's month.** A task's words run to two lines when the day has room for all of them.
  - **Zoomed out.** When the board is too far out for the 9.5pt type to be 7pt on screen, a month's
    day becomes large dots and a week's blocks drop to a name. The node view only tells the card
    (`CanvasOnScreen`) when the board's zoom crosses that line, so zooming redraws it once.

**Amended** (2026-09-23). `Period` gained a `month` case (the calendar month, for Day/Leftovers/Time;
five rolling weeks for Coming up, the same split `week` already had) so it, not Layout, is the one place
a view's query window is decided — closing a bug where Coming up's grid silently ignored whatever Period
was set to, and a stored Period or Layout could go stale-but-hidden and reassert later with no visible
cause. Choosing a Rail layout while Period is a span (now Week or Month) resets it to List the same way;
choosing Period: Week/Month while Layout is Rail resets Layout to List.

## Calendars

Decided 2026-09-18. Steps 1–3 built 2026-09-25.

**The ask:** subscribe to a calendar, associate it with a project or area, and see its events among the
sittings, in the views that cover that project.

### C1 — Events come from EventKit, in the app only

Every account the Mac already has, behind one permission prompt (`requestFullAccessToEvents`, with an
`NSCalendarsFullAccessUsageDescription`), and no sign-in for Folio to handle. **This breaks the
contract-first rule, on purpose:** a CLI binary asking for calendar access is its own problem, so the
contract, `pm` and Raycast get no events at first. An `.ics` subscription URL is the portable
alternative, and the way back to the contract if another surface ever needs events.

**Events are read, never written, and never stored.** They're read live and aren't copied into the
vault or a sidecar. The calendar stays the truth about the calendar.

### C2 — A project names its calendars, and what to match in them, in frontmatter

Beside `pm-color`, under `pm-events`: a list of calendars, each with the queries its events must match.

```yaml
pm-events:
  - calendar: Work              # the calendar's title
    account: iCloud             # optional; only when two calendars share a title
    match: ["1:1 Priya", "Priya / Stuart"]
  - calendar: Launch            # no match: every event in the calendar
```

- **A calendar is named by its title and account**, not `calendarIdentifier`, which isn't stable across
  Macs. A name that matches nothing is kept, and just draws nothing, so a vault synced to a Mac
  without that account loses nothing.
- **`match` takes several query strings, and an event matches if any one does**: case-insensitive
  "contains", on the title. A series gets renamed, and a person has two recurring meetings, so one
  string wasn't enough. No `match` means the whole calendar; few people keep a calendar per project, so
  that's the rarer case.
- **Title only, no attendees.** People are out of scope (Not in this pass), and a title is what you can
  see and type.

### C3 — The association is the filter

A view shows the events associated with the projects it already covers (D2), and nothing else. A W-1
Day card shows W-1's meetings, and a card across the board shows every project's. There's no separate
filter on the card and no "all calendars": an event with no project to belong to has no row to be.
The views stay about the work and don't become a second calendar app.

### C4 — Events are a fourth row type, read-only

Drawn first in the rail, week and month layouts (D9), in the project's colour and visibly unlike a
sitting: an event is a span that was scheduled, a sitting is a start that happened. Whether they join
the plain list, and how, waits until they've been seen on the rail. Copy as Text includes them.

### Build order

1. ✓ **PmLib, no EventKit.** Read and write `pm-events`, and a pure matcher (a calendar title, an account
   and an event title against a project's entries). Tests cover several `match` strings, no `match`,
   a missing account, and a calendar that isn't there.
   As built (`ProjectEvents.swift`, `ProjectEventsTests`):
   - `ProjectEventSource`; `projectEventSources(rawText:)`, `settingProjectEventSources(_:in:)`,
     `setProjectEventSources(project:to:)`; `matches(calendar:account:title:)` on a source and on a list.
   - Calendar and account titles compare ignoring case and surrounding space.
   - A source with an account doesn't match an event with no account.
   - Blank `match` strings are ignored; none left means the whole calendar.
   - Reads block or flow `match`, a single string, quotes, comments, and a sequence at the key's indent.
   - Writes a canonical block: `match` always as a quoted flow list; titles quoted only when YAML needs it.
   - Rewriting drops unknown keys inside `pm-events`.
   - Clearing the last frontmatter key removes the block, as `settingFrontmatterValue` does.
2. ✓ **The app.** An EventKit reader, the usage string, and **Show Events From…** on the project and area
   menus: pick calendars, add query strings, and it writes the frontmatter.
   As built:
   - `CalendarEvents` (app): EventKit access, the calendars, and `events(in:for:)` filtered by
     `ProjectEventSource`. Searches only the calendars the sources name. Nothing is kept.
   - `NSCalendarsFullAccessUsageDescription` and `com.apple.security.personal-information.calendars`
     (hardened runtime). Access is asked for from the sheet, never at launch.
   - `PMCommand.showEvents`, "Show Events From…": Project menu, menu extra, quick bar (`calendar`,
     `events`, `meetings`), sidebar row menu, board card menu.
   - `ProjectEventsSheet`: calendars by account, a checkbox each, "Title contains" strings under a
     checked one, and a count and next event over 30 days. Saved calendars this Mac lacks are listed
     under Not on This Mac and kept. Writes on Save, only when changed.
   - Rows ⇄ sources are PmLib (`projectEventChoices`, `projectEventSources(from:)`). An account is
     written when the file named one, or two calendars here share the title and aren't checked alike.
     Opening and saving unchanged writes nothing.
3. ✓ **The views.** Events for the card's projects, drawn in the rail, week and month.
   As built:
   - `projectEventLinks(projects:)` (PmLib): every project with `pm-events` among a card's projects.
     All projects means active and areas; a named archived project counts. Frontmatter only, cached
     per file by modified date.
   - `ProjectEvent` (PmLib): an occurrence with its project. `days`, `startMinute(on:)`,
     `endMinute(on:)`, `timeLabel` ("9:00–9:30 AM", "All day"). An all-day event ends at the next
     midnight; a timed one ending at midnight stays on its day.
   - `CanvasEventFeed` (app): per Day card and Coming up card. Links off the main thread, then one
     EventKit read; again on every card poll and on `EKEventStoreChanged`. Nothing without access.
   - Drawn only where a layout is on time: Day's rail, week and month; Coming up's week and month.
     Day's plain list and Coming up's list draw none (C4).
   - Look: a dashed outline in the project's colour over a faint wash, with a calendar mark. Sittings
     stay filled blocks with a bar. Month lines: an outlined bar; dots: a ring.
   - Rail: at its start, an all-day one with the untimed sittings, ahead of a sitting at the same
     minute. A day with events and nothing written still draws its rail.
   - Day week: events sized by their span (sittings still aren't), side by side where they overlap
     (`CanvasTimeGrid.lanes`), behind the sittings. A sitting that begins in an event takes the right
     half; the event keeps the left. All-day events in a strip above the grid. Hours widen for them.
   - Coming up week: a day's events above what's due. Month: events before tasks, one line kept for
     tasks, "+N events" when they don't fit.
   - Copy as Text: an `## Events` section after the answer, a heading per day with events
     (`ViewMarkdown.events`).
   - Read only: no click action; the help names time, title and project.
4. **Later.** A sitting started during an associated event takes the event's title, so the meeting and
   its notes read as one row. A period anchored to an event ("since the last 1:1" as the calendar says
   it, not only as the notes do). **Take Notes for This Meeting**, starting a sitting in the associated
   area.

## No inbox, by decision

Decided 2026-09-18: PM has no inbox. Capture relies on the **focused project** and its **current
sitting**, so a note or a task lands where you are working, by default, with no triage step after it.
That's the model's own strength, and an inbox would weaken it: a second place for everything to wait,
and a daily chore of emptying it.

What it leaves open, recorded so the views don't paper over it:

- **Capture with nothing focused still fails** ("No project is focused", from Siri). The answer is to
  keep something focused, not to add a place to catch the miss.
- **Tasks never move between projects** (decided 2026-09-18). A task for another project is created
  there, in its current sitting, or in a new one if it has gone cold. That's the same join-or-start
  rule as every write. Tasks only relate across *sittings*, within a project, by picking up.

## Build order

Each step ships on its own.

1. ✓ **Start times in headings (D4).** It's first because it's the only step that can't be backfilled:
   every sitting started without one reads as "Earlier" forever. The label splits into a time and a
   name, every new sitting is written with its time, and renaming keeps the time. PmLib tests cover
   each heading shape in D4 parsing as it says, a rename keeping the time, and the first sitting of a
   day getting one.
2. ✓ **`session.list` and `pm day` (D8).** Tests cover attributing a completion to the sitting it fell
   in, a completion in no sitting, and a completion after midnight staying with the evening's sitting.
3. ✓ **The view card and Day (D2, D3, D5).** A text node carrying `pmView`, the row vocabulary with the
   project chip, the rail and the Week lede. Reading only.
4. ✓ **Acting from a view (D6).** Acquire-on-act through `StoreRegistry`, and the undo route. A
   `CanvasUndoRouteTests` case covers a tick on a Day row being undone by ⌘Z on the board.
5. ✓ **Waiting and Search as views.** These are adapters over queries that exist, and they prove the
   card is general before another query is written.
6. ✓ **Leftovers (`task.leftovers`).** The sitting card (D7) was built with step 4's dragging.
7. ✓ **Coming up and Projects**, and **Copy as Text** (D10) for every view that exists by then.
8. ✓ **The week and month layouts (D9).** They're last because they are the most drawing and the least
   new data, and because the calendar design should be settled before the week grid's shape is fixed.
9. ✓ **Time (`time.spent`).** The seventh kind, added 2026-09-22 by
   [time-tracking.md](time-tracking.md) D7 — a list and only a list, since its rows are projects. It
   is the first view whose query needed a *new record* behind it rather than a new question of the
   records PM already kept.

## Open

- **Selections across projects** were settled by not having them: a selection is one sitting's
  rows (step 4), so a gesture is one project's step.

## Not in this pass

- ~~**An activity log** (`.pm-activity.ndjson`): a sidecar stamping every write, throttled to one line
  per five minutes, that would give each sitting a span and an end. It was designed as D4 and set
  aside when start times went into headings. Worth reviving only if spans turn out to be wanted.~~

  **Wanted, and built differently** (2026-09-22, [time-tracking.md](time-tracking.md)). Spans were
  wanted. But a throttled log of *writes* would only ever have seen the minutes you spent typing into
  PM, and most of the time a project costs is spent in Obsidian, a browser or a terminal. So the
  record is of **attention** — where the focus is, and when the machine goes quiet — which is one
  global file rather than a per-project sidecar, and the thing it measures is the work rather than the
  app. A sitting's span and end fall out of it (D6 there), which is what this entry was after.
- **People.** Out of scope by decision (2026-09-18). PM doesn't manage people, so a view can't be
  scoped to one. Searching for a name is what Search is for.
- **Counts over time** (done per week as a chart). Views are lists of real things you can act on. A
  count belongs in a view's summary line, and a chart would be a different kind of card.
- **Scriptable view cards** (D1): the escape hatch if the closed set proves too small.
- **Next**: until a board asks for it (D1).
- **Learnings across projects.** `## Learnings` lines carry no date and aren't in any sitting, so they
  can't be ordered or placed in a day. That needs its own argument about whether a learning should
  carry a date, not a view.
- **The Waiting window as a board with one Waiting card on it**, the way the project window became a
  board tiled to one card (canvas-workspaces §7d). Worth doing once the view card exists, but it's a
  change to a window, not to the model.

## The goals this is checked against

Brainstormed 2026-09-18, so the views aren't shaped around the day alone. Any change to the set, the
settings or the layouts should still leave each goal with an answer, or say why not.

| goal | answered by |
|---|---|
| Get oriented in the morning: where was I, what's due, what's unblocked | Day (yesterday) · Coming up · Waiting |
| Shut down: close out today, note where to resume | Day (today) · Leftovers, acted on |
| Keep and reread the journal | Day in the rail, week and month layouts |
| The weekly review | Day (week) · Leftovers (before this week) · Projects · Waiting |
| Report out: standup, weekly update, client status | Day (week), Copy as Text (D10) |
| Plan the week | **Not answered.** Intentions aren't recorded anywhere, so this needs its own design |
| Prepare for a 1:1 | Day or Leftovers anchored `since:[[the area]]` (D2), and later a calendar event |
| Follow a meeting series | the sitting card (D7), beside the area's card |
| Come back to a dormant project | a project card set to Current. Not a view, which confirms where the line is |
| Wrap up a project before archiving it | Day (all time) on that project, with Copy as Text |
| Hand a project off | the same, plus the brief. A project card and a Day card on one board |
| Spot neglect, and balance the load | Projects |
| See the deadline horizon | Coming up, in the week or month layout |
| Find where I said something | Search |
| Follow a thread between projects | **Not yet.** Backlinks as a view, when a board asks for it |
| Resurface learnings and decisions | **Not answered.** The prose has no structure for these to be found by |
| Capture now, decide where later | not wanted. Capture lands in the focused project's current sitting |
| Watch momentum | a summary-line count only. Charts are out (Not in this pass) |
