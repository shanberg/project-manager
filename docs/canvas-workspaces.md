# Working on the board

Two things were asked for, and they are one claim seen at two scales: **a board is a place you work,
not a place you look.**

> The canvas view is for freely placing and relating items related to a project. A free thinking
> space, including taking action and taking notes. The tile view is a way to create one or many
> complete workspaces based on those cards.

The code currently says the opposite, in as many words:

> A project's notes card opens the project, and that item comes first: it is a card *showing* a
> project, and **the board is read-only**, so this is the way in to actually doing something about
> what it says.
> — [CanvasBoardView+Commands.swift:318](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:318)

Everything below follows from retiring that sentence. It is not a list of missing commands; the
commands are missing *because* of it, and adding them one at a time without replacing the premise is
how the card ended up able to tick a task but not write down why.

**Status.** §§1–5 are built. A project card you have stepped into starts sessions, writes their notes,
adds tasks, and reads and edits the brief; and the brief's fields commit as you leave them, in the
window as well as on a card. The arguments now live where the code is — `CanvasProjectNote`,
`SessionNoteTakeover`, `DetailsEditor`, `CanvasBoardView.engagedProjectCard`. What is kept here is the
shape of the whole, because **§6 and §7 are not built** and lean on it.

## 1. What a project card can and cannot do today

[CanvasProjectNote](../pm-mac/PM/Canvas/CanvasProjectNote.swift) already shares the project window's
real store, through `StoreRegistry` — so a tick on a board is the same act as a tick in the window,
one document, one undo stack. That part is right and nothing here changes it.

**It can:** tick a task, focus one (double-click), edit its text (⌥ double-click, or the menu), set
due, set waiting, add a task *relative to an existing task*, delete tasks, follow a `[[link]]`, go to
the project.

**It cannot:**

- **Start a session.** Nothing on the card offers it. ⇧⌘N reaches `state.requestNewSession()`, which
  only [ProjectView](../pm-mac/PM/Project/ProjectView.swift:635) answers — so on a canvas tab it lands
  nowhere, and a standalone board window has no `ProjectWindowController` to send it to at all.
- **Write or edit prose.** The card draws prose through `RenderedNote`, which is a renderer. The
  window's way in is `openSessionNote(index)` → `SessionNoteTakeover`. The card has no equivalent, so
  the one thing PM is *for* is the one thing a board cannot do to a project.
- **Add the first task.** `AddEditor` only opens from `TaskMenu` on an existing todo, so a project
  with no tasks has no way to get one.
- **Show or edit the details block.** The card's body is title + sessions; summary, problem, goals and
  approach are not drawn at all.
- **Add a link**, which is the other thing you do to a project's notes.

## 2. Stepping in is the whole safety story

The read-only premise had a real argument under it, and it survives — just not as far as it was taken.
A board is mostly panned and read, and a checkbox that fired on the first click that landed near it
would make the board hazardous to cross. That is what **engagement** is for: one click steps in, and
from then on the card takes its own clicks
([`takesItsOwnClicks`](../pm-mac/PM/Canvas/CanvasNodeView.swift:180)); in a tile there is nothing to pan
across, so the click that lands in a tile *is* the step in.

That mechanism is already built, already works, and is already the gate on every edit the card does
allow. Nothing was withheld beyond it for a second reason — there was no second reason, only a premise
nobody went back and revised. So:

**A project card you have stepped into is the project.** The engagement gate is the entire safety
story, and everything the window can do to the notes, the card can do to the notes.

## 3. Where the card stops

Not everything, though, and the line is worth stating because it keeps "Go to Project" from being an
admission of failure:

- **The card does everything you do to the notes** — sessions, prose, tasks, details, links.
- **The window keeps everything you do to the project as a thing on disk** — archive, rename, reveal
  in Finder, open in Obsidian, the sidebar, find across the document.

That is a boundary a person can hold in their head, and it is the same one the card's own doc already
half-states when it says the card is "a project, not a markdown file".

## 4. Writing a session on a card

The two acts, in the order they matter.

**New Session** is `store.openCurrentSession` ([PMStore.swift:975](../pm-mac/PM/Model/PMStore.swift:975)),
which is what the window's `beginCurrentSession` calls: the *current* session — the one the project is
already in, or a new one when the idle window has closed the last. The card wants the same call and the
same landing, which is the caret in the note, because a session you just asked for is one you are about
to write in.

**Writing prose is a takeover, not an inline field.** The window replaces its whole column with
[`SessionNoteTakeover`](../pm-mac/PM/Project/ProjectView.swift:2839) — a header, a `MarkdownTextEditor`,
no Save or Cancel, auto-saving on every way out. A card should do exactly that to itself: while you are
writing, the card *is* the editor, and Back returns it to the note. Three reasons, and the third is the
one that decides it:

1. It is the same piece rather than a lookalike, which is the rule this card was built on.
2. Prose wants the whole width. A card is already a narrow column; an inline editor inside a rendered
   note would be a narrow column inside a narrow column.
3. **The takeover already solved a problem the card would otherwise meet fresh.** It captures its seed
   and its `SessionRef` at init, precisely because a note written from the quick bar can insert a
   session above the one being edited — and on a board that race is not hypothetical, it is Tuesday:
   six cards, several on the same project, all writing to stores that update each other.

The dependency to sever is `state: ProjectViewState`, which the takeover uses for titlebar clearance
and for opening a `[[project]]`. A card has no titlebar; the clearance becomes a parameter and the
project-opening is the callback `CanvasProjectNote` already takes.

**Affordances: menu and keyboard, plus inline rescue for the dead ends.** The window has no New Session
button either — it is ⇧⌘N and the File menu — and a card that grew chrome the window does not have
would be the lookalike problem again. So the card's commands live in its contextual menu and on the
same keys. The exception is the two states with nothing to click:

- a project with no tasks needs a row to add the first one,
- a project with no sessions needs a way to start one that is not a menu you have to guess at.

Those get an inline row, revealed once you have stepped in, in the place the window puts its add
editor.

**The details block edits as live rows.** Summary, problem, goals and approach are the one part of the
notes that is not already live: `DetailsEditor` is an explicit form, seeded into `@State`, and the only
way anything reaches the file is the Save button — with a Cancel beside it
([ProjectView.swift:3358](../pm-mac/PM/Project/ProjectView.swift:3358)). A modal form inside one pane of
a workspace you are working across is worse than it is in a window, so the card forces the question
[item 15](canvas-backlog.md) was holding: the block becomes live rows like the task list, and **Cancel
is retired**. That is the honest half of the trade — a form that both writes as you type and offers to
discard is lying about one of the two — and it is affordable because the notes file has undo behind it
and the rest of the app has no modal editing anywhere. The card is not getting a lesser version of the
window's form; the window loses the form too.

## 5. The engaged card is the board's current project

⇧⌘N on a board has to mean *which* project, and a board can hold six.

The board already knows how to answer this once: ⌘Z routes to
[`lastEditedProject`](../pm-mac/PM/Canvas/CanvasBoardView.swift:87) — the more recently edited of the
canvas document and whichever project card wrote last — because "edited last" is what a person means by
undo. New Session is not that kind of command. It is aimed, so it takes the aimed answer: **the card
you are stepped into.** Nothing engaged, nothing targeted, and the command is dim.

This is also the answer to a question another item left open. Item 13 asks what "the current project"
means on a board with six project cards on it, and answers "the window's project, which is nothing at
all for a board opened from a file". The current project is the card you are in — which is true of a
file-opened board too, and does not need a window to have an opinion.

## 6. What a card shows, and why it is now load-bearing

A workspace of "the project's tasks, and Figma" and a workspace of "the whole project, and Jira" are
two cards on the same project, configured differently. So what began as a density complaint about a
board of six projects — the backlog's item 12 — became the thing that
makes workspaces distinguishable: a card set to show the latest session, all sessions, the details block, open tasks, or
all tasks — and mixed.

Two consequences that were not obvious before.

**Display is not capability.** A card showing only tasks can still start a session and still write a
note. What a card *shows* is a lens on one document; what it can *do* is settled by section 2. The
obvious wrong turn is to build a tasks-only card as a tasks-only surface, and then a workspace made for
working through tasks is the one workspace you cannot write in.

**Two cards, one project, one store.** `StoreRegistry` refcounts, so two cards on one project share the
store and stay in step with each other and with the window for free. What assumes there is only one is
`CanvasProjectNoteCard.isOn`, which gates the "add the project note card" offer — it decides whether to
*offer*, so a second copy has to be reachable another way (duplicate is the obvious one).

**Storage: the node, in the `.canvas`.** The backlog guessed "probably defaults, keyed by canvas path
and node id, which is what `CanvasCardMedia` and `CanvasCardSession` already do" — and that was
backwards about its own precedent. Both keep their setting **on the node, in the file**, under a `pm`-prefixed
key, and both argue for it in the same words: this is something you *set*, and a card that forgot it
when the window closed would be worse than not offering the choice
([CanvasCardSession.swift:13](../pm-mac/PM/Canvas/CanvasCardSession.swift:13),
[CanvasCardMedia.swift:26](../pm-mac/PM/Canvas/CanvasCardMedia.swift:26)). `CanvasCardZoom` is the third.
Three precedents all one way, and the reasoning fits this case exactly: what a card shows is a fact
about that card, it is a name rather than anything private, and a board shared through Obsidian
carrying it is a feature.

## 7. What a workspace is

> A workspace is a particular set of tiles, relative placement/size, and pinning settings. A workspace
> can have a name. A workspace is ephemeral unless named. A workspace can be duplicated. Tiles on a
> workspace can be rearranged.

That definition needs no designing, because it describes a structure the app already has, field for
field. `CanvasViewState.Tiling` is `ids` — the set of tiles, in the order that *is* their relative
placement — plus `arrangement` (grid or master-stack), `masterFraction`, and `sizes`, whose whole job
is to hold, per tile, "a pinned length, or a share"
([CanvasViewState.swift:33](../pm-mac/PM/Canvas/CanvasViewState.swift:33)). Set of tiles, relative
placement, relative size, pinning. The workspace already exists as data; what it does not have is the
word, or anywhere to be.

**Ephemeral unless named** is likewise already the design, and already argued at length — as two
storage files with deliberately different lifetimes:

- The tiling that is up lives in [`CanvasViewMemory`](../pm-mac/PM/Canvas/CanvasViewState.swift:57),
  which is *volatile*: rewritten on every change, so a board you left tiled comes back tiled. Leaving a
  tiling does not discard it either — `lastTiling` keeps it, because "Escape means *show me the board*,
  not *forget what I did*".
- A named one lives in [`CanvasArrangements`](../pm-mac/PM/Canvas/CanvasArrangements.swift), and the
  reason it is a separate file is exactly this distinction: "you built an arrangement, you named it, and
  you expect it to be there next month… one careless memberwise initialiser away from losing all of
  them."

So naming is not a save-as bolted on the side. It is a promotion between two stores that were built
apart on purpose, and the word for what gets promoted is *workspace*.

**Rearranging tiles is built** — dragging a tile carries it and displaces the one it is over
(`.reorderTile`, [CanvasBoardView+Input.swift:96](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:96),
`CanvasTileSession.reorder`), and the order is stored precisely because the order is the arrangement.
**Duplicating one is not** — that is [item 10](canvas-backlog.md), and under this definition it is how a
second workspace ordinarily comes to exist rather than a convenience.

What is left, then, is not design: the word, a home in the window for named workspaces, duplicate, and
untangling the word from the two other things wearing it.

### What a frame is

Worth spelling out, because the app has been calling frames workspaces and that is the confusion this
section removes.

A **frame is a group node in the `.canvas` file** — Obsidian's own concept, which PM draws as a
labelled rectangle on the board with cards sitting inside it, adds from the board menu, and renames
through "Rename Frame…". It has a position and a size, it is in the document, it syncs, and Obsidian
opens the same file and shows the same frame. Membership is geometric: the cards it holds are the ones
whose *centres* fall inside it, so dragging a card in or out is how you change what is in it. ⌃1…9 goes
to one — fit it in the window and select what is in it, "fitting rather than tiling, because a frame was
arranged by hand and the arrangement is the point".

Against the definition above, a frame is a different kind of thing in every way that matters. A frame
has a *place*; a workspace has no position at all. A frame is in the shared document; a workspace is
per-machine and must never show up in the file as an edit. You drag a card into a frame; you choose
cards into a workspace. A frame's layout is where you put the cards; a workspace's layout is computed
from an arrangement and some sizes.

The overlap — both are a named set of cards — is real, and it is the entire overlap. It is what
[CanvasBoardView+Tiling.swift:556](../pm-mac/PM/Canvas/CanvasBoardView+Tiling.swift:556) leans on: "a
frame is already a named container of cards, which is what a workspace is. Nothing had to be built for
this; it only had to be noticed." The noticing was right and the conclusion was one step too far. That
comment is the one to rewrite, `workspaces` becomes `frames` and `goToWorkspace` becomes `goToFrame`,
and ⌃1…9 keeps doing exactly what it does now.

Frames and workspaces do have a relationship, and it is a useful one rather than a confusing one: a
frame is a good way to *choose* the cards a workspace is made of. ⌘Return on a frame already tiles what
is inside it, which is "make a workspace out of this region" — the two concepts meeting at the one
point where they should.

## 8. What this does to the backlog

- **New, and first:** the card is the project (§§2–5). The complaint that started this.
- **12** — what a card shows — is promoted and re-argued: display is not capability, and it is stored
  on the node, not in defaults (§6). It is the next thing to build.
- **15** — live-saving the summary and goals — is **decided**: live rows, and Cancel is retired, in the
  window as well as on the card (§4). It stopped being optional the moment a details block could sit in
  a tile.
- **18** — what a workspace is — is **answered** (§7), and what is left is a rename plus a home. The
  definition turned out to be `CanvasViewState.Tiling` as it already stands.
- **9** and **10** fold into §7: not "is this hidden or missing" but "this is the unit, give it a home",
  and duplicating one is how the second workspace gets made.
- **13** — suggest the project's links — gets its open question answered by §5.

## Open

**The rename's blast radius.** `goToWorkspace(_:)`, `workspaces`, `CanvasFocus.arrangement`, the saved
defaults key, and every doc comment that argues "frames are workspaces" — including
[CanvasBoardView+Tiling.swift:556](../pm-mac/PM/Canvas/CanvasBoardView+Tiling.swift:556), which argues it
well and will need to argue the opposite. Saved data keyed by name has to survive it.

**Whether a workspace can span boards.** Everything above keeps a workspace inside one board, because a
tiling is a list of card ids and cards live in a `.canvas`. "Slack and Google Docs, no project notes"
is a workspace with nothing project-shaped in it, which raises the question of which board it belongs to
at all. Left open deliberately: the answer is probably "the board you made it on, and that is fine",
but it is worth being sure before the word *workspace* is promoted to the thing tabs are made of.
