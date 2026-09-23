# Where the time went

**Status:** decided and built 2026-09-22, steps 1–5. Follows [sessions.md](sessions.md), which settled what a sitting *is*,
and [done-report.md](done-report.md), whose log this one is modelled on. Amends [views.md](views.md) D5
on durations — see D6.

**Amended 2026-09-23 by [away-time.md](away-time.md):** D3 — quiet ≤ 15 min on the same project counts; display sleep isn't a leave.

PM can say what you finished and when you sat down. It can't say where the day went.

```bash
pm time              # today, per project
pm time week
pm time --since 2026-09-01 --until 2026-09-05
pm api call time.spent '{"period":"week"}'
```

## The problem

Three records in PM have a clock in them — the journal, the done log and the pick log — and
`SessionTimes.swift` already mines all three. Every one of them records a **moment**: a task was
finished at 14:26, a task was picked up at 15:02. A moment is enough to put a day in order, which is
what `SessionTimes` wanted. It is not enough to say how long anything took, because time spent is the
question of what you were doing *between* two moments, and nothing records that.

The nearest thing PM has is `task-timing.json`: a single slot, `{task_key, seen_at}`, overwritten every
time focus moves, feeding the menubar's stale tint. It knows how long the current task has been current
and forgets every span before it — which is exactly the shape of a feature that was never asked to
report.

### The thing this is not

Folio refuses durations on purpose today, in three places that all say the same thing:

> The rail shows only when a sitting began, never how long it ran: a column of durations reads as a
> timesheet. — `CanvasDayCard.swift`

That position was about the **rail**, and about sizing a block by how long its sitting ran, and it
stands (D6). What it should never have ruled out is answering "where did Tuesday go" when you ask.
A duration you went looking for is not a timesheet. A duration in a column beside every sitting you
didn't ask about is.

## The model

**Attention is a thing that moves, and moving it is an event.** One project or area has your attention
at a time. That has been true since the beginning — it's `focused.json`, a single global slot every
surface reads and writes. Time tracking is that slot with a log behind it.

**Time is derived, never stored.** No duration is written anywhere, ever. A span is arithmetic between
two edges, done on read — the same way `SittingList` stores nothing new and joins the two logs PM
already keeps.

## Decisions

### D1 — The unit is the project, not the task

Every total is per project or area. The log names the task too, but only as colour: what you were on
when the span began, and what changed during it.

Task focus is the wrong thing to measure. It is navigation (`PMStore.focus`, `recordsUndo: false`), it
**moves on its own** when you complete something — `selectNewCurrentAfterRemoval` picks the next leaf,
and sessions.md D3 is explicit that the app choosing a task is not you choosing it — and it frequently
names the next thing rather than the thing your hands are on. A per-task timesheet would be precise
about the wrong quantity, and precise is how a wrong number gets believed.

Project focus is different in every one of those respects. It is a deliberate act, it never moves by
itself, and it is the one fact all five surfaces already agree on.

### D2 — The attention log: one file, global, append-only

`~/.config/pm/attention.ndjson`. One event per line:

```json
{ "id": "…", "at": "2026-09-22T09:04:11Z", "event": "began",
  "project": "W-1 Website Refresh", "key": "/Users/s/PARA/active:W-1 Website Refresh",
  "task": "Draft the brief", "source": "app" }
{ "id": "…", "at": "2026-09-22T10:41:52Z", "event": "ended",
  "project": "W-1 Website Refresh", "key": "…", "why": "switched", "source": "app" }
```

**Global, where the done and pick logs are per project.** That's a deliberate departure from
done-report.md's reasoning, and it's forced: a span ends because your attention went *somewhere else*,
and the only file that can know that is one both projects write to. A per-project log would record a
hundred openings and never once say which of them was still going.

The price, accepted. It doesn't travel with a project through archiving, and it isn't backed up or
synced with the vault — the two properties that argued for a sidecar in done-report.md. Both are the
right way round here. A span is a fact about a Tuesday, not about a project's history, and two Macs
keeping one timeline between them would be two Macs each claiming the same hour.

Never pruned, unlike the journal it sits beside in the config dir. Entries are about 200 bytes, and a
busy day is a few dozen of them.

### D3 — A span is bounded by signs of life, not by the clock

Focus lands on a project at 9:00 and moves at 17:00. That is not eight hours of work. It is a morning,
then lunch, then an afternoon you spent on something you never told PM about.

A **sign of life** is input to the machine: any key, any gesture, in any app, anywhere. Not Folio's own
window and not its frontmost-ness — the work happens in Obsidian, in a browser, in a terminal, and PM's
claim is about the project rather than about its app. So the timekeeper watches the machine
(`CGEventSource.secondsSinceLastEventType`), never itself.

A span therefore runs from `began` to **the last sign of life while that project still had attention**.
`secondsSinceLastEventType` gives that moment exactly and at any time, so an `ended` is always
*back-dated* to it rather than stamped when it was noticed. Two things follow, and they are the whole
honesty of the feature:

- **Idle time is never counted**, whatever noticed it — a lock, a sleep, a lid, a meeting away from the
  desk, or nobody having touched the keyboard.
- **The threshold that notices changes when the record is written and never what it says.** A pause
  that ends a span ends it at the moment your hands left, not at the moment PM worked out they had.

`attentionPause` — **10 minutes**. This is the only thing the threshold decides: *the longest pause that
still counts as working*. Ten minutes is long enough to read a document, watch something, or think at
the screen, and short enough that a coffee isn't work. Coming back to the same project afterwards
starts a fresh span (`began`, `why: "resumed"`), so a day's total is the sum of its spans and the gap is
simply absent from it. Hardcoded, with the same note `sessionIdleWindow` carries: the obvious thing to
lift into Settings when it earns a control.

`attentionCap` — **an hour**. A span with no `ended` on record at all (Folio was killed, or was never
running) is worth the time to the last evidence the other three logs offer within it, and never more
than an hour. See D4.

### D4 — Folio keeps the time; every surface moves it

Only a running app can watch a machine go quiet, so Folio writes `began` and `ended`, and it is the
only thing that ever writes an `ended` with a real clock behind it.

But attention moves from Raycast, from `pm`, and from a model, whether or not Folio is running. So
`project.focus` appends `began` from the dispatcher too, from whichever adapter called it — the same
reasoning that made the done log observe rather than hook, arrived at from the other side.

That leaves spans opened by a surface and never closed by anything. A read closes them itself, and says
so rather than pretending:

- **`measured`** — an `ended` is on record. The span is what it says.
- **`inferred`** — no `ended`. The span runs to **the latest thing the journal, the done log or the pick
  log has for that project inside it**: a write at 11:40 is proof you were still there at 11:40, and
  proof beats a cap, so a long stretch of evidence is credited in full. With **no** evidence, nothing is
  known past the moment it began, and it is worth `attentionCap` — an hour of benefit of the doubt, and
  no more. Either way it is clamped to the next event in the log, which is where attention demonstrably
  went somewhere else.

A report totals both and marks the inferred ones. A number that says how it was arrived at can be
argued with; one that doesn't can only be believed or ignored.

**A span belongs to the day it began in.** One running past midnight is split at midnight, so a day's
total is a day's.

### D5 — What a read answers: time, and what came of it

`time.spent` (tier 2, a query), taking the same period fields as `task.done`. Per project: the total,
the spans it's made of, and **what changed while they were running** — tasks finished, dropped and
picked up, and sittings begun. Those come from the logs the spans are already being read against, so
they cost nothing.

A number on its own is a timesheet; a number with what came of it is a record of a day. That is the
whole of the difference, and it is why the two are one query rather than two.

```
Tuesday 22 September — 4h 20m

  Website Refresh          2h 10m   2 sittings · 3 done · 1 picked up
  Team 1:1s                  40m    1 sitting · 1 done
  Observation Probe        1h 30m   1 sitting                        (inferred)
```

`pm time` prints it. Longest first: the question is where the time went, and the answer starts with
where most of it went.

### D6 — On sittings, optional and off by default

**views.md D5 is amended, narrowly.** A sitting may say how long it ran, under a setting
(`showsSittingDuration`), default off. Everything else that passage says stands:

- **The rail is still not scaled by duration.** Blocks are measured, not sized by time. A block's height
  says what it holds.
- **A sitting's duration is the attention spans that fall inside it, summed** — never wall-clock from
  one heading to the next, which would count the hour you spent in another project as this sitting's.
- It is one quiet line in the sitting's chrome beside the time it began, in the tertiary style, and it
  is absent rather than zero when there's nothing on record.

Off by default because the objection was right: nobody asked for a column of durations. On, for the
weeks when you need to know.

### D7 — A card, because every query has one

`time.spent` with no card would be `pm done`'s situation, which [views.md](views.md) was written to
end: *"answered already, in the CLI and nowhere you can see it"*. So **Time** is the seventh view kind,
and its rule is views.md D1's — one question, one designed answer, every surface.

It is **a list and only a list**. A Day can be read down a rail, across a week or as a month because
its rows are sittings and sittings happen at times. Time's rows are projects, and a project doesn't
happen at a time; laying one out on a calendar would be answering Day's question, badly, next to the
card that already answers it well.

Each row is a project: its mark and name, how long it had your attention, a bar, and what came of it.
The `inferred` mark sits **beside the number it qualifies**, never in a legend at the foot of the card
that nobody reads next to the figure it applies to.

**A bar, not a chart**, and measured **against the longest row rather than the total**. Against the
total, a day split evenly across five projects draws five stubs and reads as a day where nothing
happened; against the longest, the top row is always full and each bar is compared with the one above
it, which is the only comparison anybody makes. That bar is the whole of the visualisation. A pie, a
stacked day, a rail scaled by duration — those are the timesheet views.md D5 refused, and refusing
them is not a limitation of this card but the shape of it.

**Projects with changes but no time are listed last, under their own heading.** A row with a dash where
a number should be reads as a broken table, and "you worked here without telling PM" is a different
fact from "40m" — worth saying, and worth saying separately.

## Build order

Each step ships on its own and leaves the app coherent.

1. **The log and the derivation (D2, D3).** `AttentionLog` beside `DoneLog` and `PickLog`; the span
   derivation pure and tested — trimming, capping, the midnight split, the inferred close.
2. **The contract and the CLI (D4, D5).** `time.spent`, `project.focus` appending `began`, `pm time`.
   Usable headless from here, with every span inferred until step 3.
3. **The timekeeper (D3, D4).** Folio watches the machine and writes the edges: focus changes, pauses,
   sleep, lock and quit. This is what makes a span measured rather than guessed.
4. **On sittings (D6).** The setting, and the line.
5. **The Time card (D7).** The seventh view kind, its model over `time.spent`, and Copy as Text.

## Not in this pass

- **Editing the record.** "That hour was actually the other project" has no gesture. The log is
  append-only and a correction would be an event like any other (`reassigned`), but the report has to
  exist before anyone can know which corrections they want to make.
- **Time against a task.** D1 rules it out as a *total*. A span already names the task that was focused
  when it began, so a later pass could say "this is roughly what that task cost" without any of it
  becoming a number anyone budgets against.
- **The month layout.** A Day card's list, rail and week each say how long a sitting ran when the
  setting is on; the month doesn't. Its cells are dots and single lines at the best of times, and a
  duration is the last thing that would fit. Worth revisiting only if the month grows a wide-cell
  detail level of its own.
- **Time against a project on the Projects card.** That card answers "which projects are moving", and
  a cost column would be a second question crowding the first. The Time card is one board away.
- **A calendar's answer.** Meetings are time spent too, and views.md leaves calendars decided but not
  built. The two should meet when they do.
