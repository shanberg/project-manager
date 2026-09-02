# Open items

Things worth building that aren't designed yet. Each entry is the shape of the problem and the
questions that have to be answered first — not a plan. An item graduates into its own page under
`docs/` when it's settled enough to build.

## A report of what got done — today, this week

**Status:** open, raised 2026-08-31.

Ask PM what you finished today, or this week, and get a list back. The weekly-review use, and the
standup use: you did the work, the record of it is spread across a dozen notes files, and reading
them back by hand defeats the point of having written them down.

### Why it isn't free

Nothing records *when* a task was checked. Completing rewrites `[ ]` to `[x]` in place and drops the
focus marker — [NotesTodos.swift:559](../pm-swift/Sources/PmLib/NotesTodos.swift:559) — and that's
the whole edit. The only date anywhere near a task is the `### Thu, Aug 21, 2026` session heading it
sits under, and that is when the task was *written*. A task captured in one sitting and finished
three weeks later would report as three weeks ago, which is worse than no report.

The journal isn't the answer either. `~/.config/pm/journal.ndjson` does record a `completed` change
with a timestamp, but it's an undo log, not a history: 200 entries kept, pruned above 300
([ApiJournal.swift:63](../pm-swift/Sources/PmLib/Api/ApiJournal.swift:63)), and it only sees writes
that went through the contract. A busy fortnight ages the evidence out, and a checkbox ticked by hand
in Obsidian was never in there at all.

So this is a data question before it's a reporting question.

### The shape: a log beside the notes, not a stamp in them

**Decided 2026-09-01.** The completion date does not go on the task line. It goes in an append-only
log, and the notes file stays exactly as heavy as it is today.

The weight argument is the whole argument and it's enough: a stamp is paid once per finished task,
forever, in a document whose entire claim is that you can read it as prose. A project that ships two
hundred tasks ends up with two hundred lines of bookkeeping you scroll past to find the three you
care about. Reporting is a thing you do occasionally; reading the notes is a thing you do constantly.
The occasional job doesn't get to tax the constant one.

Two things fall out that are better than a consolation prize.

**The disagreement question dissolves.** It was the obvious objection to a log — the log says done,
the file says `[ ]`, who wins — and it turns out to be a wrong question. The file is state; the log is
events. "This task is open" and "this task was checked on the 1st and reopened on the 3rd" are both
true, and neither contradicts the other. Reopening appends a reopen; it doesn't rewrite history. The
file on disk stays the truth about *what is*, which is the rule the journal already states outright
([ApiJournal.swift:104](../pm-swift/Sources/PmLib/Api/ApiJournal.swift:104)), and the log answers the
different question of *what happened* — the one a weekly report is actually asking.

**Deleted work still counts.** A stamp lives on the line, so tidying a finished task out of the notes
erases the fact that you did it. A log entry outlives the line it describes, which means it has to
carry a text snapshot rather than only a `TaskRef` — the ref may not resolve by the time anyone
reports on it. That's a requirement, not an aside.

The cost, stated plainly: **the log only knows what PM witnessed.** A stamp is written into the file
and survives anything that can read the file; a log is written by a process that has to be running.
Tick a checkbox in Obsidian and no event exists — see the open question below, which this decision
makes sharper rather than solving.

### The convention question, kept for the record

[todo.txt](https://github.com/todotxt/todo.txt) came up as the way to spell an in-file stamp. It's
moot now, but two findings from it are worth not re-deriving:

- **PM's `key:value` tokens are already the todo.txt extension convention** — the spec's own worked
  example is `due:2010-01-02`, character-for-character the token PM writes, and
  `dueInlinePattern` even accepts the spaceless form
  ([NotesTodos.swift:7](../pm-swift/Sources/PmLib/NotesTodos.swift:7)). If a date ever does land on a
  line, `done: 2026-09-01` beside `due:` is the spelling, and it's a citation rather than an
  invention.
- **The positional half was never going to port.** `x 2011-03-02 2011-03-01 Review Tim's pull
  request` duplicates the markdown checkbox, puts two bare dates in front of the text, and
  distinguishes them by order alone — where `TaskContent.split` peels *trailing* tokens in a loop
  specifically so any arrangement parses identically
  ([NotesTodos.swift:59](../pm-swift/Sources/PmLib/NotesTodos.swift:59)). Also `+Project` and
  `@context` collide head-on with the ` @` focus marker and `[[Name]]`. Those are settled; the spec
  doesn't get to relitigate them.

todo.txt's second date, creation, is the one thing worth keeping in mind — and PM's answer is
unchanged by any of this: the `### Thu, Aug 21, 2026` session heading already records creation once
per sitting instead of once per line.

### What's still open

- **Where the log actually lives, and this is the hard one.** There may be no such place as "the
  vault". `paraPath` is optional and unset on every config that predates it
  ([Config.swift:8](../pm-swift/Sources/PmLib/Config.swift:8)), so a setup with only `activePath` and
  `archivePath` has no guaranteed common parent to put a single file in. That leaves two answers.
  A **per-project dotfile** (`.pm-done.ndjson` in the project folder — dot-prefixed so Obsidian's
  tree ignores it) always has a home, travels through rename and through the active/areas/archive
  moves for free, and keeps a folder self-contained; the report becomes an N-folder scan, which is
  what `task.waiting` and the menubar count already do anyway. A **single file in the config dir** is
  simpler to read but leaves the vault — no sync, gone on a new machine, not backed up with the work
  — which is precisely the property that disqualified the journal. Leaning per-project.
- **Not the journal, and not in the journal.** `journal.ndjson` is an undo stack: 200 entries kept,
  pruned above 300 ([ApiJournal.swift:63](../pm-swift/Sources/PmLib/Api/ApiJournal.swift:63)), with
  content copies behind it. This log must never prune and holds tiny entries. Same file format,
  different file, different lifetime.
- **Tasks checked outside PM** — now the sharpest open question, because the log can't see them at
  all. PM could diff against a last-seen snapshot and synthesise an event, but it can only honestly
  record when it *noticed*, not when it happened. Does the report say "12 done, 3 noticed since you
  last looked", fall back to the session heading, or say nothing?
- **One project or the whole vault.** The interesting version is vault-wide; `task.waiting` already
  groups across every project, so there's a precedent for the shape.
- **Whether a report is only tasks.** A week read back as a checklist is thinner than the week
  actually was. Sessions carry prose too, and a review probably wants both.
- **Where it surfaces.** An API action plus CLI is the floor, since Raycast and the menubar both come
  free from the contract. Whether the Mac app deserves a real view of it is separate.
