# Items: a project's cards, without the board

**Status:** built 2026-09-21, all seven steps. Where the build settled a question differently from the
proposal, the decision below says what was built and why — the record is meant to be true, not
flattering. The other half of [canvas-workspaces.md](canvas-workspaces.md)
and [views.md](views.md): those are about *arranging* cards and about cards that *answer a question*;
this is about the cards that simply **are things** — a page, a file, a note, a folder — and about
getting at them without a plane. **Workspaces are untouched by design**, and so is the file on disk.

## The problem

Every item in a project is a node in `docs/<Title>.canvas`, and [JSON Canvas](https://jsoncanvas.org)
gives every node an `x`, a `y`, a `width` and a `height`. There is no way to have a thing in a project
without first deciding where it sits and how big it is.

That is the right bargain for a board of six cards you arranged on purpose. It is the wrong one for
the other use, which turns up constantly and has nowhere to go:

- *Put this link in this project.* You open the window, switch to the board, find empty space, drop it,
  and now you own its position for ever.
- *What has this project got in it?* You zoom out and read forty rectangles — which is why
  `CanvasDetail.simplifiedBelow` exists at all: a board too far out to read is still the only index.
- *Add three things quickly.* Three placements, three sizes, and a board that drifts further from
  whatever arrangement you had made.

The board is a place you *make*. A list is a place you *keep*. PM has only the first, and the cost of
the first is paid on every add whether or not you wanted an arrangement.

Three pieces of the answer are already written and don't know about each other:

- [`CanvasExistingCards`](../pm-mac/PM/Canvas/CanvasExistingCards.swift) — every card as
  `{id, name, kind}`, grouped by frame, in reading order, drawn from names and symbols with **no page
  woken up**. That is the item list, sitting inside a picker for one command.
- `canvasCardSummary` ([CanvasSummary](../pm-mac/PM/Canvas/CanvasSummary.swift)) — the one line that
  stands for a card. The name of an item, already decided.
- [`CanvasTidy`](../pm-mac/PM/Canvas/CanvasTidy.swift) and `CanvasTiling.order` — laying cards out in a
  grid, and reading a scatter as rows. Placement, already solved, in the one place that needed it.

## The model

**An item is a card, seen apart from where it sits.** Three rules keep that from turning into a second
application:

1. **One truth.** The `.canvas` is the store. List and grid are *lenses* on the same nodes, the way a
   project card is a lens on the notes document ([canvas-workspaces.md](canvas-workspaces.md) §6).
   Nothing is copied into a sidecar, nothing needs migrating, Obsidian still opens the board, and a
   workspace still points at node ids that mean what they meant.
2. **Every item is placed.** There is no unplaced state. What changes is *who decides* the placement:
   the board asks you, the list doesn't (D6). A card made from the list is an ordinary card, and the
   next person to open the board in Obsidian sees it where it went.
3. **One item vocabulary.** A file card, a web card, a folder, a view and the project's note are one
   type with one name and one symbol, wherever they are drawn — the picker, the list, the grid, the
   wire. A new kind of card is a new case, not six call sites (D2).

## Decisions

### D1 — The canvas file stays the store; list and grid are lenses

The alternative was a real item store — a sidecar of items with ids, kinds and titles, and canvas nodes
holding references into it. It buys a genuine unplaced state and a manual order that nothing fights
with. It costs a **second truth about what a project contains**, and this codebase has refused that
every time it has come up: `pmShows` and `pmZoom` live on the node rather than beside it, a view card
never writes its answer into the file ([views.md](views.md) D3), and a tiling stays out of the document
entirely because it is not an edit. An item that exists in the sidecar and not in the `.canvas` is a
thing the board cannot show and Obsidian cannot see, and the first bug it produces is unfixable in
principle: which of the two is right?

So: **a list of items is a read of the document.** It has no state of its own except how you asked to
see it (D4, D5), and every act in it is an ordinary edit to the `.canvas`, on the store's own undo
stack ([CanvasDocumentStore](../pm-mac/PM/Canvas/CanvasDocumentStore.swift)).

### D2 — `CanvasItem`, in PmLib

`CanvasExistingCards.Card` is promoted out of the picker and into the domain layer:

```swift
struct CanvasItem {          // PmLib/CanvasItem.swift
    var id: String           // the node id
    var kind: Kind           // text · file(symbol:) · view(symbol:) · page(host:)
    var title: String        // canvasCardSummary, a file's name, a page's remembered title
    var detail: String?      // the host, or the folder a file is in
    var frame: String?       // the id of the frame it sits in, or nil for loose
    var rect: CanvasRect     // where it is, for the lenses that care
}
```

**Four kinds, not seven.** The list above was written as a menu's worth of nouns; the document has
four, and they are what got built. A folder is a file card with a folder's symbol, the project's note
is a file card pointing at the notes, and a view is a text node carrying `pmView` — a fifth case for
each would be a kind that nothing in the `.canvas` distinguishes. A frame is not an item at all: it is
what items are grouped *by* (D3).

**What the app knows, the app is asked for.** Three answers a document cannot give — whether a stored
path is a folder (the disk), what a page is called (`CanvasPageTitles`), what a view names itself once
its settings are read (`CanvasViewSpec`) — arrive as `CanvasItemLookups`, each with an honest answer
when there is no app (a file, the host, the kind's own name). That is what lets `card.list` describe a
board from a command line. `CanvasViewKind` moved to PmLib with it, so a Today card is a Day with a
calendar beside it on every surface rather than the text card it is stored as.

Kind carries what the item is drawn *by* — a symbol for a file or a view, a host for a page — because
that is the one thing each lens would otherwise work out for itself. `CanvasAddCommand` already makes
"the things you can put on a canvas" a single list that every add surface iterates; `CanvasItem.Kind`
is the same discipline applied to reading them back. Adding a kind should reach the board, the picker,
the list, the grid and the wire together, or it will reach some of them.

### D3 — Frames are sections

A frame is already a named set of cards that has a position, already a tab (⌃1…9), already grows to
hold what Tidy puts in it, and is already how the picker groups. So in a list it is a **section
header**, and in a grid a band. Loose cards come first, under no header, in reading order — exactly
what `CanvasExistingCards` does today, and the reason that behaviour needs no second argument here.

Frames are the only grouping. A list that could group by kind, by date, by site would be the query
builder [views.md](views.md) D1 refused, and it would be grouping by things the board cannot show —
leaving two different pictures of one project.

### D4 — Order is a sort, not an arrangement

A list needs an order; the board already has one, and it is spatial. Rather than give an item a second
opinion about where it comes, the list is **sorted**, by one of:

| sort | what it is |
|---|---|
| **Reading order** (default) | `CanvasTiling.order` — down and across the board, the order the picker uses and the order tiles are laid in |
| **File order** | the order the nodes sit in the file, which is insertion order near enough, and therefore *recently added*, and costs nothing |
| **Name** | `title`, case-insensitive |
| **Kind** | pages together, files together, views together |

**No manual drag-to-reorder, and no `pmOrder`.** Two cards would be first — one on the board, one in
the list — and nothing reconciles them; the codebase has spent whole sections removing exactly that
kind of second store (`CanvasViewState.workspaceName`, §7h). Arranging is what the board is for, and it
is one keystroke away.

There are no timestamps on a node, so *recently added* cannot be exact. File order is honest about
what it is: Obsidian appends, PM appends, and the answer is right until somebody rewrites the file by
hand. Naming the sort **File order** rather than *Recently added* is the difference between a fact and
a promise.

**Sorting reorders inside a section and never across one.** A frame is where a card *is* — the one
fact about arrangement the list does carry over — so the sections stay in the board's own order and
the sort decides the rows within each.

**Where it is chosen, and where it is kept.** View ▸ Sort Items By, dimmed while a board is up because
a board has an order of its own and this does not rearrange one; and on a right-click anywhere in a
lens that isn't on an item — a header, the add row, the space under the last section — which is both
where somebody would look for it and the only thing that menu could otherwise have said. One order per
board rather than one per lens, because the list and the grid are the same read, and remembered beside
the lens in `CanvasViewState.sort`: not in the `.canvas`, for D5's reason, and written only when it is
not the default.

### D5 — The canvas tab is drawn as a board, a list or a grid

A tab is `notes` or `board(focus)` ([ProjectTab](../pm-mac/PM/Project/ProjectTab.swift)), and the
canvas — `board(.whole)` — is the one focus that is never tiled and that every window has exactly one
of. That is where the lenses go: the canvas tab can be drawn three ways.

- **Nothing about workspaces changes.** A workspace tab is a tiling of cards and stays one. A frame
  tab gets the list lens free, over that frame's items alone, because it is the same read narrowed.
- **The switch is View ▸ As Board / As List / As Grid**, ⌥⌘1 / ⌥⌘2 / ⌥⌘3 — the Finder's ⌘1…4 with the
  modifier the tabs left us, since ⌘1…9 is Go to Tab and that reservation is real now.
- **Remembered per canvas, in `CanvasViewState`**, beside the tiling and the refresh cadence and for
  the same reason: it is a per-machine way of looking, not an edit, and it must not appear in a file
  that syncs. `ProjectRendererMemory` is a different axis (task list vs board) and stays as it is.
- **Not called a mode.** `CanvasMode` is `view`/`connect` already. The type is `CanvasPresentation`,
  cases `board`, `list`, `grid`.

A project that wants to be a list is a list every time it opens, which is the whole of the ask.

### D6 — Adding from the list, and where the card lands

At the foot of each section is an **add row**, the way the task column has one: type a name and get a
doc card (a markdown file in `docs/`), paste a URL and get a web card, or use the `+` for the full `CanvasAddCommand.offered` list
(file, folder, private web, the views). One surface, no dialog, no placement.

Where it goes:

- **Added under a frame**, it joins that frame, laid out by `CanvasTidy.grid` — 20pt gutter on the 10pt
  lattice, the frame growing to hold it, one undo.
- **Added under no frame**, it joins the **Inbox** frame, made on first use. It is an ordinary frame:
  renameable, movable, deletable, and it gets a tab like any other.

The Inbox frame is what stops "add without deciding" from meaning "a pile of cards at the origin". It
is not [views.md](views.md)'s rejected inbox — that was about task capture, which already has a right
answer (the focused project's current sitting). A card has no such home, and inventing one *as a frame*
costs no new concept: the board can already show it, Obsidian can already read it, and moving things
out of it is dragging.

**Which frame the Inbox is, is a mark and not a name.** The frame carries `"pmRole": "inbox"` among its
extra keys — hidden, in that nothing draws it, and durable, in that unknown keys are exactly what
`CanvasDocument` keeps verbatim through every program that touches the file. Identifying it by label
would have been the cheap version and is wrong twice: "Inbox" is an ordinary word, so a board that
already has a frame called it — a reading pile, somebody's triage column — would start quietly taking
PM's cards; and renaming the frame would lose it, so the next add would start a second pile beside the
first. With the mark, the rules are:

- The marked frame is the Inbox, **whatever it is now called**. Rename it to `Reading` and cards keep
  landing where they have been landing, which is what a frame you have been filling should do.
- A frame already labelled `Inbox` that nothing has marked is **adopted** — marked on the way past —
  rather than doubled. Somebody who drew a frame and called it Inbox meant the thing the word means,
  and two frames with one name, one of them the real one, is the confusing outcome.
- `--frame <label>` is unaffected and unmarked: a named frame is found by its label, because a label
  is what a caller who is not looking at the board can name.

A card added from the board is unaffected: the board menu still puts one where you right-clicked.

### D7 — A row is the item, and acts through selection

Rows carry the node id, so everything a card can do, a row can do. Following the rule the rest of the
app keeps: **multi-select and one contextual menu, never a control per row.** The menu is the card's
own, whole — `CanvasBoardView.cardMenu(forItems:)` calls the same builder a right-click on the board
calls, so everything a kind of card adds to its menu is here because it is the same code. **What is
left out is the tiling block, and only that**: those commands act on the arrangement in front of you,
and in a list there isn't one. The spatial items that act on the *document* (Size, Identify As) are
left in rather than dimmed — they work, and a menu that changed shape between lenses would be two
menus.

- ⏎ or double-click opens the item, and **opening is maximizing its card**: the board tiled to that one
  card, which is the one way of looking at a single card the app already had (canvas-backlog 41).
  Escape flies it back — and, because the lens it came from is remembered, carries on back to the list.
- **Space opens too, rather than peeking.** Peek draws over the cards on a board, and in a lens there
  are no cards in front of you. Both keys mean "show me this one" in both lenses, and Escape is the way
  back from both.
- Dragging a row to another section moves the card into that frame (and tidies it there). Dragging one
  **out** of the window carries the item, exactly as dragging a link off a project card does.

**A drop lands in a section, never between two rows.** AppKit offers both — a row, or the line between
two of them — and taking the second would promise an order the list does not have (D2). So wherever
the pointer is, the drop is retargeted to the section under it and shown on that section's own row:
the header when it has one, which `floatsGroupRows` keeps on screen however far down you are, and the
add row when it hasn't, that row already meaning "something new joins here". The grid says the same
thing with a caret at the end of the band.

What the drop then *does* splits in two, and the split is the pasteboard's:

- **Rows of this board move.** A dragged row carries its node id on a private flavour
  (`CanvasItemRows`) beside the link, file or prose it is worth to every other app — so a row dropped
  in another section is the card changing frames rather than a second card made out of the first. The
  ids have to be cards of *this* document for it to count, so a row dragged from another project's
  list is an ordinary copy, which is what it looks like and what it should be. A card dropped on the
  section it is already in stays exactly where it is: with no order to take up a place in, re-slotting
  it would move something on the board in return for nothing in the list.
- **Everything else is made, in that frame.** Files, links, text, images and cards copied off a board
  go through the same `CanvasDrop` the board reads and the same `commit` the board commits — the same
  card, the same question about a file from outside the vault, the same undo. Only *where* is
  different, and that is `CanvasCardDestination`: `.point` for a board, `.frame` for a lens. Several
  files take successive slots inside one change, so a folder dropped on a section is one undo.

The same resolution catches **⌘V in a lens**, which used to paste onto the board behind it where
nothing showed it had arrived: while a lens is up, every card the board makes goes into a frame,
whether it was asked for by an add row, the `+` menu, a paste or a drop.
- The hit area is the whole padded row, so a click near the edge lands on the row rather than falling
  through to the add row beneath it.

### D8 — The grid draws faces, and wakes nothing

A grid of live cards would be a screenful of renderers, which is the cost `CanvasDetail` was written to
avoid. So a grid tile draws what the board draws when it is zoomed out — the item's symbol and its one
line — **plus the picture the card already has**: `CanvasPageSnapshots` keeps two frozen pictures per
card, filed by tiledness, and the untiled one is a thumbnail that cost nothing to take. A card with no
picture draws its face; a picture card draws itself, since it is one already.

That makes the grid the visual index and the list the dense one, and neither of them a reason for a
board of forty cards to run forty renderers.

### D9 — Items go on the wire: `card.list` and `card.add`

The contract has no canvas verbs at all today — the board is app-only. Two are added, in the
`<noun>.<verb>` shape the rest of it uses, at **1.20.0**:

- **`card.list`** (tier 2) — a project's items: id, kind, title, detail, frame, sorted as D4 sorts.
  What the picker, the list and the grid all read, so no surface has a private opinion about what a
  project contains.
- **`card.add`** (tier 1) — a URL, a file path or a line of text, plus an optional frame. Returns the
  usual envelope. This is the simplest form of the whole ask: *add an item to a project without a
  canvas* becomes `pm card add <url> @project`, a Raycast action, and something a model can do while
  reading a page.

Two consequences to settle rather than discover:

- **The revision is the canvas's, not the notes'.** The envelope's `revision` is documented as the
  content hash of the notes file, and a card write touches neither the notes nor a task. It is the same
  guard over a different document, and `card.add` reports the hash of the `.canvas` it wrote. The entry
  is journaled as the document write it is, so `journal.undo` reverses a `card.add` under that guard;
  what it cannot report is a diff of tasks, because a board has none.
- **A preview makes nothing, the board included.** A project has a canvas or wants one, and `card.add`
  makes it — but a dry run on a project with no board must not leave one behind. Caught by
  `DryRunTests`, which is the guard that exists for exactly this.
- **A running window needs no telling.** `CanvasDocumentStore` already watches the file on a two-second
  poll because Obsidian edits it, so a write from `pm`, Raycast or MCP arrives as an ordinary outside
  change and reloads. No new channel, and the case is already tested.

`card.delete` is deliberately not in this pass (see below).

### D10 — What the lenses do not show

**Edges.** Arrows between cards are a fact about a plane and have no rendering in a list. They are
preserved (nothing in this pass writes them), and a list simply doesn't mention them. If connections
turn out to matter away from the board, that is a backlinks feature and needs its own argument.

**Positions and sizes.** Not shown, not editable, not sorted by (except as reading order). A lens that
let you type coordinates would be the board with worse ergonomics.

### D11 — List mode is a list *and* a detail

A list of forty one-line rows answers *what is on this board* and nothing else. Picking a row meant
taking it on trust, or leaving the list: maximize the card, look, fly back. So list mode is a split —
**the rows on the left, the item they are pointing at on the right** — and the rows become navigation.
Arrow keys walk them and the right-hand half keeps up.

**The detail is the card, not a picture of one.** This began as a face — the snapshot D8 already
keeps, or the markdown laid out again beside the row — on the argument that a renderer per keystroke is
what the lens exists to avoid. What it actually bought was a *second* way of drawing every kind of
card: one that agreed with the board on the easy ones and drifted on the rest. A stale picture for a
page. A file read twice, by two rules. Nothing at all for a view card. A card already knows how to draw
itself, so the right-hand half is a **board** — the same `CanvasBoardView`, on the same store — **tiled
to whatever the rows have selected**. The detail is then literally the thing ⌥⌘↩ would fill the window
with, and there is one renderer for a card in this app rather than two.

**Tiled rather than scrolled to**, which is what keeps that cheap and what keeps it safe:

- A tiling of one card *builds* one card. The other thirty-nine are never made, so walking the list
  costs one card's renderer at a time rather than a board's worth — D8's budget, kept by construction
  instead of by drawing something else.
- A tiled card has the tiled grammar: no free space to drag into, nothing to resize. So a half you can
  read and step into is not also a second, smaller place to rearrange the board from by accident.
- The half is hidden when nothing is selected and when the lens is, and a hidden board is the page
  budget's own answer to nobody looking.

Two small things the board had to learn. `tile(_:animated:)`, because every arrow key down the list
re-tiles and a card flying across the pane each time is a journey nobody is following. And
`topClearance` as a property rather than a constant, because this is the first board that is not under
a board's own header but under the lens's, which reaches further down.

**Opening is still opening.** ⏎ and a double-click maximize the card on the pane's *own* board, filling
the whole width, and Escape flies it back to the list — D7 unchanged. The detail is the look while you
are still walking; opening is arriving.

**Several picked is several tiles.** The machinery makes that free, and it is the true answer: the
menu, ⌫ and a drag all act on the three, so a half that showed a count — or the first of them — would
be the one part of the pane declining to do its job.

**Where the seam is.** The list reports and the pane acts, as everywhere else in D7: the half is a
`CanvasItemDetailPane`, three calls wide (`show`, `refresh`, `teardown`), and `CanvasPaneController`
supplies the board that answers them. That is also what keeps the list testable — `PMViewTests` is
hostless and compiles the files under test, and a board pulls in most of the app.

**The grid is untouched.** It is already a wall of faces; putting a detail beside it would leave the
tiles too narrow to be faces and duplicate what they show.

**The list keeps its width and the detail takes the room.** A wider window should mean more of what
you are reading, not a wider column of one-line rows — so the two halves are laid out in
`splitView(_:resizeSubviewsWithOldSize:)` rather than left to the split view, which divides a pane in
two and then holds that *proportion* for ever. None of the shorter ways work: a split view ignores a
width constraint on a half at any priority, and discards a `setPosition` made during the layout pass
that precedes its own. The width is read back off the view each time, so a divider somebody dragged and
a position `autosaveName` restored are both simply what it finds there. That memory is AppKit's own and
per app — a shape of the window rather than a fact about a canvas, so it is not in `CanvasViewState`
beside the lens and the sort.

**A row is as tall as what is in it.** The rows were a fixed 32 points, on the argument that a list of
forty items should not measure forty strings to know how tall it is. The measuring is real and the
argument was still wrong: a card's title is the first line of whatever is written on it, so the long
titles are the notes rather than the links, and cutting every one of them off at the same place is the
list refusing to show the difference between two cards that begin alike. So a title wraps, up to four
lines, and its row grows. Measured strings are cached per width, so forty rows are measured once and
then only when the divider moves — which is exactly when a title that fitted stops fitting.

## Not in this pass

- **`card.delete` on the wire.** Deleting a card from a board a window may be holding, from a surface
  that can't see it, without the board's undo stack, is a destructive action that wants its own
  argument. The app deletes items today and keeps doing so.
- **A table lens.** Craft's third shape. It needs columns, columns need properties, and a card has
  none beyond what D2 lists. Worth revisiting only if items grow properties.
- **Properties on an item** (a tag, a status, a date). This is the fork that turns a board into a
  database, and it should be taken deliberately or not at all.
- **The list as its own tab**, open beside the board. Cheap once the lens exists (`ProjectTabView`
  gains a case), and worth having only once the lens has proved itself.
- **Items across projects** — a list of every card everywhere. That is a view in the
  [views.md](views.md) sense and belongs to that set, with a query behind it.
- **Manual order** (D4), unless the sorts prove insufficient.

## What got built

Every step, on 2026-09-21. `CanvasItem`, `CanvasItems`, `CanvasItemPlacement`, `CanvasViewKind`,
`canvasReadingOrder` and the card-naming helpers are PmLib;
[`CanvasItemListView`](../pm-mac/PM/Canvas/CanvasItemListView.swift),
[`CanvasItemGridView`](../pm-mac/PM/Canvas/CanvasItemGridView.swift) and `CanvasPresentation` are the
app's, hosted by `CanvasPaneController` over the same ground the board sits on. Covered by
`CanvasItemTests`, `CanvasItemPlacementTests` and `CardApiTests` in PmLib and `CanvasItemListTests` in
`PMViewTests` — the list driven as a real table in a real window over a real store.

Two things the build changed: the lenses are AppKit rather than SwiftUI (`NSTableView` and
`NSCollectionView` bring multi-select, type-select, drag and a contextual menu with them, and a SwiftUI
list in a bundle that is never the active app cannot be driven by a test), and hiding the board turned
out to need `applyPageBudget()` told rather than inferred — the budget runs when a board scrolls or is
resized, and being hidden is neither, so a lens left up kept every page running behind it.

## Build steps

All seven landed on 2026-09-21, in this order, and steps 8 to 10 the same day.

1. **`CanvasItem` in PmLib**, with `CanvasExistingCards` rebuilt on it and its tests kept green. No new
   surface — the picker was the proof the type was right.
2. **Sorting** (D4): `CanvasItems.sections(of:sort:)`, with reading order, file order, name and kind.
3. **The list lens**: `CanvasPresentation`, View ▸ as Board / as List / as Grid on ⌥⌘1…3,
   `CanvasViewState.presentation`, and the list drawn from D2 and D3.
4. **Acting from a row** (D7): the card's own contextual menu, delete, and dragging a row off.
5. **The add row** (D6), the Inbox frame — marked `pmRole: inbox`, not found by its label — and
   `CanvasItemPlacement`.
6. **The grid lens** (D8), over the frozen pictures.
7. **`card.list` and `card.add`** (D9), contract 1.20.0, the Mac and Raycast clients regenerated, and
   `pm card list` / `pm card add` in the CLI.
8. **Dropping into a lens** (D7): `CanvasItemRows`, `CanvasItemPlacement.move`, `CanvasCardDestination`
   threaded through `commit`, and both lenses registered as drop destinations.
9. **Choosing the order** (D4): View ▸ Sort Items By and each lens's own menu, kept in
   `CanvasViewState.sort`. The four sorts had been reachable only over the wire, through `card.list`.
10. **The detail half** (D11): `CanvasItemDetailView` beside the rows in a split, fed by the selection
    and by every reload, with the Open button that ⏎ already was.

## Still to look at

- **A drop's feedback has not been seen.** The retargeting is asserted — which section a pointer
  anywhere in it lands on, which flavour moves and which copies — but what a drag actually *looks*
  like over a floating header, and whether the grid's caret at the end of a band reads as "joins this
  band", are questions only a real drag answers.
- **The lenses have not been driven in the running app from here.** The views are asserted headlessly
  and rendered to pictures; what has not been exercised end to end is the pane switching underneath a
  real window — `⌥⌘2` on a canvas tab, the flight out to a maximized card and back. It is the first
  thing to try.
- **A frame tab's lens is not remembered.** `restoreViewState` writes only for the plain canvas tab
  (`focus == .whole`), which is deliberate — one row per board, owned by one pane — so a list set on a
  frame tab lasts as long as the tab does. Right until somebody wants otherwise.
