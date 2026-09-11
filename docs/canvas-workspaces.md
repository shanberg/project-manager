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

**Status.** §§1–6 are built. A project card you have stepped into starts sessions, writes their notes,
adds tasks, and reads and edits the brief; the brief's fields commit as you leave them, in the window as
well as on a card; and a card is set to draw the brief, the notes, the tasks, finished work, and either
every sitting or the latest. The arguments now live where the code is — `CanvasProjectNote`,
`SessionNoteTakeover`, `DetailsEditor`, `CanvasCardShows`, `CanvasBoardView.engagedProjectCard`. What is
kept here is the shape of the whole. **§7, §7b and §7c are built too** — the words go to the right
things; a workspace has a name you can see, a list you can switch from, and no Save; and its home is a
tab, which is where its commands are and what duplicating one makes another of. **§7d is built**: the
project window's notes *are* a board tiled to the project's own card. **§7e is built**: every project
has a note and a canvas — enforced now rather than asserted — and with two faces down to one board at
two scales, the renderer switch is gone; the way out of the notes is zooming out of them, and the tab
renames itself on arrival. **The card's keyboard is built too**, by the rule find already used rather
than the flag §7d expected. **The task column is gone**: a canvas that
will not parse is now replaced rather than fallen back from (§7f), which was the last thing keeping it
alive, and the other two jobs it was doing have answers of their own. **§7h is built**: read back as a
whole, the sections above had left four kinds of debt between them — acts that destroyed work with no
question, a row that could not hold what §7g put in it, two stores answering one question, and exits
that vanished exactly when they were needed — and every one of them is a thing an earlier section made
true and did not go back to. **§7i is built**: every workspace has a name and every tiling is one, the
canvas is a permanent tab at the head of the row rather than a chip that other chips can turn into, and
a tab stopped following its board — which is what the header's reflow was made of. **§7k is
built**, all six steps: a workspace is columns of tiles, grid and master-and-stack are two ways of
filling them, and it has keys, tabs, the board as a picker, peek and Size Columns to Content. What is
left is the one question under Open, which is not a task.

## 1. What a project card can and cannot do today

[CanvasProjectNote](../pm-mac/PM/Canvas/CanvasProjectNote.swift) already shares the project window's
real store, through `StoreRegistry` — so a tick on a board is the same act as a tick in the window,
one document, one undo stack. That part is right and nothing here changes it.

**It can:** tick a task, focus one (double-click), edit its text (⌥ double-click, or the menu), set
due, set waiting, add a task *relative to an existing task*, delete tasks, follow a `[[link]]`, go to
the project.

**It cannot:**

- **Start a session.** Nothing on the card offers it. ⇧⌘N reaches `state.requestNewSession()`, which
  only the task column answers — so on a canvas tab it lands
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
[`SessionNoteTakeover`](../pm-mac/PM/Project/SessionNoteTakeover.swift) — a header, a `MarkdownTextEditor`,
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
([`DetailsEditor`](../pm-mac/PM/Project/ProjectDetails.swift)). A modal form inside one pane of
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
board of six projects — the backlog's item 12, now built as `CanvasCardShows` — became the thing that
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

## 7b. Making a workspace visible — **built**

§7 settled what a workspace *is*. What was still missing is anywhere to see one, and reading the code
for it turns up four complaints with one cause between them.

- **Saving one produces no visible change.** Run "Save Arrangement…", type a name, press Save, and the
  window is identical. The only evidence anywhere in the app is a new line inside a submenu of the "+"
  button. A save with no feedback reads as a save that did not happen.
- **Nothing says which one you are in.** The readout says `6/43` whether you are in "Dashboard" or in
  something you tiled ten seconds ago and will never want again.
- **The only list of them is inside the new-tab menu**, which conflates *switch to this workspace* with
  *open another tab*. Going from Dashboard to Review means opening a tab, and a way of looking should
  not multiply views.
- **You can make them and never manage them.** No rename, no duplicate, no delete —
  `CanvasArrangements.remove` exists and has no callers anywhere in the app. The dead function is the
  tell: the store was built for a UI that was never finished.

Under all four: **a workspace is the only major object in this app with no representation of itself on
screen.** A card is a rectangle, a frame is a labelled rectangle, a tab is a chip. A workspace is a
string in a submenu.

### The readout is the workspace

One move fixes all four, and it needs no new chrome. The title pill already answers "what am I looking
at" and already carries the tiled state as `6/43 ✕`. That slot shows the workspace's **name** when it
has one, and it becomes a **menu**.

- Naming has a visible effect: `6/43` becomes `Dashboard`. The first complaint is fixed by the same
  change that fixes the second.
- The menu lists every workspace on this board with the current one ticked — **including `Untitled ·
  6 tiles` when you have not named it**, which is how "ephemeral unless named" gets rendered rather
  than merely being true.
- Rename, Duplicate and Delete hang off that menu, on the object they act on.

> **Superseded by §7i.** The pill has no readout and no menu at all now. Both moved to the row: the
> canvas is a permanent chip, every workspace is a chip, and the row answers "what am I looking at" at
> a constant width, which the pill could not while it was also the thing that gave way. What the pill
> kept is the name of the board and the ✕, which now shows the canvas rather than untiling anything.

**Losing the count costs nothing**, because the two never compete. `6/43` answers "how much of the
board am I seeing", which matters most immediately after an ad-hoc ⌘↩ — exactly when there is no name
to show. Count when unnamed, name when named, so the readout says which *kind* of workspace you are in
by which of the two it is showing. The count moves to the help text.

**"Save Arrangement…" stops being a save.** It becomes "Name This Workspace…", which is what it always
was: the promotion from the volatile store to the durable one that §7 describes. Nothing is copied; one
thing acquires a name.

Tabs are not replaced by any of this and are not in competition with it. The tab bar answers *which of
my open views am I in*, and is already good at it. This menu answers *what exists on this board*,
including what is not open anywhere. The "+" menu keeps its section, renamed, still meaning "open in a
new tab" — an act that is now clearly distinct, because switching lives somewhere else.

### Adjusting one is not saving one

**A named workspace is live.** Drag a tile, pin a width, promote a master, switch to grid — it lands on
the workspace as you do it. No Save, no dirty mark, no Revert. This is §4's decision applied to a
second object: a thing that both writes as you work and offers to discard is lying about one of the
two, and this app has stopped doing that.

**⌘↩ is the exception, and it is the only one.** "Fill Window with Selection" does not mean "adjust
this"; it means "these cards, now" — it is the act that made the workspace in the first place. So it
starts a fresh **Untitled** workspace and leaves the named one exactly as it was, one click away in the
menu. That line is not arbitrary: every other tiling command is incremental, an edit to the tiling that
is up, and ⌘↩ is the one that replaces the set wholesale.

Worth stating the cost plainly, because it is real: **a tiling has no undo.** It is view state, not a
document change, so `store.change` is not involved and ⌘Z will not bring a removed tile back — you
re-add it by hand. That is survivable at this scale (nothing is destroyed but a layout, and the cards
are all still on the board) and it is what makes the ⌘↩ carve-out load-bearing rather than tidy: it
keeps the one destructive-feeling act off the named thing.

### What it needs that does not exist

**One field.** `CanvasViewState.workspaceName: String?` — which named workspace the tiling that is up
*is*. `CanvasFocus.arrangement(name)` is not that: it is a tab pin, and a board tiled ad hoc in a
whole-board tab has nowhere to record a name today. The field is what the readout reads, what the tick
in the menu compares against, and what ⌘↩ clears.

**No keys, deliberately.** ⌘1…9 is free and is the obvious slot for "go to workspace *n*" — and it is
also every browser's shortcut for selecting a tab, and this app has tabs. [Backlog
17](canvas-backlog.md) says decide the navigation grammar before adding a single key, and spending
⌘1…9 here would be spending it on the losing side of a question that is already open. ⌃1…9 stays with
frames. *(§7c settled that question — a tab is where an open workspace lives, so the two sides turned
out to be one — and §7h spends the keys on Go to Tab. It also found that ⌘1 and ⌘2 were not free.)*

### What shipped, and the two things it decided on the way

The readout is `CanvasTitlePill.workspaceMenu`, the list also lives in View ▸ Workspace (nine slots
retitled on validation, exactly as Go to Frame does it), and the write-through is
`CanvasPaneController.keepNamedWorkspaceUpToDate`. Two rules were settled by building it:

**Naming and renaming are one command.** A workspace that has a name cannot be named again, so the item
retitles itself to "Rename …" — `tileCommandTitle`'s pattern. The alternative was letting Name run on a
named workspace, where it would leave the old one behind and put you in a second one: a duplicate,
arrived at by picking the wrong item. Duplicating deserves to be asked for, which is item 10.

**Renaming and deleting break a tab pinned to the old name**, and that is accepted rather than fixed.
*(§7c fixed it for this window; §7h stopped a rename from landing on a name that already has a chip.)*
The name is the whole of a workspace's identity — there is nothing underneath to keep pointing at — so
a pin that no longer resolves lands on the whole board, which is what `applyFocus` has always done for
a frame deleted in Obsidian. Following the pins would mean reaching into every window's stored tabs to
rewrite a string, for a case the existing fallback already handles quietly.

## 7c. A workspace's home is a tab — **built**

§7b gave a workspace a name you could see. It left two things unfinished, and they turned out to be one
thing: **the commands and the object had drifted apart.**

- **A workspace's verbs were sitting in the tile menu.** View ▸ Board ran `Fill Window with Selection`,
  `Arrange Tiles`, **`Workspace ▸`**, then `Make This the Master Tile`, `Pin Tile Width`, `Remove from
  Tiled View` — the workspace submenu sandwiched inside the tile group, every item of it a
  `#selector(CanvasBoardView…)`. Promote, pin, remove and rearrange are verbs on a *tile*. Name,
  duplicate and delete are verbs on the *identity of a whole set*. They shared a receiver and a menu
  group, and nothing in either says why.
- **There were two ways to be in "Dashboard", and they drew differently.** `CanvasFocus.workspace(name)`
  — a tab pinned to it — and `CanvasViewState.workspaceName` — the board's live answer — were both
  telling you which workspace you were in. A pinned tab's chip said `Dashboard · 6/43`; a plain board
  tab that had switched to it from the readout's menu said `Canvas · Dashboard`. Same board, same six
  cards, two chips. That is the shape of fault §7b diagnosed one layer down, surfacing one layer up.

### The tab is the workspace

The fix is one claim: **a tab is where an open workspace lives**, and everything follows.

- **The pane's `workspaceName` is the answer, and the tab is made to agree with it.** Name the workspace
  a plain board tab is showing and that tab *becomes* the workspace's tab; ⌘Return out of one and it
  stops being it. `reconcileWorkspacePins` is the whole mechanism, and it runs from the one funnel that
  already existed. Only named workspaces move a pin — an unnamed one has no name to point at, which is
  what unnamed means, so a tiled board tab stays a board tab and a tiled frame tab stays on its frame.
- **The chip carries the commands**, on right-click, which is where a Mac keeps the verbs for the thing
  under the pointer. `WorkspaceCommands` is written once and shown in two places, because one tab is no
  tabs: a window with a single board has no bar and no chip, and the title pill's readout carries the
  same menu until a second tab makes the bar appear. That is the handoff the readout itself already
  makes.
- **The menu bar keeps its mirror**, moved out of the tile group and set beside `Go to Frame` — the
  other "go to a named set of cards", which is the thing it is actually like.
- **Switching goes to the tab a workspace is already open in.** Two chips on one workspace are two names
  for one thing, and choosing between them is a question with no answer. It is the same call
  `WindowManager` makes for a project that already has a window.

**An unnamed workspace gets a chip too**, reading `Untitled` — the same word the menu uses for it. That
is "ephemeral unless named" rendered a second time, and it is what makes the bar readable as a row of
workspaces rather than a row of two kinds of thing. The whole *untiled* board keeps saying `Canvas`,
because a board is not a workspace: a workspace is a set of tiles (§7).

> **Superseded by §7i.** There is no unnamed workspace: every tiling is made named. The paragraph's
> instinct was right and its conclusion was backwards — a row of two kinds of thing is the problem, and
> the fix is to stop making the second kind rather than to give it a word. `Canvas` is right and is
> now a glyph on a permanent first tab rather than a name a chip can acquire.

### A chip is a name, and it is yours

The first chips carried three things: a glyph, the name, and a `6/43` badge. Two of them went.

- **The glyph** told a frame called "Research" apart from a workspace called "Research". That is a
  collision that is rare, that the chip's own menu resolves the moment you ask, and that was costing
  every chip in the row a symbol to guard against.
- **The badge** said how many cards the tiling holds — a fact the board underneath is showing you at
  full size. It was carrying the ✕ out of the tiled view, which is the one thing that had to be
  rehoused: `Leave Tiled View` is now an item on the chip's menu, on the current tab only, since it
  acts on the board that is up.

What is left is a name, which is what a tab is — **all of it**, whenever there is room. A flat 168pt
ceiling on a chip used to truncate "Detective Depictions" in a window with space for three more of it,
which is a cap firing on the name's length rather than on the room available. The room decides now: the
bar sizes to its contents, is the thing that gives way when the header runs out (`CanvasPaneController`
sets that priority), and only then does a label shorten — the current tab last, since a row where every
name shortens together is a row where the one you are in has stopped saying which it is.

Two things follow from a row of names:

- **Drag one along the row.** `ProjectTabSet.move` was written for this and tested before there was
  anything to call it — "that one goes *there*", the same operation spelled the same way as
  `CanvasTileSession.move`. The row reorders as the drag crosses each chip rather than promising an
  order with an insertion line.
- **Double-click one to rename it.** On the tab you are in, and only on a workspace: the tabs that are
  not workspaces are named after what they show rather than by you. A named workspace is renamed and an
  unnamed one is *named* — the same fork `WorkspaceCommands` draws, arrived at by typing instead of by
  picking. Return commits, Escape abandons, clicking away commits. The menu keeps its item, because a
  rename you can only reach by knowing to try is not a rename anybody finds.

### What ⌘Return does now, and why it is a new tab

§7b's one carve-out was that ⌘Return starts a fresh unnamed workspace instead of adjusting the named one
— the guard that makes live adjustment safe where there is no undo. It worked, and you could not see it
work: the chip changed under you and Dashboard was gone from the window.

**So the workspace being left keeps its tab.** ⌘Return opens a chip for it *behind* the pane you are
looking at, and that pane becomes the Untitled one — that way round because the pane in front of you is
the one holding the selection the command just acted on. Dashboard is then a click away in the bar
rather than two clicks away in a menu, and §7b's protection is a thing you can see rather than a rule
you have to be told.

Duplicating has the same shape for the same reason: the copy arrives in its own tab. **Every act that
*makes* a workspace makes a tab; switching between them makes none.** That is the line, and it is why
"a way of looking should not multiply views" survives intact — that sentence was about switching.

### Duplicate, which is backlog 10 and the last of §7b

`ProjectSplitViewController.duplicateWorkspace(named:)`, seeded `Dashboard copy` and counting past the
copies that exist. Copied from the *store* rather than from a board, so a workspace you are not looking
at can be duplicated from its chip — and for the one you are in they are the same bytes anyway, because
the write-through keeps the durable row level with the screen.

It is worth saying what it is for, since it looks like a convenience: §7b made a named workspace **live**,
so "let me try something without wrecking this one" had no answer at all until this. And Name This
Workspace… deliberately stopped being that answer, renaming instead of leaving the old one behind —
because arriving at a duplicate by picking the wrong item is not the same as asking for one.

### One cost §7b accepted, now partly paid back

Renaming used to break every tab pinned to the old name, on the grounds that the name is the whole of a
workspace's identity and a pin that stops resolving lands on the board. That is still true of pins in
*other* windows. It stopped being true here: this window knows every chip on the old name, so
`renameWorkspace(named:to:)` carries them across in the same act — and it is the one place both the
prompt and the chip's own field arrive at. The rename is a remove and a save
still — there is nothing under the name to re-key — with the save first, so a failure leaves you with
both rather than neither.

**What it needed that did not exist:** nothing in storage. `CanvasFocus` is unchanged, wire format
included, and no new key was added — the two stores §7 argued for already lined up with the two kinds of
chip, because a board's one volatile row *is* its unnamed workspace and a named one already had a
durable row of its own. The one thing that had to be pinned down is that a pane goes on owning that row
after its tab acquires a name (`CanvasPaneController.ownsViewMemory`), or naming a workspace would have
quietly stopped the board remembering its connect mode.

## 7d. The note-only view, as a workspace with one card on it — **built**

A project window has two shapes: its notes and its board. That was always one shape too many. A card
already *is* the project window's notes — `CanvasProjectNote` renders them with the window's own pieces,
against the window's own store and undo stack — so "the notes" is a board tiled to that one card, and
the second renderer is a thing the app keeps because it had it first.

Two things stood in the way, and only one of them was real.

- **A project might not have a `.canvas`.** It turns out this was answered before the question was
  asked: `PMStore.openableCanvasPath` writes one on demand, and says why in its own words — "a project
  is assumed to have a canvas, so opening one is never a two-step ceremony". `createProjectCanvas` puts
  the project's own card on it. So the board a notes tab would become always exists by the time it is
  asked for.
- **The card could not do everything the column does.** This one was real, and measurable: task
  multi-select and the bulk actions that hang off it, drag-to-reorder, and ⌘F. Switching before closing
  that would have been calling a regression a simplification.

### What closed it

- **Selection.** `RowSelection` — the rules written down once, as a value with hostless tests, on the
  same argument `ProjectTabSet` makes. The window's list had them inline; a second copy on the card
  would have been two answers to "what does ⇧-click do" waiting to drift. Writing the tests found a bug
  the inline version had: ⇧↑ on a range built downwards grew it upwards instead of shrinking it,
  because the extending step was leaving from the same end a plain step leaves from. A range has a
  fixed end and a moving one, and the fixed end is the anchor.
- **The bulk actions came free.** `TaskMenu` has taken a `targets` list since the window grew one; the
  card was simply passing it nothing. `TaskDeleteConfirmation` moved out of `ProjectView` and is now
  put up by both — and it earns its place on a card for the reason it earned it in the window, which is
  that the subtasks riding along are the part you cannot see from the rows you picked.
- **Drag-to-reorder.** The geometry was already extracted (`TaskDropResolver`, `ListDropDelegate`), so
  the card supplies its own metrics — half the window's indent step, because a card is a narrower
  column — and gets the same resolution, the same insertion mark, and the same "drag right to indent".
  Only the app's own task type: a file dropped on a board becomes a card, and a card that quietly ate
  that drop would make where you let go matter in a way nothing says.
- **Find, on the rule that was already there.** The board's find has always looked *inside* the thing
  you have stepped into when that thing is a page card, and at the board's cards when it is not. A
  project card is the third case, and it narrows its task list exactly as the window's find bar narrows
  the same list. No new bar: the field in the header is the field, ⌘F is how it opens, and ⌘G walks the
  narrowed list because a shortened list is what the matches are.
- **The Incomplete filter was already there** and is called something else. `CanvasCardShows.completed`
  is the card's version, per card and kept in the file, which is the bargain every other card setting
  made. Adding a second app-wide one would have been the two-spellings fault again.

### The flip

`ProjectTabView.notes` still exists and still goes on the wire — it is what every stored tab says, and
it is the honest name for "this project's notes". What changed is what it *builds*: a
`CanvasPaneController` on `CanvasFocus.note`, which is the board tiled to the project's own card and
nothing else. So the case stayed and the renderer went, which is the cheaper half of the same trade
§7c made: no storage change, and nothing anybody set comes back wrong.

- **The card is put back if it isn't there.** Every board `createProjectCanvas` writes starts with one,
  and taking it off is a thing you can do — but "show me this project" cannot depend on a card somebody
  dragged to the bin. It is the same act the add menu offers, and it lands in the document, because the
  note-only view is a board tiled to a real card and not a special case pretending to be one.
- **The project gets a canvas, on opening its window.** This is the convention
  `PMStore.openableCanvasPath` has stated in its own words since long before this: *a project is assumed
  to have a canvas, so opening one is never a two-step ceremony*. What is new is only that the notes are
  now the thing that asks. It is quiet in both directions — no dialog on success, and no dialog on
  failure either, where the old task column stands in instead. **A fallback is not a second answer**: it
  is what a broken file gets, the way the empty state is what no file gets.
- **The card is stepped into from the start.** New Session, New Task, Edit Details and find all ask
  which project you are standing in, and a view whose entire content is one project should not need a
  click to admit which. `engage(cardWithID:)` does what a click on a tile does, without the click.
- **Two commands were off in this view.** Leaving the tiled view would have left a tab called "Notes"
  showing the whole board, and naming it as a workspace would give the app a second name for a shape it
  already names. §7e took the first of those back; the second still stands.
- **The tiled readout was off too**, for the same reason, and §7e turned it back on.

**And the buttons.** The card has New Task and New Session beside its title — the first controls it has
grown, and the rule they break was worth breaking. Everything else here is reached the way the window
reaches it, on the grounds that a card with buttons the window has not got would be saying the two
surfaces are different things. They are not two surfaces any more.

### The keyboard, which §7d left undone — **built**

↑/↓ and ⇧↑/⇧↓, ⌘A, ⌘⌫, ⌘C, ⌘V and Return. §7d called this a question with an obvious answer, and the
answer turned out not to be the `isProjectNoteView` flag it expected: **it is the rule find and the zoom
commands already follow.** Inside a card, a command means the card.

So the keys are decided at the board (`CanvasBoardView.projectCardTakes`, `selectAll`, `copy`, `paste`)
and handed to the card you are standing in through `CanvasProjectCardCommands`, the seam the board
already used for New Task and New Session. Not from inside SwiftUI, and that is the load-bearing part:
a card claiming ⌘A from its own view hierarchy would claim it for the whole window whether or not you
were standing in the card, which is the fault the window's own hidden shortcut buttons had to be talked
out of. It also fixes something nobody had noticed — with the keys unclaimed, ↓ in a project card
bubbled to the board and *nudged the card across the document* while you read its tasks.

Three deliberate exceptions, each written down where it is made:

- **⌥ arrows stay the board's.** Moving between cards is the gesture a tiling manager is built around,
  and it is still worth having with a card open.
- **⌫ with no rows picked out is the card's own delete.** Not a delete of nothing — that is what the
  board would have done anyway, which is why the card publishes `selectedRows` for the board to ask.
- **⌘V is decided by the pasteboard.** A copied card has no meaning in a task list and a copied
  paragraph has none on a board, so each surface takes what it can use, and the board's own clipping is
  recognised as one first.

A text field being first responder while you type is not checked anywhere. It does not have to be —
that is how the responder chain already works, and it is why these can be unconditional.

### What the column was still for — **answered in §7f**

`ProjectView` was not the project's notes any more, but it did not turn out to be only a fallback
either. It was doing three jobs, and the card superseded one of them:

1. **The task column** — superseded.
2. **The no-project window.** `pm`'s cold start opens a window on `PMFiles.focusedProjectKey()`, which
   is nil until something is focused, and "No focused project" plus its hint was that screen.
3. **Where a store's load error is read.** `store.errorMessage` had no other surface.

And the fallback was not decorative: a project's tasks live in its **markdown**, not in its canvas, so
a `.canvas` that will not parse was one UI coupling away from "I cannot reach my tasks". Retiring the
column meant answering all three, which §7f does.

## 7e. Every project has a note and a canvas — **built**

§7d left the window holding a control it had stopped needing. If the notes are the board tiled to one
card, then the board is that view zoomed out, and a two-position switch saying *which of this project's
faces am I on* is answering a question the app no longer asks. Two faces became one board at two
scales.

### The switch is a claim about the world, so fix the world first

The switch could only go once the thing underneath it was reliably there, and it was not. Two
invariants that the code stated in prose were enforced in only one direction:

- **The canvas.** `ProjectCanvas.swift` opens by saying *"every project is assumed to have one, or to
  want one: there is no 'does this project do canvases?' question anywhere above this file"*, and
  `openableCanvasPath` makes one on first ask. True — except the ask could go unanswered:
  `openableCanvasPath` returned without calling its completion when a loaded store had no project path,
  which under §7d is a window waiting on a file for ever with its in-flight latch stuck. It reports now.
- **The note.** Every project has notes — `createProject` scaffolds them, and `ProjectCanvas` cites
  their creation as the precedent for its own. Except `resolveNotesHandle` *threw* `.notesNotFound`,
  which is a report of a broken invariant handed to somebody who cannot act on it. It creates now, from
  the template, in the one place every read and write already comes through.

An invariant asserted in a comment and thrown at runtime is not an invariant. These are the two files
the whole design rests on, so they say the same thing twice now instead of once each way.

### What the switch cost, and where it went

Removing a control is only free if nothing was using it, and two things were: it was the way *out* of
the notes, and it was the only thing on screen in a one-tab window saying the project had a board at
all. Both went to the pill's tiled readout, which was already there and already saying half of it.

- **Out** is now the board's own vocabulary — the readout's ✕, ⌘↩, and ⌘−, which is the one key that
  had nothing to say in this view (a file card does not zoom its content and a tiled board's zoom is
  fixed) and which everywhere else means exactly this: one step further out.
- **In** is tiling the project's own card, by ⌘↩ or from its tile menu. No new gesture, and no new
  place to look.
- **The tab renames itself on arrival.** This is what made leaving safe, and it is `ProjectTabView`
  `.following(workspaceName:showingProjectNoteAlone:)` — the rule that a tab is what its board is
  showing, which §7c already applied to named workspaces and which now covers the other end too. A
  workspace of exactly the project's card *is* the notes, however it was built; nothing has to remember
  which door you came through. Only the three views with no identity of their own move: a frame stays
  on its frame and a name stays on its name.

`isProjectNoteView` became derived rather than declared, for the same reason — it was set once on the
way in, which was fine while the way out was a button somewhere else.

### And the branches that assumed otherwise

With the invariant real, the "what if not" cases stop being cases:

- **`ProjectCanvasEmptyState` is gone.** It offered to create a canvas, and argued for itself on the
  grounds that *switching a view must not write to disk*. Under §7d opening the window already does,
  so the page was offering a choice that had been made before it appeared.
- **One fallback, not two.** Every tab makes a board and falls back the same way, so `makeContent` is
  short and `makeBoardless` holds the whole argument: wait while it is being made, and answer when it
  cannot be. `canvasUnavailable` went from incidental to load-bearing — with no empty state left to
  land on, it is the only thing between an unwritable vault and a window that waits for ever.
- **The column keeps its own switch off.** The column is what you get when the board *failed*, so a
  control offering the board would be offering the thing that just failed.

The column itself is still there, and is the last piece: once the card carries the list's keyboard
there is nothing in it the board does not do.

## 7f. A canvas that will not open is a file to fix, not a state to render — **built**

The column outlived the switch by one release because deleting it looked like a deletion and was not.
Its three jobs (§7d) were answered separately, and only after the third one stopped existing.

### The asymmetry was the tell

Four situations reached the same place — the window cannot show you this project — and they were
answered by wildly different things:

| Situation | What it got |
| --- | --- |
| The board is still being located | A blank pane, deliberately; it is milliseconds |
| The canvas will not parse | **The entire old application** — a working task list, header, quick add |
| `store.errorMessage` | One grey sentence, inside a column's chrome, headed "No focused project" |
| No project focused at all | The same sentence, plus a hint naming a key |

Nothing about that was a decision anyone made. It is where the code sat when the column *was* the
window: a broken file got a complete alternate app, and a project that would not load got a sentence
wearing that app's costume.

### The canvas case is the only one that mattered

The other three are messages. This one was a capability: with the column deleted, a `.canvas` with a
stray comma in it would cost you access to tasks that are not in the canvas at all.

Three ways out were on the table — show the error and accept the loss; give the card a second host with
its own header, find and key routing; or **refuse to have a broken canvas**. The third is the one the
declaration in §7e already implies. Every project has a canvas; a file that will not parse is not one.

So `PmLib.replaceUnreadableCanvas` moves it aside — same folder, same name, `.unreadable-<date>`
appended — and writes a fresh one in its place, and the pane that opens says so and offers **Show in
Finder** for the old file. Nothing is destroyed, and the fourth row of that table stops existing.

Two details are load-bearing:

- **The suffix goes after `.canvas`, not before it.** `resolveProjectCanvasPath` adopts a lone board in
  a folder and declines when there are two, so a kept file still named `*.canvas` would leave the
  project unable to say which of the two was its board — including the fresh one just written for it.
- **Once per project per window.** A second failure straight after a replacement is not a broken
  canvas, it is a vault that cannot be written to, and rewriting the file again would not help. That
  falls through to the pane below.

And it is only ever the *project's* board. A window opened on a `.canvas` file is looking at somebody's
document; rewriting one of those because it failed to parse would be a great deal to do to a file you
were only asked to look at, so `WindowManager.open(canvas:)` still reports those instead.

### The other three collapse into one small pane

`ProjectTrouble` is a pure function from *(is there a project, did it load, which key is bound)* to two
lines of text, and `ProjectTroublePaneController` draws them centred with no chrome. No header and no
tab bar: everything a header offers acts on a board, and there is no board — a window that draws its
full furniture around a failure is claiming to be working.

### The window's width cap went with it

The cap was the last thing in the window still arguing about a task list: a list gains from every extra
row it can show and nothing from being stretched sideways, so the window stopped widening at 1120pt and
refused full screen — the green button reverting to plain zoom being the honest affordance for a window
with a maximum.

Every tab is a board now, and a board is a plane where every point of width is more of it you can see.
So the cap was not merely obsolete, it had turned harmful: it was re-applied whenever a tab changed what
it was showing, which meant **zooming out of the notes pulled the window in under your hands**. Resizing
somebody's window is a thing to do when they ask, and leaving the tiled view is not asking. Gone, along
with `maxWindowContentWidth`, `maxListWidth`, and the `.fullScreenNone` that came with them.

### The cold start is not a message at all

The last of the three was the best one to reconsider rather than port. ⌘N with nothing focused used to
give you a window whose content was a sentence telling you to press another key to make the window
useful — while the list of projects sat in the same window, one toggle away.

So a window with no project **reveals the project list with the keyboard in it**. That is the key,
already pressed. `browseAllProjects` had been doing exactly this all along; it is now what a
projectless window *is*. A window opened on a canvas file is not projectless in this sense — it has a
document — so it is left alone.

### What came out

`ProjectView.swift` was 3,773 lines. The `ProjectView` struct and everything private to it is gone;
what other surfaces were already borrowing moved out to files of its own name:

| Went to | What |
| --- | --- |
| `ProjectDetails.swift` | `ProjectDetailsView` and its editor, used by the card |
| `SessionNoteTakeover.swift` | The takeover and the three layout helpers it needs |
| `MouseMonitors.swift` | The four AppKit monitors, all four used by the card |
| `RowSelectionBand.swift`, `ReadableWidth.swift` | The two shared bits of row metrics |
| `DisplayModes.swift` | `TasksMode` and `AppColorMode` — neither was ever about the column *(wrong about `TasksMode`: the column was its only reader, and §7h retired it)* |

`ProjectViewState` became `ProjectWindowState`, having shrunk to what the sidebar shares with the
window, and lost two members with it: `focusedPane` and `isEditingText` were both write-only once the
column left. They existed because a SwiftUI `.keyboardShortcut` is offered a keystroke before the main
menu is, so the column's own ⌘A / ⌘C had to be told by hand to stand aside for a text field. The board
answers those from the responder chain, where a focused text view is already ahead of it — which is the
rule the flag was imitating. `TextFocusWindow` keeps its token field editor and nothing else.

## 7g. Opening a project shows its workspaces — **built**

§7c settled that **a tab is where an open workspace lives**, and that every act which *makes* a
workspace makes a tab. That is the right story on the way out and the wrong one on the way in.

A workspace you built last week, named, and then zoomed out of before closing the window still exists —
and had no chip. `ProjectTabView.following` un-pins a tab the moment its board stops being that
workspace (§7e), which is honest about what the tab is showing and leaves the workspace reachable only
through a menu. So opening a project showed you none of the work you had named.

**The row is the project's workspaces now, not only the ones the window was left holding.**
`ProjectTabSet.include(workspaces:selecting:)` puts a chip on the row for every workspace that has none.
Existing tabs keep their places — the row can be dragged into an order and that order is the user's —
and newcomers land after them in the alphabetical order `CanvasWorkspaces.names` hands over, which is
the order you would look one up in. A workspace that already has a tab gets no second one, for §7c's
reason: two chips on one workspace are two names for one thing.

**And the one you were last in is the one that comes up.** That cannot be read off the stored tab
selection, because leaving a tiled view un-pins the tab: the last thing you did in Dashboard was leave
it, and the selection records the whole board. So `CanvasWorkspaces` keeps a `lastUsed` name per board,
written from `refreshTabModel` — the one funnel both ways of arriving in a workspace pass through,
clicking a chip and naming the one you just built. It is validated on read rather than kept tidy on
write, so a workspace deleted in another window answers nil instead of every delete having to come here.

**Leaving one keeps its chip.** ⌘Return already did this (§7c: "the workspace being left keeps its
tab"), because starting a fresh workspace should not make the named one vanish. The same is now true of
the other way out — zooming out of Dashboard leaves a Dashboard chip beside the tab you zoomed out in —
which is what makes the row consistent within a session rather than only at the moment of opening.

**Seeded, not enforced.** A chip you close stays closed for the session and comes back next time you
open the project, because the row is a view of what exists. Closing a chip is not deleting a workspace;
that verb is on the chip's own menu and always has been.

> **Superseded by §7h and then by §7i.** §7h made the close durable, which is machinery to keep a close
> from being contradicted by the seeding right above it. §7i removed the disagreement instead: a
> workspace's chip *is* the workspace, so there is no close — Delete is the verb, and it takes the chip
> with it.

## 7h. What the row cost, once there was one — **built**

§§7–7g built the object, gave it a name, a home, and a chip that arrives with the project. Read back as
a whole, they left a system whose parts were each right and which had picked up four kinds of debt
between them: a set of acts that could destroy work with no undo and no question, a row that could not
hold what §7g put in it, two stores answering one question, and a set of exits that disappeared exactly
when they were needed. None of these is a disagreement with the sections above; all four are things
those sections made true and did not go back to.

### Naming was a destructive act nobody had noticed

`CanvasWorkspaces.save` replaces, and §7b argued for that: a named workspace is **live**, so dragging a
tile has to land on it without a Save. What the argument covers is the write-through. The same call is
also how a name is *acquired* — Name This Workspace…, a rename, a duplicate, the chip's own field — and
there the thing being replaced is not the workspace you are looking at. Typing "Dashboard" into an
untitled chip ended last week's Dashboard, silently, with nothing to undo it.

**The fix is the Finder's question**, on the three paths that acquire a name and not on the
write-through: one name, two things, only one can keep it. And the same argument, one step further,
applies to the verb that had no question at all. §7c put Delete on the chip's contextual menu two lines
above Close Tab; the reasoning for not asking — "what is on screen is untouched, a deleted workspace is
one that has stopped having a name" — is true and is half the story. The tiles survive; the workspace
does not, and the workspace is the thing the row is a list of. Both now ask, and both say what survives
rather than only what goes.

### A rename could make the state §7c says has no meaning

"Two chips on one workspace are two names for one thing, and picking between them is a question with no
answer." `openTab` has refused to make a second chip since §7c. `retarget` cannot refuse in the same
way — it is how a tab *follows* its board — and the collision only exists afterwards: rename "Review" to
"Dashboard" while Dashboard has a chip and the row now says Dashboard twice; delete a workspace two tabs
were in and both land on the whole board and both say Canvas.

`ProjectTabSet.collapseDuplicates` is the sweep the two bulk retargets do behind themselves. The
leftmost chip survives, because the row has an order and it is the user's, and a selection on a chip
that goes moves to the survivor so the window is still showing what it was showing.

### The row outgrew the header §7c fitted it into

§7c is emphatic that a chip is as wide as its name — the flat 168pt cap "fired on the name's length
rather than on the room available, which is the one thing a cap in a header should never do" — and the
bar is deliberately the header's give-way, the thing squeezed against the trailing controls. Those two
were a matched pair for the handful of tabs you had opened by hand. §7g changed how many that is: the
row seeds a chip for every workspace the board has, with no gesture involved, so a project with eight of
them arrives with eight chips and "give way" means every name in the row shortening to a sliver at once.

**So the bar gives way by clipping rather than by squeezing.** The chips sit in a horizontal scroll view
capped at their own measured width, so a bar with two chips is still two chips wide and never a strip
across the window; past that the overflow is one scroll away and the selection is always scrolled to,
since a tab you reached with ⌃⇥ that stayed off the end of the row is a switch you have to go looking
for. A chip is as wide as its name again, and stays that way at any count.

**And an untitled chip carries its count again.** §7c dropped the badge because the board underneath was
already showing you the tiles at full size — true of the chip you are looking at, and not true of the
two beside it. A row with three chips all reading `Untitled` is a row you have to click through to read,
so an unnamed workspace says `Untitled · 6`, which is the pill's own rule (name when named, count when
not) applied to the chip. A named chip still says only its name; it has one.

**Closing a chip means it.** §7g called the row "seeded, not enforced" and let a closed chip come back
next launch, on the grounds that the row is a view of what exists. But the control is an ✕, and on this
Mac an ✕ on a tab is a promise that it stays shut. The set remembers the workspaces you have said no to,
opening one again retracts it, and closing is still not deleting — that verb is on the chip's own menu
and now asks first.

### Two stores answered "which workspace was I in"

§7g added a `lastUsed` name per board because leaving a tiled view un-pins the tab, so "the tab
selection alone cannot answer which workspace was I in once you have zoomed out of one." That premise
was made false by §7g's own next paragraph: **leaving one keeps its chip.** The row still holds the
workspace; the selection records that you were looking at the whole board, which is what you were
looking at. A second store could only disagree with the first, and it did — spend the evening in a
project's notes after an hour in Dashboard, close the window, and it reopened in Dashboard.

The store is gone and the selection is the answer, which is §7c's rule read the way round it was
written: **a tab is where an open workspace lives**, so the tab you left selected *is* which workspace
you were in, including when the honest answer is "none of them".

### The ways out went missing one at a time

A tiled view had, on paper, four exits. In the ordinary case it had one, and it needed a pointer and a
contextual menu.

- **⌘↩** is the way out "only when there is nothing left to narrow to". Clicking a tile selects it
  (that is what made a tile clickable in the first place), so after the most ordinary interaction in a
  tiled view ⌘↩ means *fill the window with this one*.
- **Escape** stops at the root, deliberately and rightly: it is the key that cancels an edit, and every
  cancelled edit should not be one keystroke from tearing down a workspace.
- **The pill's ✕** was handed to the tab bar by §7c the moment a bar existed. The bar has no ✕ — it has
  a menu item. And §7g made "a bar exists" the ordinary case.
- **View ▸ Leave Tiled View** had no key equivalent at all.

Two changes, both of them arguments already written down and not followed far enough. The ✕ **stays on
the pill whenever there is a tiling to leave**: §7c's objection was that a pill saying "Dashboard"
beside a chip saying "Dashboard" says it twice, which is true of the *name* and is not an argument about
a button. Only the readout goes to the bar. And **⌘− leaves any tiled view**, not just the note-only
one — `zoomOut` already carried the whole argument ("the thing one step further out from a workspace is
the board, which is exactly what ⌘− means everywhere else") and then applied it to one workspace out of
all of them. It costs nothing: a tiled board's own zoom is fixed, so ⌘− did nothing in every tiled view,
not just in that one.

### ⌘1…9 was being reserved by two dead menu items

§7b left ⌘1…9 unspent "because it is also every browser's shortcut for selecting a tab, and this app has
tabs", deferring to backlog 17: settle the navigation grammar before spending a single key. The grammar
was settled by §7c — a tab is where an open workspace lives, so *go to workspace n* and *go to tab n*
stopped being two claimants — and meanwhile ⌘1 and ⌘2 were spent anyway, on View ▸ Incomplete/All.
Those two, and Show Notes beside them, were switches on the task column; §7f removed the column and
`PMPanelTasksMode` and `PMPanelDetailsExpanded` were left with no reader anywhere in the app. The items
went on ticking a checkmark and changing nothing. (§7f's own table says `TasksMode` "was never about the
column", which is the sentence that let it survive: it was a filter over a list of tasks, and the column
was the list.)

So: the three dead items are gone, and View ▸ Go to Tab has ⌘1…⌘9, nine slots retitled on validation
the way Go to Frame does it, with ⌘9 meaning the last tab however long §7g has made the row. ⌃1…9 still
goes to a frame, and the modifier is still what tells the two words apart.

### Three more that were each one line

- **⌘W took the window**, tabs and all, with no question, while View ▸ Close Tab had no key. `performClose`
  is answered by the window before anything of ours is asked, and a second menu item with the same key
  would never be reached past File ▸ Close — so the window narrows it: ⌘W closes the tab you are in and
  the window once that was the last one, which is what every Mac app with tabs does. ⇧⌘W is the window.
- **"Open in New Tab" on a frame did not exist.** `openSelectedFrameInTab` had been written, was named in
  two places as one of the two ways a tab gets made, and had no callers anywhere in the app. It is on
  the frame's contextual menu now.
- **The bar drew nothing at one tab**, taking the "+" with it — so a window with one tab made no visible
  offer of a second, and the two routes it was documented as leaving that job to were a File menu item
  and the command above. One tab is still no *chips*; the "+" is always there.

Two smaller ones went with them: the current chip wore a permanent ✕ (the chip your pointer is nearest,
and the only one you could hit by accident), and naming from the chip's field started empty while naming
from the menu started at "Grid, 6" — one act, two seeds, and an empty field that reads as "this had no
name" under the word `Untitled`.

## 7i. Every workspace has a name, and the canvas is a tab — **built**

§§7–7h built a row of chips and then spent four sections paying for the fact that not every chip was
the same kind of thing. The row held the notes, the whole board, a frame, a named workspace, and an
*untitled* one — five kinds behind one shape — and every rule that had to be written twice was written
twice because of that. This section removes two of the five, and what is left is a row you can read.

Two claims do all the work:

- **A workspace is a named set of tiles.** Both halves are enforced. There is no untitled workspace,
  and there is no tiling that is not a workspace — except the project-note view, which is a tiling of
  one card that nobody chose (§7d).
- **The canvas is not a workspace.** It is the board itself, untiled: the thing every workspace is a
  narrowing *of*. So it is one permanent tab at the head of the row, drawn as a glyph, and it never
  closes, never moves, and is never tiled.

### The untitled workspace was the source of most of the special cases

"Ephemeral unless named" (§7) was a good description of where a tiling was *kept* — the volatile
`CanvasViewMemory` row versus the durable `CanvasWorkspaces` one — and it leaked outward into a kind of
object. Counting what it cost by the time §7h was finished:

- A chip that had to say `Untitled · 6`, because two of them in a row were otherwise indistinguishable
  — a count on a chip, which §7c had removed once already for being a fact the board underneath was
  showing at full size.
- `WorkspaceCommands` forking on `name: String?`, so the one menu offered "Name This Workspace…" or
  "Rename …" depending on a state you could not see.
- `saveTilingAsWorkspace`, one command under two words, retitling itself on validation.
- `CanvasViewState.workspaceName`, an optional whose nil case meant "tiled, but pointing at nothing".
- `ProjectTabItem.isWorkspace` beside `workspaceName`, a flag existing purely for the chips that were
  a workspace without being a named one.
- And the thing ⌘Return did to get there: clear the board's `workspaceName`, leaving the *named*
  workspace it had been in with no chip — which is what `onLeftWorkspace` and `openBehind` were built
  to repair, inserting a chip behind you on every press.

All six are gone, and one rule replaces them: **⌘Return makes a named workspace and opens its tab.**

### The name is assigned, not asked for

⌘Return is the board's fastest gesture — fullscreen this card, tile those six — so a modal in front of
it would be a modal in front of *looking at something*. `WorkspaceNamePrompt.freshName(avoiding:)`
hands out "Workspace", "Workspace 2", and the chip is renameable in place the moment it exists. That is
the Finder's bargain over an untitled folder: a real name from the start, and the real name is the
thing you type over. It also retires the old seed, "Grid, 6", which was a fair *description* and a poor
name — it goes stale the moment you swap the arrangement, and it puts a count on a chip.

The obvious objection is that ⌘Return is pressed constantly and the store would fill with junk. The
answer is in `ProjectSplitViewController.tileAsWorkspace`: **the same set of cards resumes the same
workspace rather than making a second.** ⌘Return on the six cards you always tile lands in the
workspace you already have, every time, whatever it is called now. This is the job `lastTiling` was
already doing for the *arrangement* — "the same cards as last time means the same arrangement as last
time" — done one level up, for identity.

### A tab stopped following its board, which is where the reflow came from

`ProjectTabView.following(workspaceName:showingProjectNoteAlone:)` was §7c's mechanism and §7e's
renderer switch: the pane was the answer and the tab was made to agree with it. It is gone.

Watch what one gesture used to cost. Zoom out of Dashboard and: the chip renamed itself from
"Dashboard" to "Canvas"; a second chip was inserted behind it so the workspace you had just left did
not vanish; `collapseDuplicates` swept up if that made a pair; and the title pill took its readout back
from the bar, because the bar had gone from two chips to three and `showsTilingSummary` is keyed on
whether there is a bar at all. Four things moved, in the header, for one press of ⌘−.

Now nothing moves. A workspace tab is its workspace for as long as the workspace exists, so leaving one
is not an edit to anything — it is a change of *tab*, and the canvas is a tab. `goToCanvas` is the whole
of it, and it is what the pill's ✕, ⌘−, ⌘↩-with-nothing-left-to-narrow and the menus' "Show Canvas" all
now do. **The pane you were in keeps its tiles**, so coming back to its chip is instant and exact —
which is also why none of this needs an animation: nothing is being undone.

### What the pill gave up

The readout. §7b put "6 of 43 cards" in the pill because a board showing six of forty-three with the
rest hidden looks like a board most of which has been deleted, and that was true when the pill was the
only chrome a tiled view had. §7c then handed the readout to the bar whenever there was a bar, and §7h
had to claw the ✕ back out of that handoff because it had gone along with it.

There is no handoff now. The canvas has a permanent chip and every workspace has a chip, so the row
answers "which of this board's places am I in" at all times and in one place.

**And then the ✕ went too.** It survived one round longer than it should have. §7h had just fought to
keep it — §7c gave the readout to the bar and took the ✕ along with it, leaving a window whose only
click out of a tiled view was inside a right-click menu — so keeping it was right *then*. Once this
section made it mean "show the canvas", the canvas was a permanent chip a few inches to its right, and
a control that duplicates the control beside it is not an escape hatch, it is a second thing to
explain. The pill is the project's name and nothing else, which is the one property worth having here:
it never changes width, so nothing in the header moves when you switch between the board and a
workspace.

### The chip, finally

Four debts, all of them visible, none of them arguable:

- **A capsule full of rectangles.** The bar is a `Capsule`; the chips inside it were 5pt rounded rects.
  Now they are capsules, and the geometry nests.
- **The selected chip was `.quaternary` over `.regularMaterial`** — the faintest fill SwiftUI has, over
  glass, at 11pt. It is `.primary` at 9% now, which is what it takes to be seen through a material.
- **Every chip reserved 17pt on its right for a ✕ it was not showing**, so no label was centred in its
  own box. Only the chips that *have* a Close reserve it now, which is the notes and a frame — the
  canvas and every workspace have none at all.
- **No glyph anywhere.** §7c removed the kind glyph for guarding against a rare name collision, and the
  answer here is not to put it back: the workspaces are names and read as names. The canvas gets the
  one glyph in the row, because it is the one chip that is not a name —
  `rectangle.3.offgrid`, scattered rather than gridded, since the grid is `rectangle.split.2x2`, the
  button that tiles.

And the header's tool capsules drop their glass over a tiled board (`headerBacking(_:in:showing:)`).
The backing exists to hold controls legible over content panning beneath them; tiles are panels with
their own edges on a plain ground, so a second separation on top of one that has already happened just
reads as two surfaces arguing about which is in front.

### ⌘W means the smallest thing you are inside

Three answers, one rule read at three depths, and it falls out of the row having three kinds of tab in
it. A tab with a Close — the notes, a frame — closes. A workspace has no Close, and what you mean by
shutting one is "I am done looking at this", which is the canvas: ⌘W steps out to it, and the workspace
is exactly where you left it when you come back. On the canvas there is nothing left inside the window,
so ⌘W means what it means everywhere else on this Mac. File ▸ Close Tab retitles itself to "Show
Canvas" on a workspace rather than being dimmed, on `tileCommandTitle`'s pattern — a menu item that
says "Close Tab" while stepping out to the canvas is the menu promising something else.

### Close is not a verb on a workspace

A workspace's chip *is* the workspace, so closing one would leave a named thing in the store with
nowhere to be — and the row, which is a view of the store, would put the chip straight back. §7g met
that with a `dismissed` set and §7h made it durable, which is a lot of machinery to make a close
survive being contradicted.

So a workspace chip has no ✕ and no Close Tab. What it has is **Delete**, on its own menu, behind the
question §7h added — and Delete now takes the chip with it, which is the same act seen from the row.
What people mean by "close this" is either "show me the board", which is the canvas chip one click to
the left, or "I am done with this", which is Delete. `dismissed` is gone, and so is the durable key it
had just acquired.

### What came out

`ProjectTabView.following`, `ProjectTabSet.dismissed`, `ProjectTabSet.replaceSelected`,
`ProjectTabSet.openBehind`, `ProjectSplitViewController.reconcileTabsWithTheirBoards`,
`CanvasBoardView.onLeftWorkspace`, `CanvasBoardView.saveTilingAsWorkspace`,
`CanvasBoardView.suggestedWorkspaceName`, `CanvasPaneController.nameWorkspace`, `tileCount`,
`workspaceDeleted`, `hasWorkspaceToSave`, `refreshWorkspaceLists`, `CanvasHeaderModel.workspace`,
`workspaces`, `showsTilingSummary` and the pill's workspace menu, `ProjectTabItem.isWorkspace` and
`editSeed`, and the reads of `CanvasViewState.tiling` and `workspaceName` — the two fields stay on the
wire so an old row still decodes, and nothing reads them.

**One carry-over, and otherwise no migration.** A stored row with no canvas tab is given one by
`ProjectTabSet.init(tabs:selectedID:)`, a stored `dismissed` array is simply not read, and a stored
tiling in `CanvasViewMemory` is not restored — the canvas pane owns that row and the canvas is not
tiled. `CanvasFocus`'s wire format is untouched, `arrangement` included.

The carry-over is which workspace you were in. Before this section a board could be *in* "Main" while
the tab holding it said `.whole`, so a window closed back then stored a selection that lands on the
canvas and loses the thing you were working in. The name is in `CanvasViewMemory.workspaceName`, which
is the only record of it — so `takeWorkspaceName(of:)` reads it once, clears it in the same act, and
nothing writes the field again. Every board answers it exactly once and nil for ever after, which is
what keeps it from becoming the second store answering "which workspace was I in" that §7h took a
section to remove.

## 7j. A new project opens on a Notes workspace — **built**

§7d kept the note-only view a *tab* rather than a workspace, so the app would not have two names for
one shape. §7i then made every other chip in the row a workspace, and that left the notes tab the odd
one out: the only chip that closed, the only one you could not rename, and the only one you could not
tile a second card into. Once the tab bar lost its "+", closing it also left File ▸ New Tab as the
only way back.

So wherever there is a board with the project's own card on it, **the notes are a named workspace**
holding that card and nothing else. A notes tab — a new window's default, or one in a row stored
before this — becomes that workspace's chip rather than gaining a twin, and asking for the notes
(View ▸ New Tab, the renderer switch) goes to it (`ProjectSplitViewController.adoptNotesTab`). The
workspace is found rather than duplicated: one of the card alone is the notes whatever it is called,
and only when there is none is one made, as **Notes** — or Notes 2, past a Notes of yours that holds
something else (`CanvasProjectNoteCard.notesWorkspace`). Any workspace of the project card alone steps
into the card on arrival, as the notes tab always did.

**Every project, not only new ones** — this shipped for new projects first, and that left every
existing window with a closable Notes chip beside a row of workspaces that don't close. `.notes` /
`.note` remain only as the fallback for a project whose board has no card to show.

## 7k. A workspace is columns of tiles — **built**

Add Card from Canvas answered the request it was built for and showed where the model stops. A workspace
is a list of card ids, laid out by one of two formulas, so the only thing that can be said about where a
card goes is its index — and the only place a new one can go is the end. Every capability a tiling
manager is expected to have is a question about *place*: this tile beside that one, this one below,
these two sharing a slot. A list can't answer any of them.

This section was worked out in a playground before a line of it was written here — a working model of
the whole design on example cards, keys and drags included:
[Workspace Tiling Playground](https://claude.ai/code/artifact/cfc421a3-bf11-400f-81c9-62df098ebf56).

### What tiling managers agree on

i3 and sway, bspwm, Hyprland, niri, and on the Mac AeroSpace, yabai and Amethyst, disagree about a great
deal and agree about this:

- **Every act has a key.** Focus in a direction, move in a direction, grow and shrink, even everything
  out, and go back to the last window. This board has the first of those (⌥ arrows) and does the rest
  with the mouse or not at all.
- **You say where the next window goes.** Beside the focused one by default, or at a place marked in
  advance — bspwm's *preselection*.
- **Several windows can share a slot** — i3's tabbed and stacked containers — which is what stops a
  layout from breaking up into slivers.
- **A window can be summoned without joining the layout** — the scratchpad.
- **Layouts are either computed from a list** (dwm, xmonad, and this board today), **or a tree you split**
  (i3, bspwm), **or columns on a strip** (niri, PaperWM).

### The shape: columns, tiles, cards

**A workspace is a row of columns. A column is a stack of tiles. A tile holds one card, or several as
tabs, and shows one of them.** Two levels, not a tree. That is the whole model, and the rest of this
section is what it makes possible.

Two levels covers nearly everything people build with i3 or bspwm splits, and it is what answers backlog
11. BSP was ruled out in `CanvasTiling`'s own doc comment as a scheme for windows that arrive one at a
time, and the backlog's reply was that a tree you *build* doesn't have that problem — but it has another:
under a tree, "the end" is not a place, so adding a card needs a second grammar that names a tile to
split and a direction. Columns have that grammar built in and cost nothing to store: left and right are
a new column, above and below are a new tile in this one.

**Grid and master-and-stack stop being modes and become commands** that fill in columns. After one runs,
the layout is yours: move a tile across and nothing snaps it back. The arithmetic is `CanvasTiling.run`,
which already shares a length among flexible and pinned things, run twice — once across the width for
the columns, once down each column for its tiles.

### A width belongs to its column — **decided**

Today a size belongs to the card (`sizes` is keyed by card id), so a tile carries its width wherever it
goes. Here a column's width is the column's, and a tile's height is the tile's, so a tile moved into
another column takes that column's width, and two swapped tiles swap cards while the sizes stay where
they were.

That is a real change, and it is the right one for this shape. A width that followed a card into a column
of three would have to be either ignored — the column already has a width — or imposed on the two tiles
already there, which is resizing cards you never touched. It is the argument `CanvasTiling.grid` already
makes for why a real grid ignores sizes, taken to its conclusion.

### Where the next card goes

**Next to the tile you are on, splitting it along its longer side** — a wide tile gets a new column
beside it, a tall one a new tile below. This replaces "on the end", whose argument in `add(_:)` was that
the end is the one position you can predict without learning anything. That was true of a list. In a set
of columns there is no end to predict, and "beside the thing I'm looking at" is the prediction everybody
already makes.

**⌥N chooses instead.** An arrow picks a side, T puts the card in the tile as a tab, ⌥ arrows pick a
different tile, and Return opens the board to pick the card. The choice waits until a card arrives, and
it is not saved — `memory(of:)` names what a workspace keeps, and this is not one of them, for the reason
`maximized` isn't.

**While you choose with ⌥N, the place is marked and nothing moves** — **decided**, after using it. It
used to draw the layout the change would produce, with the tiles moved aside around a stand-in. That is
what the drag gave up (below), and choosing with the keys gives it up for the same reason, so the mark is
the drag's: a new column as the side of the whole column — which is what a half-tile highlight got wrong
in the first version of the playground — above or below as half the tile, a tab as its top band. The
boundaries stay live while you choose, since every tile is still where the columns put it.

**A drag moves nothing until you let go** — **decided**, after using it. Dragging a tile by its
handlebar or its tab carries a small proxy of the card; the tile it came from stays where it is,
dimmed; and where it would land is marked on the tiles as they stand — a new column as the side of the
whole column, a tile above or below as half of the tile, a tab as its top band, a swap as the tile
itself (`CanvasTileSession.dropMark`). What the drop would do is written under the proxy, which
travels with the pointer and is always on top, rather than in the mark, which the proxy could cover.
The layout changes once, on the drop. The first version reflowed
the tiles under the pointer as it moved, the way the playground does, and in the app that was
unpredictable, took precision, and disoriented: the target kept moving because the tiles did.

### The board is the picker

**⌥B zooms the workspace out to the board.** Each tile flies back to where its card sits, the workspace's
cards stay outlined and numbered, and a click adds a card or takes it out. Escape goes back in.

This is the visual picker Add Card from Canvas was asked to be, and it has no thumbnails to make. It is
the board at the zoom you would look at it anyway, so a thousand cards cost what the board already costs,
and you find a card by where you put it rather than by reading names. Nearly all of it exists: leaving a
workspace already flies the tiles home and fades the other cards in. The picker is that, zoomed to fit,
with a click that toggles membership instead of selecting and an Escape that runs the way in.

Add Card from Canvas stays in the menus, for the keyboard and for when you know the name.

### Tabs in a tile

**Several cards share a tile and one shows.** Web cards are the case: a ticket beside the dashboard it is
about, two documents you flip between. ⌥[ and ⌥] step through them. A tab that isn't showing is left out
of the layout's `visible` — the mechanism a maximized tile already uses — so switching tabs changes which
card is drawn and does not reload anything.

**Dragging a tab pulls that one card out**, to beside any tile, including the one it came from, or into
another tile's tabs. ⌥T does it from the keyboard, beside the tile it came from. Backlog 8 — "swap the
card in a tile" — is this: add the new card as a tab and take the old one out.

**⌥⌫ takes out the card that is showing, not the tile** — **decided**. Taking a tile out is taking out
each of its cards, and the one you are looking at is the one the command can see.

### Peek is a zoom, not a copy

On the board, Space on a card opens it at a size you can read, and Space or Escape puts it back without
it joining anything. The playground draws a second copy of the card over everything, and the app can't:
a web card moved to a different parent view is a page torn down and started again (`reordering`'s note
in `CanvasBoardView` says so, and it is why a lifted card is raised by layer rather than by re-adding
it). So a peek **zooms the board onto the card** — its own view, the page it is already running, woken
by the budget like any card you zoom into. Return adds it.

### Sizes from what's in them

A window manager can't know what is in a window; the board knows every card's kind. **Size Columns to
Content** gives each column the share of the width the widest card it holds reads at — a page 1024pt, a
PDF 720, a note or a project's card 640, an image 560, a text card 320. Shares, not pins: the columns
still fit the window. A page narrower than 380pt is marked while you drag a boundary, since that is
where a page stops reading and it is the width pinning exists to protect. (The playground had this as a
switch that stayed on; built, it is a command — see step 6 below.)

### The keys — **decided**

**⌥ is the tiling key**, because ⌥ arrows already are, and everything else follows from that: ⇧ moves
the tile that plain ⌥ would move focus to; the zoom keys with ⌥ in place of ⌘ size the tile instead of
the board.

| | |
|---|---|
| ⌥ ← → ↑ ↓ | Focus the next tile over |
| ⌥` | Back to the last tile |
| ⌥[ ⌥] | Previous and next tab |
| ⌥⇧ ← → | Into the next column, or a new one at the edge |
| ⌥⇧ ↑ ↓ | Up and down the column |
| ⌥T | Pull the showing tab out |
| ⌥= ⌥− | Widen and narrow the column |
| ⌥⇧= ⌥⇧− | Taller and shorter tile |
| ⌥0 | Balance |
| ⌥⇧0 | Size the columns to what's in them |
| ⌥N | Choose where the next card goes |
| ⌥B | The board, to pick cards |
| ⌥⌫ | Take out the card that is showing |

**They are the board's only when the board has the keyboard.** In a text card you are typing in, ⌥= types
≠, ⌥[ types “ and ⌥T types †, as they do everywhere else on the Mac, and taking them away from a text
view would be taking three characters away from somebody's writing. That is the rule the card's
keyboard already works by — a text view is first responder while you type, so none of the board's keys
are reached — and it is why the table needs no second modifier.

### What is saved

`CanvasViewState.Tiling` gains `columns`, beside the fields it has. The old fields go on being
**written** — `ids` column by column, an `arrangement` read off the shape, `masterFraction` — so a build
from before this section still opens a workspace saved by one after it, and lays it out its own way. A
tiling saved before this section has no `columns`, and is converted once when it is restored, by running
its arrangement: that needs the window, because a grid's column count comes from the window's shape,
which is why it happens at restore and not at decode.

`CanvasTileSession` loses `arrangement` and `sizes`. `CanvasTiling.savedArrangement` stays, as the
command a new workspace is filled in by.

### What it costs

The layout arithmetic is nothing — twenty tiles is microseconds — and the rule that keeps it that way is
already the board's: move the views that exist, never rebuild them. The cost is elsewhere.

- **A page re-lays itself out every time its tile changes size.** An animation that resizes six web cards
  is six pages reflowing on every frame. Neither ⌥N nor a drag adds any: both mark where the card would
  go and leave the tiles alone, and a drag reflows once, on the drop. **Measure
  first**, with `FrameMeter`, on a real board of pages. If it is bad, the answer is to give each page its
  final size at once and animate a picture of it, putting the live page back when the tiles land. The
  frozen-page snapshot in `CanvasLinkNodeView` is half of that already.
- **The picker drops every page below `pagesLoadAbove`**, so they freeze to their pictures. They keep
  their renderers for the off-screen grace, so going back into the workspace reloads nothing, and the
  budget pass already waits for the crossing to land (`isCrossing`). The first frame of a board of forty
  cards is what zooming the board out costs today, and is worth one measurement.
- **Hidden tabs hold live pages.** A tile of five web tabs could hold five of the eight. The budget
  already treats a card that isn't drawn as not visible, so hidden tabs give their slots up first and
  freeze after the grace. Probably right as it stands; worth a test.

### The order it is built in

Each step ships on its own once the first is in.

1. **The shape.** Columns in `CanvasTileSession` and `CanvasViewState.Tiling`; grid and master-and-stack
   as commands; dividers, pinning, promote, swap, the handlebar and maximize on columns; the conversion
   of saved tilings. Deliberately no new gestures, so what changes on screen is only what the shape
   changes:
   - A grid whose last row is short has shorter columns of taller tiles, rather than a centred short row.
   - A grid keeps its columns when the window changes shape. Arranging it again fits it to the new one.
   - Arrange's two items are commands, and neither is ticked.
   - Every boundary in a grid can be dragged. A grid of rows *and* columns used to have none.
   - Swapping two tiles swaps the cards; the sizes stay where they were.
   - Taking out the master leaves the stack filling the window, rather than promoting the next tile.
   - A boundary's menu pins the column or the tile either side of it — Pin Left Column, Pin Tile
     Above — rather than naming a card, and Even Out on the master's boundary makes the two columns
     equal rather than putting back the split you usually drag it to.
   - Unpinning a tile leaves it the size it was, rather than jumping to an even share.
   **Built.**
2. **Keys**, and where the next card goes: the automatic side, ⌥N, and the mark. **Built** — the
   keys for tabs and the board (⌥T, ⌥[ ⌥], ⌥B) arrive with those steps.
3. **Tabs.** **Built**:
   - **The strip is the layout's.** A tile of several cards is laid out whole and its card is drawn
     below a band across its top (`CanvasTileSession.tabStrips`, `belowTabs`), so everything that reads
     where cards are — hit testing, the handlebars, the page budget — is right without knowing about
     tabs. The band is drawn under the cards, with the handlebars (`CanvasTileHandleView`).
   - **The strip is the tile's title bar.** A click on a tab shows it, a drag on one pulls that card out,
     and a drag on the rest of the strip carries the tile, as the handlebar does. Double-clicking it
     maximizes, as a title bar's double-click does.
   - **The top of every tile is its tabs.** Dropping a tile or a tab on a tile's top band joins its tabs.
     A tab pulled out joins them from the middle too, since one card is not a tile to swap with.
   - **Maximizing keeps the tabs.** The strip stays on the tile filling the room, and ⌥[ ⌥] step through
     it with the maximize following the card that shows.
   - **Pull Out of Tabs** is on a tabbed tile's own menu, beside ⌥T.
4. **The board as the picker.** **Built**:
   - **The workspace stays up.** Picking is a way of drawing it, not a way out of it: `isTiled` (the
     workspace — commands, what a card is added to, what is saved) and `showsTiles` (the screen —
     whether cards take their own clicks, whether the board scrolls and zooms, which rule the page
     budget runs by) came apart for it, and they differ only while picking. So nothing is set aside,
     each pick is an ordinary change to the workspace saved like any other, and the tab never leaves.
   - **A pick goes where the next card goes**, and is then the tile the next pick goes beside, so a run
     of clicks lays the cards out in the order you picked them. ⌥N's Return opens the picker, so the
     place you chose is where the first click lands.
   - **A frame is its cards**: clicking one puts in every card inside it that isn't in yet, or takes
     them all out when they all are — never the last card.
   - **The keyboard is the picker's.** Escape, Return and ⌥B go back; nothing else means anything,
     because ⌫ there would delete a card off the board you are only choosing from.
   - Also **Pick Cards on Board** in the View menu and a tile's menu, retitled to the way back while it
     is up.
5. **Peek**, as a zoom. **Built**:
   - **Space on a card, while picking.** The board flies onto the card — its own size if the window has
     room, never larger, in the middle of what the sidebar and the header leave (`CanvasTiling.peek`) —
     and the rest of the board is dimmed round it. Space or Escape flies back to exactly where the board
     was, and so does a click anywhere but the card.
   - **Return, or a click on the card, is what a pick would have been**: in, where the next card goes,
     and back to choosing. Except that a card already in the workspace is not taken out but shown — you
     went and looked at it, which is not asking for it to go — and the workspace comes back on its tile.
   - **Not a frame.** A frame is its cards and there is nothing in one to read, so Space over one beeps.
   - **A look, not a visit.** The card still doesn't take its own clicks and the wheel still moves the
     board, as everywhere in the picker; reading further down a page is zooming in by hand.
6. **Size by Content.** **Built**, as **Size Columns to Content** (⌥⇧0, and in every Arrange menu):
   - **A command, like Balance, not a mode.** A mode would have to decide what a boundary drag means
     while it is on — fight the drag, or quietly switch itself off at the first one — and either way the
     widths would stop being what you last did. Done once, it is one more way to set them, and Arrange
     stays a menu with nothing ticked.
   - **The widest card a column holds**, tabs that aren't showing included, gives the column its share
     (`CanvasTileSession.contentWidth`): a page 1024, a PDF 720, a note 640 — a project's card is its
     notes and its tasks together, and sized as the notes — an image 560, a text card 320. A pinned
     column keeps its pin. Heights are left alone.
   - **The mark for a narrow page is shown while a boundary is dragged**: a page under 380pt says its
     width in orange. That is when you are choosing a width; a page left narrow on purpose shouldn't
     carry a warning for as long as it stays that way.

### What step 2 decided on the way

- **The keys are the board's `keyDown`, not menu key equivalents.** A key equivalent is taken before
  the view you are typing in sees it, so ⌥= as a menu shortcut would have taken ≠ away from every text
  card and every text field on every page. As `keyDown` they reach the board only when nothing that
  types wanted them — which is how ⌥ arrows always worked, and why the table in *The keys* needs no
  second modifier (`CanvasBoardView.tilingTakes`).
- **The chosen place is the session's, and the overlay marks it.** `CanvasTileSession.preselection` is
  a field like `maximized`: not saved, and while it is set `placementFrame` says where the card would
  go, measured off the tiles as they stand. It drew the *room* at first — `layout` was the columns with
  a stand-in inserted — and that went the way the drag's live reflow went, for the same reason. The
  boundaries stay live while it is up, since nothing is drawn anywhere but where the columns put it.
- **Return offers the cards.** Finishing a choice opens the board to pick from (step 4 — until then it
  opened Add Card from Canvas at the place). Any other way a card arrives — a new card, a paste, a
  followed link — goes there too, and uses the place up.
- **Several cards at once go one beside the next.** A paste of three placed beside the same tile would
  split it three times and land in reverse; beside the one before, they read in the order they came.
- **A drag never reflows the tiles** (see *Where the next card goes*): it marks where the card would
  land and changes the layout once, on the drop. That retired the handlebar's one-move-per-crossing rule
  (`CanvasTileSession.reorder`), which existed only because the order changed under a pointer still
  being read against it — and, on a second pass, the live preview that had replaced it.

### Left out on purpose

- **A strip that scrolls past the window.** Every workspace fits its window, for now.
- **Workspaces that fill themselves** from a frame or a search. A workspace stays a list you control.
- **Rules that place a card by its kind.** Size by Content is as far as that goes.

## 8. What this does to the backlog

- **New, and first:** the card is the project (§§2–5). The complaint that started this.
- **12** — what a card shows — was promoted and re-argued: display is not capability, and it is stored
  on the node, not in defaults (§6). Built as `CanvasCardShows`, and the item is retired.
- **15** — live-saving the summary and goals — is **decided**: live rows, and Cancel is retired, in the
  window as well as on the card (§4). It stopped being optional the moment a details block could sit in
  a tile.
- **18** — what a workspace is — was **answered** (§7) and the rename it asked for is **done**; the
  item is retired. The definition turned out to be `CanvasViewState.Tiling` as it already stood, so
  what shipped was three words going to three things and nothing else.
- **9** and **10** fold into §7 and §7b: not "is this hidden or missing" but "this is the unit, give it
  a home", and duplicating one is how the second workspace gets made. §7b says where that home is — the
  pill's tiled readout, which stops being a readout — and answers 9's remaining question with *both*:
  it was a real gap **and** a discoverability one, and they had the same cause.
- **13** — suggest the project's links — gets its open question answered by §5.
- **8** — swap the card in a tile — is **folded into §7k** as tabs in a tile: add the new card as a tab
  and take the old one out. Its picker is the board itself, which also answers its thumbnail question.
- **11** — BSP layouts — is **answered by §7k**: not a tree, but columns of tiles, which have the
  splitting grammar a tree needs and cost nothing to store.

## Open

**The rename is done**, and what it turned on is recorded in the code rather than here:
`CanvasFocus.CodingKeys` (why `workspace` still goes on the wire as `arrangement`),
`CanvasWorkspaces` (why the defaults key keeps its old spelling), `CanvasBoardView+Tiling.frames` (why
a frame is not one), and `CanvasViewState.Tiling` (why the type kept its name while the concept took a
new one). `CanvasFocusCodingTests` is what holds the wire format still, since nothing else in the code
would notice it moving.

**A workspace cannot span boards — decided.** Everything above already kept one inside a single board,
and this settles that it stays that way. **A board is one `.canvas` file**: the document PmLib parses
out of it (`CanvasDocument` — nodes, edges, and the keys it carries through untouched), which one
`CanvasBoardView` draws, and which every view memory is keyed by (`CanvasViewMemory`, keyed by the file
rather than by the project, because a board is one document however you reached it). A tiling is a list
of card ids; a card id means something only inside the file it was written in. So a workspace spanning
two boards would be a list whose ids come from two documents, with nothing to say which one an id
belongs to — and the workspace would break the moment either file was opened on its own.

"Slack and Google Docs, no project notes" is still a workspace with nothing project-shaped in it, and
the answer is the one that was already likely: it belongs to the board you made it on. That board may
hold nothing but web cards, which is a perfectly ordinary `.canvas`.
