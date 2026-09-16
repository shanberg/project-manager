# What got done

**Status:** implemented 2026-09-16 in PmLib (`DoneLog.swift`), the contract (`task.done`), and the
CLI (`pm done`). Raycast, the menubar and MCP reach it through the contract; no surface draws it yet.
It started as an entry in a page of open items, since deleted; what that entry argued is kept below.

Ask PM what you finished today, or this week, and get a list back, across every project.

```bash
pm done            # today
pm done week
pm done --since 2026-09-01 --until 2026-09-05
pm api call task.done '{"period":"week"}'
```

## Why it needed a log

A notes file is state. Completing rewrites `[ ]` to `[x]` and that's the whole edit, so nothing records
*when*. The `### Thu, Aug 21, 2026` heading above a task is when it was written, and a task captured
three weeks ago and finished today would report as three weeks old. The journal isn't it either: an
undo stack, pruned to 200 entries, that only sees contract writes.

The date doesn't go on the task line (`done:2026-09-01`), because a stamp is paid once per finished
task, forever, in a document meant to read as prose. It goes in an append-only log beside the notes.
The file stays the truth about *what is*; the log is the record of *what happened*, so "open now" and
"checked on the 1st, reopened on the 3rd" never contradict each other.

## Observed, not hooked

The first shape assumed "the log only knows what PM witnessed" and would have appended from the
contract's write path. Looking at the code, the contract isn't the only thing in PM that completes
tasks: the Siri and Shortcuts intents call `completeTodo` directly
([PMReminderSchemas.swift](../pm-mac/PM/Intents/PMReminderSchemas.swift)), bypassing the dispatcher and
the journal, and Obsidian or any editor bypasses PM entirely. Hooking writes would have meant finding
every path and routing it, and still seeing nothing of the outside ones.

So the log is written by **looking**. Each project folder keeps a baseline of what was checked the
last time it was seen; a look compares the notes against it and appends whatever changed. There are
two places that look:

- **Every notes write.** `DirectNotesIO.writeContent` and `ObsidianNotesIO`'s CLI write look straight
  after writing, by the same `projectFolder(ofNotesPath:)` name test the canvas uses. Every PmLib write
  path funnels through a `NotesIO` — the contract, `NotesService`, the intents, the app's undo — so PM's
  own completions are stamped the moment they land, from whichever surface.
- **Every report.** `doneTasks` looks at each project before reading its log, so a checkbox ticked in
  Obsidian an hour ago is in the answer rather than waiting for PM to write that project.

A tick made outside PM is stamped when it was *noticed*, and the report counts it silently like any
other (decided 2026-09-16). The alternatives — flagging it, or listing it apart — were weighed and
passed over: the report is for reading back a week, and the noticed time is almost always the same day.

## The rules

**Matched by text, counted.** The baseline is, per task digest, how many are open and how many checked.
Not positions: sessions start above tasks and tasks move, and none of that is work. A **completion** is
one task of a given text going from open to checked — the checked count rose *and* the open count fell.
A **reopening** is the reverse. So:

- a task written already checked, a checked task renamed, or one pasted in from another project is
  nothing — only one side of the count moved;
- a task ticked and then deleted before anyone looked is lost, which is the price of not hooking;
- two tasks with the same text are two tasks, and ticking one is one completion;
- the focus marker and `due:`/`waiting:` tokens aren't part of the text, so completing a focused task,
  which drops its marker, is still that task.

**The first look logs nothing.** Tasks already checked when PM first sees a project were done at a time
nobody knows; the first look writes the baseline and stops, or the first report would be a year long.

**A reopening cancels the latest completion before it.** Done on the 1st and reopened on the 3rd was
not done that week; done again on the 5th was done on the 5th. The log keeps all three events.

**Deleted work still counts.** Each entry carries a copy of the task's text and the ISO date of the
session it sat under, because the line may be gone by the time anybody reports on it.

**Days are the reader's.** `today` and `week` are local; `week` follows the reader's first weekday.
`since` and `until` are local dates, both inclusive. (`parseSessionDateArgument` pins noon UTC for
headings; a report's Tuesday is the reader's Tuesday, so it doesn't use it.)

## Where it lives

In each project folder, beside `docs/`:

- `.pm-done.ndjson` — the log. One event per line: `at` (UTC), `event` (`completed`/`reopened`),
  `text`, `digest`, `session`. Never pruned; entries are about a hundred bytes.
- `.pm-seen.json` — the baseline, `{"tasks": {"<digest>": [open, checked]}}`, replaced on each change.

Per project rather than in `~/.config/pm`, because `paraPath` is optional and there may be no common
vault root, because a folder carries its history through rename and archiving for free, and because it
syncs and is backed up with the work — the property that disqualified the journal. Dot-prefixed so
Obsidian's tree and Finder ignore both.

The baseline is in the folder rather than the config dir for a reason that only shows with two Macs: a
baseline that didn't sync would have the second machine find every completion the first one made and
log it again.

A look holds an exclusive `flock` on the log while it reads the baseline, appends and writes the new
baseline, so the app and a `pm` call looking at the same moment can't both log one completion. The lock
is on the log, which is only ever appended to, because the baseline is replaced atomically — a new
inode — and a lock on a replaced file locks nothing. Events are appended before the baseline is saved:
interrupted between the two, the next look logs the change again (a duplicate) rather than never (a loss).

## The action

`task.done` is a query. Fields: `period` (`today` default, `week`), `since`, `until`, `scope` (`all`
default, `active`, `archive`). Archived projects are in by default, unlike `task.waiting`: finishing
something and archiving it the same week is the most done a thing can be. Data is a list, newest first:

```json
{ "projectFolder": "W-1 Redesign", "projectName": "Redesign", "isArchived": false,
  "at": "2026-09-16T14:26:49Z", "text": "Email Dana", "session": "2026-09-16" }
```

`pm done` prints it grouped by project, tasks oldest first within each.

## The todo.txt convention, kept for the record

[todo.txt](https://github.com/todotxt/todo.txt) came up as the way to spell an in-file stamp. Moot for
this feature, but two findings are worth not re-deriving, and [canvas-backlog.md](canvas-backlog.md)
item 14 leans on the first:

- **PM's `key:value` tokens are already the todo.txt extension convention.** The spec's own worked
  example is `due:2010-01-02`, character-for-character the token PM writes
  ([NotesTodos.swift:7](../pm-swift/Sources/PmLib/NotesTodos.swift:7)). If a date ever does land on a
  line, `done:2026-09-01` beside `due:` is the spelling, and it is a citation rather than an invention.
- **The positional half was never going to port.** `x 2011-03-02 2011-03-01 …` puts two bare dates in
  front of the text and tells them apart by order alone, where `TaskContent.split` peels *trailing*
  tokens in a loop so that any arrangement parses identically. And `+Project` / `@context` collide
  head-on with the ` @` focus marker and `[[Name]]`.

todo.txt's second date, creation, is answered already: the session heading records it once per sitting
instead of once per line.

## Not yet

- **A view in Folio.** The contract has the answer; nothing draws it.
- **Session prose.** A week read back as a checklist is thinner than the week was. Sessions written in
  the range could come along with the tasks.
- **Looking on reads.** The app reloads a project when its file changes on disk, which would be a
  natural third place to look and would stamp Obsidian ticks within seconds for open projects. Left out
  so that reading stays free of writes; the sweep before a report makes it unnecessary for correctness.
