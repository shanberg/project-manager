# Project review: gather your thoughts, clean up a creaky project

**Status:** one-project review built 2026-11-28. Not yet run on a Mac. The queue across projects is next.

## The problem

A project goes creaky without anything being wrong on any one day. Tasks age past three weeks, a due
date slips by, the summary stops describing what the work has become, a wait outlives the project it
was waiting on. Catch Up ([stale-tasks.md](stale-tasks.md)) answers one of these, one tree at a time.
Nothing sits you down to look at the whole project and decide what you think of it now.

## Decisions

### D1 — A review is a sitting

Opening a review starts a sitting named **Review** (`reviewSessionName`), as Take Notes for This Meeting
starts one named for its meeting. So:

- the old tasks it picks up are drawn under it, under **Picked up**, as in any sitting;
- its time is counted, and Day shows it;
- what you write at the end is its note, followed by a line saying what the review did
  ("Reviewed: kept 3 · dropped 2 · brief updated.");
- **last reviewed is read, not stored**: it is the newest sitting whose name is Review, or begins with it
  ("Review: Q4"), and that has something in it (`ProjectReview.lastReviewIndex`).

A review closed without anything done deletes its empty heading again, so opening one by accident isn't
a review. Keep stays Keep: a "still meant" writes the pick log's `kept`, not a pick, so the Review
sitting doesn't fill with things you only looked at.

### D2 — Creaky is read from what's already on disk

`ProjectHealth` (PmLib) reads a project's notes and tasks, with the picks and keeps a read already
carries:

| Reason | Read from |
| --- | --- |
| Stale trees | `TaskStaleness.staleRoots` |
| Overdue | open tasks whose own `due:` has passed (an inherited date isn't counted again) |
| Waits released | open tasks whose own `waiting:` names something archived |
| Focus gone quiet | the focused task untouched for three weeks |
| Gone quiet | no sitting for three weeks (`projectQuietAfter`) |
| Empty brief | Summary, Problem, Goals, Approach left blank (an area: Summary and Goals) |

`isCreaky` is any of the first five. An empty brief is reported for the brief step but isn't a creak on
its own: plenty of small projects never fill one in. `score` ranks a queue, overdue heaviest; `reasons`
are the words a queue row shows ("2 overdue", "12 stale tasks", "no sitting for 5 weeks").

### D3 — The walk

`ProjectReviewWindowController`, one review at a time. Steps with nothing in them are left out.

1. **Since Last Time.** Read only: the sittings since the last review (or the last three weeks, for a
   first one), each by its lede, and how many tasks were done and dropped since (the done log).
2. **The Brief.** Summary, Problem, Goals, Approach, edited in place. Written when the step is left, and
   only if something changed. One ⌘Z step.
3. **Older Tasks.** Catch Up itself (`StaleReviewView`, embedded), over the stale trees.
4. **Dates and Waits.** Overdue tasks: Tomorrow, Next Week, No Date, Drop. Waits on something archived:
   Clear Wait, Drop. A focus gone quiet: Keep, Drop.
5. **Your Thoughts.** Free text for the sitting's note, an optional learning (added to Learnings) and an
   optional next task (added to the sitting).
6. **Wrap Up.** What the review did. Finish, or Finish and Archive (Put Down, for an area), which moves
   the folder once everything is written.

Closing the window is finishing: what was answered stays, and the thoughts typed so far are written.

### D4 — It stays out of "needs you"

The "needs you" signal is *act now*: due work and notifications. A review is *tend soon*. A creaky
project gets no mark; it's offered where you'd go to tend it: **Review Project…** in the Project menu and
the menubar's Project submenu, `>review` in the quick bar, and **Review …** on a Projects card row.

## Not in this pass

- **The queue across projects.** "Review Projects…" over every active project ranked by `score`, each
  with its reasons, one walk per project with empty steps skipped, and a summary at the end. Offered in
  the menubar when any project is creaky. `ProjectHealth` is the reading it needs.
- **The board step.** Inbox frame cards and Untitled doc cards to file, delete or leave.
- **A weekly nudge.** On demand only, until it's clear one is wanted.
- **"Not now".** A state between active and archived, so a parked project stops counting as creaky.
- **The contract.** No `project.health` action yet, so Raycast and the CLI don't see it.
