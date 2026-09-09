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
project window's notes *are* a board tiled to the project's own card, and the second renderer is gone.
**This page is built.** What is left of it is the one question under Open, which is not a task.

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
frames.

### What shipped, and the two things it decided on the way

The readout is `CanvasTitlePill.workspaceMenu`, the list also lives in View ▸ Workspace (nine slots
retitled on validation, exactly as Go to Frame does it), and the write-through is
`CanvasPaneController.keepNamedWorkspaceUpToDate`. Two rules were settled by building it:

**Naming and renaming are one command.** A workspace that has a name cannot be named again, so the item
retitles itself to "Rename …" — `tileCommandTitle`'s pattern. The alternative was letting Name run on a
named workspace, where it would leave the old one behind and put you in a second one: a duplicate,
arrived at by picking the wrong item. Duplicating deserves to be asked for, which is item 10.

**Renaming and deleting break a tab pinned to the old name**, and that is accepted rather than fixed.
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

### A chip is a name, and it is yours

The first chips carried three things: a glyph, the name, and a `6/43` badge. Two of them went.

- **The glyph** told a frame called "Research" apart from a workspace called "Research". That is a
  collision that is rare, that the chip's own menu resolves the moment you ask, and that was costing
  every chip in the row a symbol to guard against.
- **The badge** said how many cards the tiling holds — a fact the board underneath is showing you at
  full size. It was carrying the ✕ out of the tiled view, which is the one thing that had to be
  rehoused: `Leave Tiled View` is now an item on the chip's menu, on the current tab only, since it
  acts on the board that is up.

What is left is a name, which is what a tab is. Two things follow from a row of names:

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
- **Two commands are off in this view.** Leaving the tiled view would leave a tab called "Notes" showing
  the whole board, and naming it as a workspace would give the app a second name for a shape it already
  names. The way to the board is the renderer switch, which is in the header where it always was — and
  which now has to be *told* which side it is on, since both sides are boards.
- **The tiled readout is off too.** "1/43" is a fact about how the app draws your notes rather than
  about the project, and the ✕ beside it is the command that was just turned off.

**And the buttons.** The card has New Task and New Session beside its title — the first controls it has
grown, and the rule they break was worth breaking. Everything else here is reached the way the window
reaches it, on the grounds that a card with buttons the window has not got would be saying the two
surfaces are different things. They are not two surfaces any more.

### What is still not ported

The list's **keyboard** — ↑/↓, ⌘A, ⌘⌫ — which on a board belongs to the board. A one-card workspace has
no cards to arrow between, so this is now a question with an obvious answer and a `isProjectNoteView`
flag to hang it off; it is simply not done. Everything reachable by mouse and menu is.

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

## Open

**The rename is done**, and what it turned on is recorded in the code rather than here:
`CanvasFocus.CodingKeys` (why `workspace` still goes on the wire as `arrangement`),
`CanvasWorkspaces` (why the defaults key keeps its old spelling), `CanvasBoardView+Tiling.frames` (why
a frame is not one), and `CanvasViewState.Tiling` (why the type kept its name while the concept took a
new one). `CanvasFocusCodingTests` is what holds the wire format still, since nothing else in the code
would notice it moving.

**Whether a workspace can span boards.** Everything above keeps a workspace inside one board, because a
tiling is a list of card ids and cards live in a `.canvas`. "Slack and Google Docs, no project notes"
is a workspace with nothing project-shaped in it, which raises the question of which board it belongs to
at all. Left open deliberately: the answer is probably "the board you made it on, and that is fine",
but it is worth being sure before the word *workspace* is promoted to the thing tabs are made of.
