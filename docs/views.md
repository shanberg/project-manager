# Views: cards that answer a question

**Status:** proposed 2026-09-18. Build steps 1 (start times), 2 (`session.list`, `pm day`), 3 (the Day card) and 4 (acting from a row) are built. Follows [sessions.md](sessions.md), whose "Not in this
pass" left *a day across projects* waiting until the pick log existed. Generalises it: the day is the
first of a small set of cards that draw an answer rather than a document. Checked against a wider set of
goals (at the end) so that it isn't built only for the day. **Calendars** are sketched here only far enough that the views leave room
for them. An inbox was considered and decided against.

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

Leftovers reads *when* as "older than". Its default is sittings before today, and a week ago is the
weekly-review setting. Waiting ignores it, and Search takes `pmQuery`.

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

## Calendars, eventually

Sketched only so that the views leave room for it. Nothing here is decided.

**The ask:** subscribe to a calendar, associate it with a project or area, and see its events among the
sittings.

- **Where events come from.** EventKit is the likely source in the app: every account the Mac already
  has, behind one permission prompt, with no sign-in for PM to handle. It strains the contract-first
  rule, because a CLI binary asking for calendar access is its own problem, so events may be app-only
  at first. An `.ics` subscription URL is the portable alternative if that matters.
- **Association is a calendar plus a match**, stored in the project's frontmatter beside `pm-color`.
  Few people keep a calendar per project. The 1:1 area is "events titled *1:1 Priya* in Work", not a
  whole calendar. Calendar identifiers aren't stable across Macs, so the stored form needs care.
- **Events are read, never written, and never stored.** They're read live and aren't copied into the
  vault or a sidecar. The calendar stays the truth about the calendar.
- **What it gives the views.** Events are a fourth row type, read-only, drawn in the rail, week and
  month layouts. A sitting started during an associated event could take the event's title, so the
  meeting and its notes read as one row. A period could be anchored to an event ("since the last 1:1"
  as the calendar says it, not only as the notes do). A gesture like *take notes for this meeting*
  could start a sitting in the associated area.

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
5. **Waiting and Search as views.** These are adapters over queries that exist, and they prove the
   card is general before another query is written.
6. **Leftovers (`task.leftovers`).** The sitting card (D7) was built with step 4's dragging.
7. **Coming up and Projects**, and **Copy as Text** (D10) for every view that exists by then.
8. **The week and month layouts (D9).** They're last because they are the most drawing and the least
   new data, and because the calendar design should be settled before the week grid's shape is fixed.

## Open

- **Selections across projects** were settled by not having them: a selection is one sitting's
  rows (step 4), so a gesture is one project's step.

## Not in this pass

- **An activity log** (`.pm-activity.ndjson`): a sidecar stamping every write, throttled to one line
  per five minutes, that would give each sitting a span and an end. It was designed as D4 and set
  aside when start times went into headings. Worth reviving only if spans turn out to be wanted.
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
| The weekly review | Day (week) · Leftovers (a week ago) · Projects · Waiting |
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
