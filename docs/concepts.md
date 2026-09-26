# Concepts

What each thing is, as built. Facts only; the design docs linked from each section hold the reasons.
Where a doc and the code disagree, this follows the code — see [Mismatches](#mismatches).

## Project and area

- Two kinds: `project` and `area`. The kind is read from the folder name, never stored. ([areas.md](areas.md))
- A project is named `{CODE}-{N} {Title}` (`W-1 Website Refresh`), lives in `active/`, and ends.
- A project number is unique across `active/` and `archive/`. Zero-padding follows the existing convention: `W-01` → `W-02`. ([README](../README.md#numbering))
- An area has a name and no number, lives in `areas/` (config `areasPath`), and doesn't end.
- Both archive into one `archive/`. Unarchiving returns each to its home root. The verb is Archive for a project, Put Down for an area.
- Project folders: `deliverables/`, `docs/`, `resources/`, `previews/`, `working files/`. Area folders: `docs/`, `resources/`.
- A folder is an area only if its notes file resolves. `pm adopt` writes a notes file into an existing folder and changes nothing else.
- Areas have the same notes, tasks, sessions, focus and capture as projects. There are no `area.*` actions; `project.create` takes `kind`.

## Notes file

- `docs/Notes - {Title}.md`. The title is the folder name without its `CODE-N ` prefix.
- Frontmatter keys: `pm-icon`, `pm-icon-recolor`, `pm-color`, `pm-texture` (+ `-reach`, `-strength`, `-pixel`, `-tile`), `pm-events`, `pm-part-of`.
- The first `# ` line is the title.
- Callouts, in order: `[!summary] Summary`, `[!question] Problem`, `[!info] Goals` (numbered, three slots), `[!info] Approach`. ([templates/notes.md](../templates/notes.md))
- An area has Summary and Goals. Problem and Approach are kept only if they already hold text.
- `## Links` — a mirror of the canvas's Links frame. See [Links](#links).
- `## Learnings` — a bullet list.
- `## Sessions` — `### ` session headings, newest first, each followed by prose and tasks.

## Session

Also called a *sitting* in the app. ([sessions.md](sessions.md), [tile-sessions.md](tile-sessions.md), [SessionWindow.swift](../pm-swift/Sources/PmLib/SessionWindow.swift))

- A heading under `## Sessions` and everything below it until the next heading.
- Two roles: a journal entry (when you sat down, what you were thinking) and the place tasks are written.
- Heading: `### EEE, MMM d, yyyy[ label]` — e.g. `### Thu, Sep 18, 2026 9:10 AM · Week in review`.
- Label: an optional start time (`h:mm AM/PM`, local), then an optional name after ` · `. A label that doesn't start with a time is all name.
- Every session PM starts is given its start time. Renaming keeps the time.
- Dates are local time.
- **The current session** — where every write without an explicit place goes (`task.add`, `session.note`, quick bar capture, CLI, Raycast, pick-up):
  1. No heading for today → start one.
  2. Today's newest session is empty → reuse it, whatever its age.
  3. Today's newest session is warm → join it.
  4. Today's newest session is cold → start one.
- Warm means the notes file was modified within the last 90 minutes. Edits made in Obsidian count. The window is fixed.
- Only today's heading is considered, so a session that crosses midnight becomes two.
- New Session joins the current session like any write. ⌥ New Session and `session.start` with `new: true` always start one, except that an empty session is reused.
- `pm notes session add` always adds a heading.
- A session's note is its whole body, prose and task lines together, in written order. `session.note` appends to the current session.
- Several sessions on one date are told apart by an ordinal: 0 is the topmost, i.e. newest.
- A session reference is `{date, ordinal, index, digest}`. The digest is of the label and ignores the time. It resolves as hit, relocated (same day) or stale. ([SessionRef.swift](../pm-swift/Sources/PmLib/SessionRef.swift))
- Sessions with nothing in them (blank lines only) are removed when a project is opened. A session holding only picks is kept. The file's modification time is restored, so the idle window isn't reset.
- Delete Session is offered only for a session with no tasks.
- `session.backfillTimes` / `pm backfill-times [--write]` dates untimed sessions:
  - from the earliest journal, done-log or pick-log event that day, rounded down to 5 minutes;
  - 9:00 AM when there is no evidence;
  - always kept between the timed sessions either side.
- Untimed sessions are drawn under one "Earlier" mark on their day.
- What a session gathers besides its own lines: the older tasks picked up during it. See [Pick](#pick).

## Task

([task-identity.md](task-identity.md), [NotesTodos.swift](../pm-swift/Sources/PmLib/NotesTodos.swift))

- A line: `- [ ] text`. Written `<text> waiting: [[target]] due: <date> @`. Tokens in any order are read; an edit writes them in that order.
- States: `- [ ]` open, `- [x]` done, `- [-]` dropped. Done or dropped is *closed*.
- Subtasks are indented 2 spaces per level. A tree is a task and the run of deeper tasks after it; a tree never crosses a session heading.
- Due: `due: YYYY-MM-DD[ HH:mm]`. A bare date is noon local time. A task without a date takes the earliest date among its ancestors.
- Waiting: `waiting: [[target]]`. A task without a wait takes its nearest waiting ancestor's. See [Waiting](#waiting).
- A task reference is `{project, session, sessionOrdinal, line, digest}`:
  - `line` counts task lines in the session; prose doesn't count;
  - `digest` is the first 8 hex characters of SHA-256 of the text, without the due, waiting and focus tokens;
  - it resolves as hit, relocated (found exactly once elsewhere) or stale.
- Leftovers (`task.leftovers`): open tasks in sessions before a date, grouped by project then session, oldest first. Each session carries a lede: its name, else its first subheading, else its first paragraph.

## Pick

([sessions.md](sessions.md) D1–D5, [PickLog.swift](../pm-swift/Sources/PmLib/PickLog.swift))

- Picking up an older task records that you worked on it in the current session. The line stays where it was written.
- A pick covers a whole tree, named by its root.
- Picks go into the current session only. Picking up in a cold project starts a session; that heading is the only change to the notes file.
- Recorded in `.pm-picked.ndjson` in the project folder: append-only, never pruned.
  - `picked` — the task (`session`, `ordinal`, `line`, `digest`, `text`) and the session it went `into`;
  - `released` — `reverses` the pick it cancels;
  - `retargeted` — the task's new digest after its text changed.
- A pick whose task or session no longer resolves isn't drawn. It is never an error.
- Picks up: focusing an older task; Pick Up on the row menu; dragging a task onto the current session; ticking, editing, or setting a due date or wait on an older task; adding a child to an older tree.
- Doesn't pick up: focus advancing on its own; reopening; dropping.
- Drag onto another session picks up; ⌥-drag moves the line. Dropping into an older session without ⌥ isn't allowed.
- A session draws its prose, its own tasks, then **Picked up**, each with where it came from. The older session shows "picked up Sep 17" on the root.
- A pick is undone with the edit that made it, as one ⌘Z step.

## Drop

- Closing a task without doing it, written `- [-]`.
- `task.drop` drops open descendants too and advances focus. `task.reopen` reopens done or dropped.
- Progress counts a dropped task as resolved, not done. `pm done` leaves dropped tasks out unless given `--dropped`.

## Done log

([done-report.md](done-report.md))

- `.pm-done.ndjson` in the project folder, with its baseline in `.pm-seen.json`.
- Events: `completed`, `reopened`, `dropped`. Never pruned.
- Written by comparing the notes with the baseline after each notes write and before each report. It isn't written by the actions themselves, so edits made in Obsidian are counted too.
- `task.done` / `pm done [today|week] [--since] [--until] [--dropped]`, archive included, newest first.

## Focus

([task-focus-flow.md](task-focus-flow.md))

- The focused project: `~/.config/pm/focused.json`, one for every surface.
- The focused task: a trailing ` @` on one line of a project's notes. One per project.
- Completing the focused task moves focus within its session to the first open of:
  1. its parent's first leaf;
  2. its next sibling's first leaf;
  3. its parent.
  Failing those, it goes to the first open leaf anywhere; failing that, it clears.
- Focus moving on its own skips waiting tasks. Focusing a task yourself doesn't.
- `task.diveIn` focuses the first open leaf under the focused task. A new task takes focus.
- `project.focus` also starts timing that project. See [Time](#time).

## Waiting

([links.md](links.md) — about waiting, not project links)

- Stored once, on the task: `waiting: [[target]]`. What a project is waited on for is found by scanning.
- A target is matched, case-insensitively, by folder name, title, `CODE-N`, then unambiguous prefix. Roots are searched active, then areas, then archive.
- Outcomes: `pending` (target live), `released` (target archived), `unresolved` (a person, or ambiguous).
- A target with a code resolves by the code and is drawn with the project's current title.
- The Waiting list: `task.waiting`, ⌃⌘W.

## Capture

- `capture.parse` reads due phrases (Today, Tomorrow, This Weekend, Next Week, In Two Weeks, `in 2w`, weekdays, a time) and a trailing `@project`.
- Quick bar modes: capture (no prefix), find task `/`, go to project `@`, command `>`, session note (⌃⌥N).
- Capture placements: under the focused task, after it (⌥ before), end of session, session note.
- No inbox: capture goes to the focused project's current session.

## Canvas

([canvas-workspaces.md](canvas-workspaces.md), [items.md](items.md), [ProjectCanvas.swift](../pm-swift/Sources/PmLib/ProjectCanvas.swift))

- One per project or area: `<project>/docs/<Title>.canvas`, made on first use. If that file isn't there, a lone canvas in `docs/` is used, then a lone canvas at the project root.
- Obsidian JSON Canvas. Node kinds: `text`, `file`, `link` (a web card), `group` (a frame). Plus edges.
- Keys PM adds are prefixed `pm`, and keys PM doesn't know are kept as they are.
- A new canvas holds the project card: a file card on the project's notes.
- Items: text, file (folders included), view and page cards. Frames are sections, not items.
- Lenses: Board, List, Grid (⌥⌘1–3), remembered per canvas on this Mac. Sorted by reading order, file, name or kind.
- View cards: a text card with `pmView` — `day`, `waiting`, `search`, `leftovers`, `coming-up`, `projects`, `time` — plus `pmProjects`, `pmPeriod`, `pmQuery`, `pmLayout`. What a view shows is never written to the file. ([views.md](views.md))
- Project card presets (`pmShows`): everything, current, tasks, brief, sitting.
- Inbox frame: marked `pmRole: "inbox"`. Cards added without a place go here (`card.add`, Services).
- Links frame: marked `pmRole: "links"`. See [Links](#links).
- Contract: `card.list`, `card.add`.

## Workspace

([canvas-workspaces.md](canvas-workspaces.md))

- A named set of tiles in columns. A column is a stack of tiles; a tile holds one card, or several as tabs.
- ⌘Return tiles the selection into a workspace named automatically ("Workspace", "Workspace 2"). The same cards reopen the same workspace.
- The canvas is a permanent tab of its own; each workspace is a tab.
- Stored on this Mac (UserDefaults `PMCanvasWorkspaces`, by canvas path), never in the `.canvas`.
- Tabs in a tile: ⌥[ and ⌥]; dragged along the strip or off it.
- Maximize fills the window with one tile or card. It isn't saved.
- A satellite is a tile moved out into a window of its own; a tile of tabs becomes a window of tabs. Its content is lent to the window, not reloaded. Satellites are put away and brought back with their workspace (UserDefaults `PMCanvasSatellites`).

## Web card

([web-cards.md](web-cards.md))

- A `link` node. The file holds its saved address; browsing changes its live address. Only Pin writes the live address back as the saved one. Home returns to the saved address.
- The live address is remembered across relaunch, without the page's state.
- Session: `pmSession` names a profile; none means the shared one. "Private" is a single session shared by all private cards and never kept on disk.
- Page budget: at most 8 live pages per board (1–24, `PMCanvasLivePages`). A page off screen stays live for 10 minutes (`PMCanvasOffScreenGrace`). Other pages are frozen and show a snapshot.

## Links

([ProjectLinksFrame.swift](../pm-swift/Sources/PmLib/ProjectLinksFrame.swift), [ProjectLinksSync.swift](../pm-mac/PM/Model/ProjectLinksSync.swift))

- A project's links are the web cards in its Links frame. A link's name is `pmLabel` on the card.
- A frame inside the Links frame is a group: several links under one label.
- Notes inside the frame are notes, not links.
- Order is the board's reading order.
- `## Links` in the notes is written from the frame, in its usual format: `- Name: url`, `- url`, or `- Name` with indented `- url` lines.
- Changes to `## Links` made by hand are carried to the frame: a line added makes a card; a line removed removes its card; a renamed or reordered line renames or moves its card.
- Changes on the board are written to `## Links`.
- The frame stores the list last written (`pmLinksMirror`), which is how each side's changes are told apart.
- Rows that aren't links stay in the notes and off the board.
- The app syncs after every read of a project's notes, and whenever a board's Links frame changes.
- `notes.addLink` syncs too, so a link added from `pm`, MCP or Raycast is a card with or without the app running.
- A project with links and no canvas is given one.

## Services

- Services ▸ Send to Focused Project in Folio, and Send to Project in Folio… (which asks, through the quick bar's project list).
- Files are moved into the project's `resources/` (a taken name gets a number) and added to the Inbox frame as file cards.
- Web addresses become project links.
- Other text goes into the current session's note.

## Views and calendars

([views.md](views.md))

- Seven kinds: Day, Waiting, Search, Leftovers, Coming up, Projects, Time.
- `session.list` / `pm day [today|yesterday|week|DATE]`: sessions in a range with their tasks by role — written, picked, finished, dropped — and work done elsewhere.
- A session can be dragged out of a view into a card of its own (`pmShows: "sitting"`).
- `pm-events` in frontmatter lists `{calendar, account?, match[]}`. A match is a case-insensitive "contains" on the event title; no match means the whole calendar.
- Events are read from Calendar, in the app, when shown. They are never stored.
- Set with Show Events From….
- Not built: events drawn in views; a session named after its meeting.

## Time

([time-tracking.md](time-tracking.md), [away-time.md](away-time.md))

- `~/.config/pm/attention.ndjson`: one log for every project, append-only.
  - `began`, and `ended` with a reason (switched, paused, locked, slept, resumed, elsewhere);
  - `counted` and `withdrawn`, for away time answered by hand.
- Durations are worked out when read, never stored.
- 10 minutes without input ends a span, back-dated to the last input. A span inferred without evidence is capped at 1 hour.
- Spans are measured, estimated or counted. A span belongs to the day it began and is split at midnight.
- A gap of 15 minutes or less, opened by a pause and ended on the same project, counts as work.
- Away time: gaps of 10 minutes to 4 hours are asked about — the newest in the menubar, all of them in the Time card. Answered with Count for… or Not Work (`time.count`).
- Apps marked not work (`PMNotWorkApps`) end a span after 60 seconds in front.
- `time.spent`, `time.aways`, `time.count`; `pm time [aways|count]`.

## Master project

([combining-projects.md](combining-projects.md))

- A member names its master in frontmatter: `pm-part-of: "[[S-004 Project Manager Tool]]"`. A master stores nothing; its members are found by scanning.
- One level: a master can't be a member, and a member can't be a master. Areas can be either.
- A master's card lists its members; the sidebar nests them; its progress and next due include theirs. Archiving a master offers to archive its members.
- `project.setPartOf`, `pm part-of`, Part Of…. Renaming a master rewrites its members' links.

## Journal and undo

([api-contract.md](api-contract.md))

- `~/.config/pm/journal.ndjson`: every write made through the contract (CLI, MCP, Raycast, app), with snapshots in `~/.config/pm/journal/`. Keeps 200 entries.
- Revision: the first 12 hex characters of SHA-256 of a file. Every read reports it.
- A write given a revision happens only if the file is still at it.
- `journal.undo` reverses the latest write only while the file is as that write left it; otherwise it reports a conflict.
- `dryRun: true` returns what a write would do, without writing.
- The app keeps its own ⌘Z stack, separate from the journal.

## Mismatches

- [task-identity.md](task-identity.md) says session dates are UTC; the code formats them in local time.
- [sessions.md](sessions.md)'s pick-log example has no `task.line`; the code writes one.
- [sessions.md](sessions.md) D3 puts Pick Up in the Task menu; as built, it's only on the row's menu.
- [links.md](links.md) lists parent/child projects as not built; master projects are built.
- Comments in `CanvasWorkspaces.swift` and `CanvasViewState.swift` still describe unnamed workspaces; [canvas-workspaces.md](canvas-workspaces.md) §7i names every workspace.
- [task-identity.md](task-identity.md) cites `NotesRawEdit.swift:562` for `sessionAddPreservingFormat`; it is now at line 632.
