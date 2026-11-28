# Sessions and time: one model

**Status:** stories written and decided 2026-11-28; step 1 (a session's end) built the same day. Follows
[sessions.md](sessions.md), [time-tracking.md](time-tracking.md), [away-time.md](away-time.md) and
[stale-tasks.md](stale-tasks.md). The full set of stories, with mocks, lives outside the repo; this
keeps the decisions and the story ids the code cites.

## The problem

A session is current by when the notes file was last written (90 minutes). Time is counted by project
focus and input (10 minutes). Old work ages by picks and keeps (21 days). Each was right on its own, and
together they disagree about what a session is: focused hours with nothing written leave no session, and
a one-line capture into an unfocused project starts one.

## The model

1. **A session is attention plus writing.** It begins when you focus a project or write to it, and stays
   current while either goes on.
2. **A session has an end, and the end is derived:** the last attention span or write inside it, worked
   out on read. Nothing new is stored.
3. **Time with no session is a question, not a loss.** An away and a focused span with no session are
   answered the same way: count it to a project, optionally as a session.
4. **Old work meets today through four verbs:** Pick Up, Keep, Drop, Skip.
5. **Two kinds of signal.** *Needs you* is act now (due work, notifications). *Tend* is look soon
   (stale trees, unanswered aways, projects due for review, waits gone quiet, cold projects with no next
   step). They never share a mark.

## Decisions

- **D1 — Attention decides the current session**, as well as writes.
- **D2 — When focus opens a session, its heading is written on the first write.** Until then Day draws it from its
  attention span, so no empty headings are made.
- **D3 — In a review, Pick Up is Next:** it keeps the tree and focuses it; the real pick happens in the
  session where the work is done.
- **D4 — Projects get a Not Now state, until a date.** It takes a project out of Tend and the review
  queue; its due work stays in Needs you.
- **D5 — "Session" is the word on screen.** "Sitting" in code and older docs means the same thing.
- **D6 — Standard UI language.** Every surface uses standard macOS controls and wording: menus, sheets,
  popovers, push buttons, disclosure rows.

## Stories the code cites

- **C2 — A session shows when it ended.** `SittingEntry.endedAt`: the latest task finished, dropped or
  picked up in it, moved later by the end of the last attention span it owns when the read asks for time
  (`withDurations`). `session.list` carries it (contract 1.26.0); `pm day` prints `9:10 AM – 10:45 AM`.

## Build order

1. ✓ A session's end (C2), in `session.list` and `pm day`.
2. The Time card opens into sessions; time with no session shows on Day (E6, E3).
3. Mark reviews by an event, not only the label (F2).
4. What counts as a session (A1, A2, A4, H2, and D1, D2), as one change.
5. End Session's next-step line, and arriving in context (C1, D1 of the stories).
6. One Tend list (G1, G3).
7. Write in Session and New Session, meetings, and the rest (A3, A5, B1, C3, E5).
