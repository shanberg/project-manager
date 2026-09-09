# Canvas backlog

One entry per item: what it is, where it lives, and — where there is one — the question that has to be
answered before it can be built. Deliberately short. An item that turns out to need a real design
argument graduates to [open-items.md](open-items.md) or a page of its own.

Finished items are deleted rather than kept, because the reasoning that was worth having outlives them
in the code: this codebase argues in its comments, and a done entry here is a second copy going stale.
What is below is what is left to do.

Priorities are at the bottom.

## Fixes

### 1. The placeholder sits over a page you could already read

A card shows its globe-and-host placeholder until the page finishes loading, which on an app-shell
page — the kind a dashboard is made of — is long after the page is worth looking at.

Not an accident: `revealPage` is called from `didFinish`, with an eight-second fallback for pages that
never settle ([CanvasLinkNodeView.swift:505](../pm-mac/PM/Canvas/CanvasLinkNodeView.swift:505)), and
`suppressesIncrementalRendering` is on so the reveal is never half-painted. The design answers "don't
flash"; the complaint is that it answers it by waiting for the wrong signal.

Open: what the earlier signal is. `didCommit` is too early — that is a blank frame. First
visually-non-empty layout is the honest one and WebKit only exposes it privately. A `estimatedProgress`
threshold is the ugly, public, probably-good-enough version. Whichever it is, the 0.2s cross-fade stays.

### 2. The alignment indicators, again — **rebuilt as a target, wants using**

The complaint got specific, and it was not about which of the three bands: it was that all of them
were the wrong *kind* of mark. They explained a snap that had already fired — a receipt — when what a
person placing a card wants is somewhere to aim.

So they are gone, and what replaced them is one outline of the frame the card would have if the match
it is near were carried through, up while you are still approaching and fading in as you close. The
whole argument is in [CanvasGhost](../pm-mac/PM/Canvas/CanvasSnapping.swift), including why the claims
collapse into one rectangle, why the lattice gets no mark at all, and why the outline moved above the
cards after `CanvasTileHandleView` had spent its whole life arguing it belonged below them.

Then the brief got sharper again, and this time about what a guide is *for*: it should promote
alignment and regularity, and rounding a card to a 10pt lattice does neither. Two cards both sitting on
multiples of ten say nothing whatever about the distance between them. So the board learnt **spacing**
— the third kind of agreement, beside alignment and size, and the first one that can see a gap. It
offers the placement that centres a card in the hole it was dropped into, and the placement that
carries on the pitch a run of cards is already keeping. Three cards with the same top edge are aligned;
they are not a row until the gaps agree, and until now the board could not tell the difference.

The grid stays exactly as it was — quantizing placement, drawn while you drag, and offering nothing.
That division is the point: the lattice tidies, and the guides relate cards to each other.

What is left is the tolerance, which is a thing to feel rather than derive: the snap fires at 7 view
points and the offer appears at 48, squared so it stays faint over most of its range. Spacing gives the
board more to catch on, so 48 will feel more generous than it did. Drag a few cards around a real board
and say whether it offers too much or too little.

## Features

### 3. ⇧ and ⌥ while resizing — **parked**

The design-tool grammar: **⇧ keeps the aspect ratio, ⌥ resizes about the centre**, and together, both.
Neither exists today — a resize is the dragged grip and nothing else
([CanvasSnapping.resize](../pm-mac/PM/Canvas/CanvasSnapping.swift:94)).

**Parked on the collision, which is real:** ⌥ already means *no snapping*, on both a move and a resize
([CanvasBoardView+Input.swift:341](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:341)), and that is
the standard Mac override — it is the reason snapping can be on by default. Giving ⌥ to "from centre"
needs somewhere else for the escape hatch (⌘ is the other candidate, and is currently an
extend-selection modifier on mouse-down). Not worth trading one muscle memory for another without
deciding it deliberately, so this waits.

### 4. ⌥-drag to duplicate a card

The Mac's own gesture, missing. `duplicate` already exists as a command, and the drag machinery in
`CanvasBoardView+Input` already reads ⌥ for "don't snap" — which is the collision, and it is
the same one 3 is parked on, met in a new place.

Not free, then: ⌥ cannot mean both. Worth deciding both at once, since a person who has learnt ⌥-drag
from Figma has also learnt ⌥ for no-snapping from everywhere else.

### 5. Cards that are just an image

An image card letterboxes: `scaleProportionallyUpOrDown`
([CanvasFileNodeView.swift:145](../pm-mac/PM/Canvas/CanvasFileNodeView.swift:145)), so a board of
photographs is a board of grey margins in a dozen different proportions.

Sketch: when the card's aspect ratio is within some tolerance of the image's, fill instead of fit —
the crop is invisible at that tolerance and the board tidies itself. Beyond the tolerance, keep
fitting, because a deliberate wide crop of a tall picture is a decision.

Open: is the tolerance a preference, a per-card switch, or a constant nobody sees? Also whether a
resize should *offer* the image's own aspect ratio as a snap, which 2 would then have to say out
loud.

### 6. Dropping files on the board — verify, then polish

Mostly built already: the board takes `.fileURL`, `.string`, `.URL` and image types, and a dropped
file becomes a file card at the drop point
([CanvasBoardView+Commands.swift:76](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:76)). So the
first job is to try it with a markdown file and find out what is actually missing. Suspected gaps:

- no visible feedback while dragging over the board — the drop lands with no indication of where,
- a file from outside the vault is stored as an absolute path
  ([CanvasBoardView+Commands.swift:159](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:159)),
  which Obsidian cannot resolve. Copy it in, or say so,
- several files cascade by 30pt rather than laying out.

### 7. Tidy

FigJam's tidy-up: take a rough cluster and make it a clean grid, keeping the reading order and the
rows people already meant. Different from the tiling — a tiling is a temporary *way of looking*, this
edits the document.

`CanvasTiling.order` already answers the hard half: what reading order a scatter of cards is in, rows
banded by the median card height ([CanvasTiling.swift:120](../pm-mac/PM/Canvas/CanvasTiling.swift:120)).
Tidy is that order, laid back out on the board at a regular pitch, as one undoable change.

Open: whether it acts on the selection, on a frame, or on everything; whether card sizes are made
uniform or only their positions regularised (Figma keeps sizes — probably right); what the spacing is
and whether it is the 10pt grid.

### 8. Swap the card in a tile

In a tiled view, a way to say "this slot, different card" — a control on the tile that raises a
picker of the cards on the board that are not currently up.

- Rows are `[thumbnail] [title / preview text]`.
- **The project note sorts first when it isn't already on screen**, since that is the card you most
  often meant.
- Existing pieces: `CanvasPageTitles` for names, and the summary/preview text in `CanvasSummary`.
  Thumbnails are the unknown — a web card's snapshot exists, a file card's does not.

Where it lives: the tile's contextual menu, beside promote and pin. Not on the handlebar — that drags
and does nothing else, deliberately, and every other tile command has moved off it and into the two
menus.

### 9. Saved arrangements — already built, and hard to find

Worth writing down because it looks like a gap and isn't. Arrangements are saved per board, by name,
in defaults rather than in the `.canvas` — [CanvasArrangements](../pm-mac/PM/Canvas/CanvasArrangements.swift),
with the whole lifetime argument set out there — and a tab can be pinned to one
(`CanvasFocus.arrangement`).

So the request "save tile layouts to the project, in app persistence rather than project data" is done,
exactly as asked. What is missing is a way to notice: it is one contextual-menu item with no shortcut
and nothing in the window pointing at it. Find out whether the answer is discoverability or a real gap
before building anything.

### 10. Duplicate the current arrangement

Small, and only worth stating because of what it is *for*: you have built a six-tile view and want a
variant of it. Today that means building the variant from scratch.

Sketch: "Duplicate Arrangement" beside Save, seeding the name from the one that is up ("Dashboard
copy"), then the copy is what your adjustments land on. Depends on nothing except 9 being answered.

### 11. BSP layouts

`CanvasTiling` currently offers a grid and a master-stack, and rules BSP out in its own doc comment:
"a scheme for windows that arrive one at a time and split whatever had focus, and a board's cards all
exist already" ([CanvasTiling.swift:13](../pm-mac/PM/Canvas/CanvasTiling.swift:13)).

That argument survives the request as far as *automatic* BSP goes — there is no arrival order to
recurse on. What it does not answer is BSP as a thing you *build*: split this tile, put that card in
the new half. Tiles can be added now, so the arrival order exists — you are the one supplying it —
and the objection goes away. What replaces it is that an added tile currently goes on the end of a
list, and under BSP "the end" is not a place: it would have to name a tile to split and a direction,
which is a second grammar for adding rather than a second arrangement.

Open: whether that is one arrangement more or a different kind of thing entirely — a grid and a
master-stack are computed from a list, and a BSP layout is a tree that has to be stored. If it is a
tree, `CanvasViewState.Tiling` grows a second shape and every saved arrangement has to decode either.

### 12. What a project card shows

A project card renders the whole notes document — title, every session, every task. On a board of six
projects that is six of everything, when what you wanted from five of them was the current state and
the open work.

Wanted: a card set to show any of the latest session, all sessions, the metadata block
(summary/problem/goals/approach), open tasks, or all tasks — and mixed, so one card is "goals + open
tasks" and another is just the latest session.

The pieces exist: `SessionBody` already cuts the document into blocks and `CanvasProjectNote` already
composes from them. The questions are where the setting lives — a card menu, a control on the card, or
the same picker in both — and where it is *stored*. A per-card setting is a fact about a card, which
argues for the `.canvas`; but the `.canvas` is Obsidian's file and PM has so far put every view
preference in defaults. Probably defaults, keyed by canvas path and node id, which is what
`CanvasCardMedia` and `CanvasCardSession` already do.

### 13. Offer the project's own links when adding a web card

Adding a web card means typing or pasting an address, when nine times in ten the address is already in
the project's `## Links` block.

Sketch: the add-a-link field suggests the current project's links first, so switching between them is a
pick rather than a paste. And the mirror: putting a card on an address the project doesn't know about
offers — never requires — to add it to the block. An offer, because a board is where you try things,
and half the pages you put on one are not worth writing down.

Open: what "the current project" means on a board with six project cards on it. The window's project is
the obvious answer, and is nothing at all for a board opened from a file. Possibly: the window's
project first, then every project the board has a card for.

### 14. Pin and reorder a project's links

`LinkEntry` is `label`, `url`, `children`
([NotesTypes.swift:3](../pm-swift/Sources/PmLib/NotesTypes.swift:3)) — a list whose order is the order
of the lines in `## Links`, with nothing to say one matters more than another.

Reordering is therefore an edit to the notes file, which is fine and is what a drag should write.
Pinning needs somewhere to put the fact. The `key:value` convention the task lines already use is the
obvious spelling and would not be an invention (see the todo.txt findings in
[open-items.md](open-items.md)), but a token on a link line is visible in Obsidian in a way a token on
a task line has already earned. The alternative is a defaults-side pin, which is invisible in Obsidian
and does not sync — the same trade `CanvasArrangements` made, and it came out the other way there.

Depends on 13 only in that both want a better answer to "what are this project's links".

### 15. Live-saving the summary and goals

Edits to the summary/problem/goals/approach block are lost if the pane closes mid-sentence, which is
not how the task rows behave — and that inconsistency is what makes it read as a bug.

**It is a bigger ask than it sounds, and the reason is Cancel.** This is not a field that commits on
blur; it is an explicit form. `DetailsEditor` seeds `@State` from the notes, and the only way anything
reaches the file is the Save button — with a Cancel beside it
([ProjectView.swift:3358](../pm-mac/PM/Project/ProjectView.swift:3358)). Saving live means retiring
that Cancel, because a form that both writes as you type and offers to discard is lying about one of
the two.

Which is a fair trade and is probably the right one — the rest of the app has no modal editing and the
notes file has undo behind it — but it is a decision about how this app edits, not a debounce. Open:
whether the whole block becomes live rows like the task list (bigger, more consistent), or keeps its
form and merely commits on dismissal as well as on Save (smaller, and leaves the inconsistency
half-fixed). Also whether ⌘Z reaches it either way.

### 16. Deliberately start a new session

A write joins the last session unless the project has been left alone for 90 minutes
([SessionWindow.swift:25](../pm-swift/Sources/PmLib/SessionWindow.swift:25)). The window is a good
default and there is no override: two distinct sittings inside an hour and a half land in one block.

The panel already has a New Session command — the question is whether it is the same thing, and
whether the override belongs on every surface that writes (the CLI, Raycast, quick capture) or only on
the one place you would deliberately say "this is new work". Probably the latter, since the whole point
of the window is that the other surfaces should not have to think about it.

### 17. Zoom to fit the selection, and the rest of the grammar

⇧2 for "fit what is selected", explicitly asked for — and asked for as part of a larger want: one
coherent set of navigation keys rather than the current scatter.

What exists: ⌘0 fits the whole board, ⌘+/− step, ⌃1…9 go to a frame, ⌘↩ tiles, the arrow keys move by
direction ([CanvasNavigation](../pm-mac/PM/Canvas/CanvasNavigation.swift)). What is missing is fit-to-
selection and, arguably, "back to where I was".

Design first. The nearest existing grammar is Figma's — ⇧1 fit all, ⇧2 fit selection, ⇧0 100% — and
adopting it wholesale would put ⇧1 next to a ⌘0 that already means the same thing, which is two keys
for one act. Decide whether the Figma set replaces the ⌘ set or joins it before adding a single key.

## Discussion

### 18. What a workspace is

Raised as a discussion, and it is one, because the app currently has **three** answers and they
disagree.

- A **frame** on the board is called a workspace outright — `CanvasBoardView+Tiling.workspaces`, ⌃1…9
  goes to one, and the justification is that a frame is already a named container of cards.
- A **saved arrangement** is a named tiling of a named set of cards
  ([CanvasArrangements](../pm-mac/PM/Canvas/CanvasArrangements.swift)).
- A **tab** in a project window is `ProjectTabView` — the notes, or a board narrowed by `CanvasFocus`
  to the whole thing, a frame, or an arrangement
  ([ProjectTab.swift:38](../pm-mac/PM/Project/ProjectTab.swift:38)).

So a tab can already be pinned to either of the first two, and the proposal — "each project may have an
unlimited number of workspaces" — is a request to collapse the three into one named thing.

The question to answer before any of it: **is a workspace a region of a board, or a window layout?** A
frame is the first: it lives in the `.canvas`, Obsidian can see it, and it has a place on the board. An
arrangement is the second: it is per-machine, invisible to Obsidian, and has no position at all. They
feel alike because both are "a set of cards you named", and they behave differently in every way that
follows from where they are stored. Deciding that is deciding what the feature is.

## Priority

**First — the one that reads as broken:** 1 (reveal a page on an earlier signal than "finished").
2 is in this tier the moment the complaint is specific: which of the three marks, in which case, and
whether it is unreadable, ambiguous or merely too loud.

**Then — find out before designing:** 6, which is the same instruction it has always been — drop a
markdown file on a board and see what actually happens — and 9, which asks whether saved arrangements
are missing or only hidden.

**Then — design first, then build:** 12 (what a project card shows), 13 (suggest the project's links),
14 (pin and reorder them), 15 (live editing, and what happens to Cancel), 17 (the navigation grammar),
7 (tidy, the largest), 5 (image cards), 8 (the tile picker), 10 (duplicate an arrangement, once 9 is
answered).

**Blocked on an argument, not on work:** 18 — what a workspace is — which 11 (BSP) sits behind, and
3 and 4, which are one ⌥ collision seen twice and want deciding together.
