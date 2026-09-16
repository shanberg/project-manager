# Sessions in a project card

**Status:** built, 2026-09-16 — backlog 25, which absorbed 16. The review is below as it was written;
the decisions at the bottom are what was built. 24, the note lost on switching tiles, was fixed on its
own first (a card stepped back into reopens the note it was left in, at its caret).

Since the window's own list was deleted (25a5aef), a project card *is* how a project's notes are read
and written — on a board, in a tile, and in the window, which is a board tiled to the project's card
([canvas-workspaces.md](canvas-workspaces.md) §7d). So how a card enters and shows sessions is no
longer a board question. It is the app's only answer.

## What a card does today

**It draws**, top to bottom: the title with New Task and New Session; the brief, when shown; every
session, newest first, each a quiet caption (`date · label`, not selectable) over its prose rendered
inline and its tasks inside the sentences that made them; and a footer that offers "Start a session"
or "Add a task" when there is nothing else. `CanvasCardShows` narrows it per card — everything, the
current session, open tasks, or the brief — and narrowing is per block, so a **session with nothing
left to show has no caption either**.

**Prose is a takeover.** Double-clicking a caption or prose, or the caption's Edit Note, replaces the
card with `SessionNoteTakeover`; the note is saved on the way out, and renaming the session lives in
its header.

**Sessions are entered five ways**, and only one of them says so:

| | what it does |
|---|---|
| double-click a caption or its prose, Edit Note | opens that session's note |
| New Session — title button, ⇧⌘N, File menu, "Start a session" | `openCurrentSession`, then opens its note |
| New Task, "Add a task" | `task.add` with no anchor: joins or silently starts a session, then adds |
| a row's Add Task | beside the anchor, in its session |
| anything outside the app — CLI, Raycast, quick bar | the same join-or-start rule as New Task |

**The rule under all of them** is `currentSessionPreservingFormat`
([SessionWindow.swift](../pm-swift/Sources/PmLib/SessionWindow.swift)): today's session is joined
unless the project has been left alone for 90 minutes, when a second heading is started and labelled
with the time. An empty heading is always joined. Only *today* is considered, so a sitting that runs
past midnight becomes two.

## What is wrong with it

1. **New Session usually isn't.** Pressed an hour into a sitting, it opens the session you are already
   in. The command's name is a promise the rule underneath it doesn't keep, and it is the one place
   someone is saying "this is new work" on purpose (16). Nothing anywhere forces a new heading:
   `session.start` has no flag for it, and only the CLI's `pm notes session add` adds one unconditionally.
2. **A card can't remove a session.** The window's session menu had Delete (empty of tasks only); the
   card's caption menu was cut shorter and nothing replaced it. A stray heading — one started by a
   New Session nobody wrote in — can only be removed by editing the file.
3. **A session you just started can't be seen.** It has no blocks, so it has no caption. The note
   takeover hides this while it is open; close it without writing, and the heading is in the file and
   nowhere on the card.
4. **Captions are the only handle on a session, and they are the quietest thing on the card** —
   `.caption2`, tertiary, not selectable, no hover. Every session command is behind a double-click or a
   right-click on text that doesn't look like it takes either.
5. **Two leftovers.** `SessionNoteTakeover.Placement.titlebar` has no caller since the window's list
   went. And canvas-workspaces §4 still says the card gets no buttons and cites old line numbers; §7d
   names `CanvasCardShows.completed`, which the presets replaced.

## Decisions

Taken 2026-09-16.

- **D1 — New Session keeps the join; ⌥ New Session forces a new one.** The plain command stays what
  every other write is, so it can't leave a trail of empty headings behind a habit of pressing it, and
  the alternate is there for the times you mean it — the way ⌥ turns a menu item into its stronger
  sibling everywhere on the Mac. `session.start` takes `new: true` (contract 1.8.0); the File menu shows
  the alternate under ⌥, and the card's title button reads ⌥ on the click.
- **D2 — Delete Session on the caption menu**, for a session with no tasks, as the window had it. The
  write already refuses a session with tasks; the menu doesn't offer it.
- **D3 — an empty session draws its caption, with a quiet call to action** under it rather than a bare
  "Empty": the two things you would do with a sitting that has nothing in it yet, write in it or add a
  task to it. Write a note is always offered; Add a task only on today's newest session, since that is
  where an unanchored add lands. Shown where the card shows that session's prose and no find is
  narrowing it; presets that leave prose out still hide it.
- **D4 — captions stay as they are.** Not taken.
- **D5 — the leftovers.** Delete `.titlebar`, and bring canvas-workspaces §4 and §7d up to date.
