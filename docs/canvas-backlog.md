# Canvas backlog

One entry per item: what it is, where it lives, and — where there is one — the question that has to be
answered before it can be built. Deliberately short. An item that turns out to need a real design
argument graduates to [open-items.md](open-items.md) or a page of its own.

Finished items are deleted rather than kept, because the reasoning that was worth having outlives them
in the code: this codebase argues in its comments, and a done entry here is a second copy going stale.
What is below is what is left to do.

**Numbers are permanent and never reused**, because code comments and other pages cite them. The gaps
are retired entries, listed at the bottom with where each one's reasoning went. Priorities are above
that.

## Fixes

### 2. The alignment indicators, again — **rebuilt as a target, wants using**

The old bands explained a snap that had already fired — a receipt — when what a person placing a card
wants is somewhere to aim. What replaced them is one outline of the frame the card would take if the
match it is near were carried through, with an 8pt glow on the one or two cards that produced the
offer, so the geometry says what kind of agreement it is and the glow says which cards it is with.

The board now agrees on **spacing** as well as alignment and size — the first kind of agreement that
can see a gap, so three cards with the same top edge can be told from a row. The 10pt lattice stays
exactly as it was and stays a separate thing: the lattice tidies, the guides relate cards to each
other. The whole argument is in [CanvasGhost](../pm-mac/PM/Canvas/CanvasSnapping.swift), including why
the claims collapse into one rectangle and why the outline sits above the cards.

What is left is **48 points**, the distance the offer fades in at. It is a thing to feel rather than
derive, and it is a stronger setting than it was now that the mark is at one opacity the whole time it
is up: everything inside 48 is drawn at full strength. Drag a few cards around a real board and say
whether the offer is up too often.

### 18. Adding a tile disorders the workspace

Adding a tile — "or similar": swapping, pulling a tab out — often leaves the other tiles in a different
order from the one they were in. Not yet reproduced on purpose.

Where to look: where the new card goes is decided in `CanvasTileSession` and argued in
[canvas-workspaces.md](canvas-workspaces.md) §7k *Where the next card goes*; the saved arrangement is
`CanvasViewState.Tiling`. The first question is whether the order is wrong in the saved workspace or
only on screen — if a reopened workspace comes back in the right order, this is layout, not the model.

### 19. A deleted card tile leaves part of itself on screen

Delete a card that is a tile, and a piece of the old tile stays drawn over the workspace that reflowed
around it, occluding it until something else redraws.

Suspects, in the order worth checking: the node view removed while the tiled fade still holds its
layer (`tiledFade`, `CanvasFade`); the frozen snapshot (`CanvasFrozenPageView`) outliving its card; the
handlebar layer (`CanvasTileHandleView`) not being told the tile went. A web tile versus a text tile
would split the first two from the third.

## Features

### 3. The modifiers a board is missing, and the one collision under all of them

Three gestures are wanted and none exists: **⇧ keeps the aspect ratio while resizing, ⌥ resizes about
the centre** — the design-tool grammar, where a resize today is the dragged grip and nothing else
([CanvasSnapping.resize](../pm-mac/PM/Canvas/CanvasSnapping.swift:94)) — and **⌥-drag duplicates a
card**, which is the Mac's own gesture and simply absent; `duplicate` exists as a command only.

These were two entries parked separately on what turns out to be one obstacle. **⌥ already means *no
snapping*, on both a move and a resize**
([CanvasBoardView+Input.swift:522](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:522)), and that is
the override which lets snapping be on by default. ⌥ cannot mean three things, so this is one decision
and it only has to be made once.

**What is actually free, read rather than assumed.** During a drag the board reads **only ⌥** — the
snapping reach and the guides, nothing else. ⇧ and ⌘ are read at *mouse-down*, by the selection path
and by nothing else: `extending = shift || command`
([CanvasBoardView+Input.swift:35](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:35)). So both are
available mid-drag, and the only real cost of taking one is a press that both extends the selection and
does the modifier's new job on the drag that follows.

**Recommendation: move the escape hatch to ⌘, and let ⌥ and ⇧ mean what they mean everywhere else.**

| | today | proposed | why |
|---|---|---|---|
| ⇧ resizing | — | keep the aspect ratio | every design tool, and ⇧ is "constrain" across the system |
| ⌥ resizing | no snapping | resize about the centre | the grammar this entry asked for |
| ⌥ dragging | no snapping | duplicate | **the Mac's own copy-drag**, learnt in the Finder |
| ⌘ dragging or resizing | extends selection, on the press | no snapping | Keynote, Pages and Numbers all suspend their guides on ⌘ |

The case for it: ⌥ is the one modifier in that table whose meaning is not PM's to choose. "⌥ copies
what you are dragging" is learnt from the Finder long before anyone meets a canvas, while "⌥ turns
snapping off" is learnt from drawing apps — and the drawing apps a person arriving here has actually
used are split on it, since Keynote's is ⌘. Trading a convention we share with some apps for one we
share with the file manager is the better side of the trade.

The cost, plainly: ⌘ already extends the selection on mouse-down, so a ⌘-click that becomes a drag
would extend the selection *and* suspend snapping. The same overlap exists in Keynote and nobody trips
over it, but it is the thing to watch if this feels wrong in the hand.

Nothing here is built, deliberately. All three gestures fall out of the decision in an afternoon, and
none of them can be built before it.

### 6. A folder dropped on a board

Dropping *files* is built and verified: over the board the drag turns into the card it will make, with
the move guides around it; several of a kind lay out as a block rather than cascading; an absolute path
is the file it names or nothing at all; and a drop holding a file from outside the vault raises one
alert — *Copy In*, to the attachments folder beside the board, or *Point At It*
([CanvasDrop](../pm-mac/PM/Canvas/CanvasDrop.swift), `askWhereOutsidersGo`, `CanvasFileResolverTests`).

What was never asked is the directory case. Nothing in `CanvasDrop` tests whether a dropped URL is a
folder, so one becomes the same file card a document does. Open: whether that is enough, or whether a
folder should make something that says what is in it.

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

**Folded into [canvas-workspaces.md](canvas-workspaces.md) §7k**, as tabs in a tile — and the picker is
the board itself.

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

### 11. BSP layouts

**Answered by [canvas-workspaces.md](canvas-workspaces.md) §7k**: columns of tiles rather than a tree.

`CanvasTiling` offers a grid and a master-stack, and rules BSP out in its own doc comment: "a scheme
for windows that arrive one at a time and split whatever had focus, and a board's cards all exist
already" ([CanvasTiling.swift:13](../pm-mac/PM/Canvas/CanvasTiling.swift:13)). That argument survives
as far as *automatic* BSP goes. What it does not answer is BSP as a thing you *build* — split this
tile, put that card in the new half — because tiles can be added now, so you are the arrival order.
What replaces it is that an added tile goes on the end of a list, and under BSP "the end" is not a
place: it would have to name a tile to split and a direction.

Open: whether that is one arrangement more or a different kind of thing entirely — a grid and a
master-stack are computed from a list, and a BSP layout is a tree that has to be stored. If it is a
tree, `CanvasViewState.Tiling` grows a second shape and every saved arrangement has to decode either.

### 14. Pin and reorder a project's links

`LinkEntry` is `label`, `url`, `children`
([NotesTypes.swift:3](../pm-swift/Sources/PmLib/NotesTypes.swift:3)) — a list whose order is the order
of the lines in `## Links`, with nothing to say one matters more than another.

Reordering is therefore an edit to the notes file, which is fine and is what a drag should write.
Pinning needs somewhere to put the fact. The `key:value` convention the task lines already use is the
obvious spelling and would not be an invention (see the todo.txt findings in
[open-items.md](open-items.md)), but a token on a link line is visible in Obsidian in a way a token on
a task line has already earned. The alternative is a defaults-side pin, which is invisible in Obsidian
and does not sync — the same trade `CanvasWorkspaces` made, and it came out the other way there.

Wants a better answer to "what are this project's links" than order-of-the-file — the same want that
built 13 (offering them at the add-a-link field), which settled *whose* links but not their relative
importance.

### 16. Deliberately start a new session

A write joins the last session unless the project has been left alone for 90 minutes
([SessionWindow.swift:25](../pm-swift/Sources/PmLib/SessionWindow.swift:25)). The window is a good
default and there is no override: two distinct sittings inside an hour and a half land in one block.

The panel already has a New Session command — the question is whether it is the same thing, and
whether the override belongs on every surface that writes (the CLI, Raycast, quick capture) or only on
the one place you would deliberately say "this is new work". Probably the latter, since the whole point
of the window is that the other surfaces should not have to think about it. A project card is now a
third surface that starts one and calls the same `openCurrentSession`, so it inherits the question.

Absorbed by 25, which should settle it rather than run beside it.

### 17. Zoom to fit the selection, and the rest of the grammar

⇧2 for "fit what is selected", explicitly asked for — and asked for as part of a larger want: one
coherent set of navigation keys rather than the current scatter.

What exists: ⌘0 fits the whole board, ⌘+/− step, ⌃1…9 go to a frame, ⌘↩ tiles, the arrow keys move by
direction ([CanvasNavigation](../pm-mac/PM/Canvas/CanvasNavigation.swift)). What is missing is fit-to-
selection and, arguably, "back to where I was".

Design first. The nearest existing grammar is Figma's — ⇧1 fit all, ⇧2 fit selection, ⇧0 100% — and
adopting it wholesale would put ⇧1 next to a ⌘0 that already means the same thing, which is two keys
for one act. Decide whether the Figma set replaces the ⌘ set or joins it before adding a single key.

### 20. Tile handles need a better placement system

The handlebar sits in the gap on the off-axis edge facing outwards, taking the other side where one is a
draggable boundary (`CanvasBoardView.tileHandle`, in `CanvasTileChrome.swift`). That rule is stated and
consistent, and in use it still puts handles where you don't look for them.

Open: what the rule should optimise — always the same edge of every tile (findable), always the edge
nearest the window's (out of the way), or the tab strip itself as the handle, which would retire the
bar where a tile has tabs. Decide with 21, since the tab strip is the other thing you grab a tile by.

### 21. Tabs in a tile: how they look, and dragging to reorder them

Two asks about the same strip ([canvas-workspaces.md](canvas-workspaces.md) §7k *Tabs in a tile*): its
appearance wants revisiting, and tabs should reorder by dragging along the strip. Today a tab dragged
is `Gesture.placeTile(… pulling: true)` — it comes *out* of the tile — so reordering needs a way to
tell "along the strip" from "out of it". The window's own tab bar already answers that
(`ProjectTabBar`, `TabDragTests`), and should be the model rather than a second grammar. Tile drags show
a proxy and a drop mark rather than reflowing live, because live reflow was tried and disorienting; a
strip of tabs may be short enough to be the exception, where reflow reads as sorting.

### 23. Header areas that drag, the way Arc finds them

Arc treats a page's own header or toolbar as somewhere to grab the window, found automatically. Wanted
most when a web tile is maximized and fills the window, where there is no other chrome to grab.

Sketch: the same question `CanvasPageView.acceptsTyping` already asks a page, in the app's own script
world — here, whether the point is in a top band with nothing interactive under it — and on yes,
`window.performDrag(with:)`. Open: whether the drag moves the window or the tile (maximized, they are
nearly the same thing; tiled, they are not), and how a page that draws its own drag regions is left
alone.

**22 answered the band half**, which this was waiting on. The band is 66pt deep and AppKit settles a
press in it by building a region from the view tree *in z-order* — a view answering
`mouseDownCanMoveWindow` with no carves its frame out, a view in front of it answering yes puts it
back — so an area that drags is a real `NSView` in the right place, not a hit test
(`CanvasTileHandleView.refreshStripExcluders`, `WindowDragBandTests`). What is still open is the part
that was always this entry's own: `performDrag(with:)` is the opposite direction, asking for a drag
where the region rule would refuse one, and a maximized web tile is mostly *below* the 66pt band
anyway — so Arc's trick is a second mechanism beside the region, not a use of it.

### 24. Switching tiles ends the session you were editing

Editing a session in a project tile, then clicking another tile, steps out of the first — and the editor
with it. A tile click selects and engages together (`tileClicked`), and one card is engaged at a time,
so `selectionChanged` disengages the other.

Open: whether a project tile should keep its editor across losing focus (the way two text views in two
windows both keep their state), or whether engagement stays single and what comes back is the editing
position when you return. The second is smaller and doesn't touch the one-engaged-card rule that the
header, undo routing and New Session all lean on. Absorbed by 25.

### 25. Review: tile session entry, project data, sessions

A full review, and possibly a redesign, of how a session is entered from a tile and how project data and
sessions are presented there. Too large for an entry; it wants a page of its own, and it should absorb 16
(deliberately starting a new session) and 24 rather than run beside them.

### 26. Keeping web apps alive, and their notifications

Slack's unread count stops updating once its card is frozen — past the ten-minute off-screen grace, or
two minutes after the window stops being key. A frozen card runs no script, and waking one restores its
history (`interactionState`), not its connections. Research notes, none of it built:

- **Keep this card running.** A per-card flag, stored like `pmAutoplay` (`CanvasCardMedia`), that counts
  as in use in `CanvasPageBudget` exactly the way playing media now does. The cheapest real answer, and
  the model it would slot into exists.
- **Badges without a renderer.** Slack, Gmail and most chat apps put the count in `document.title` and
  the favicon. The card already watches titles (`titleWatch`), so a live card could show a count in the
  tab bar; a frozen one cannot, which makes this depend on the flag above.
- **Web notifications.** WKWebView doesn't give an embedding app a public way to receive a page's
  `Notification` calls — to be confirmed against current WebKit before relying on it. The usual
  workaround is a user script that replaces `window.Notification` and posts to a script message handler,
  which re-posts through `UNUserNotificationCenter`. It is also one more thing PM says to every frame,
  which `CanvasCardMedia.script` has a documented reason to be careful about.
- **Web Push / service workers**, which would keep delivering with the page closed: not assumed
  available to a WKWebView embedder. Check before designing around it.
- **Tabs behind.** Switching tabs still freezes a board's pages outright (`pauseAllPages`), including one
  that is playing — the playing exception only covers the idle pause and the budget.

### 27. Card size tools: an aspect ratio, an exact size

Optional tools to set a card to a specific aspect ratio (16:9 and the usual set) or size, behind a
switch in Settings that is off by default.

It carries what retired 5 left behind: whether a resize should *offer* a picture's own aspect ratio as
a snap, which would make the 8% fill something you land on deliberately rather than something that
happens to be true — and which 2 would then have to draw, the way it draws the other agreements.

Open: whether these are a menu of presets on the card, a field in an inspector the board doesn't have,
or snaps during a resize that only the setting turns on.

### 28. Save a page: PNG, web archive, restorable

Save a web card's page as a PNG or a web capture, and have the capture come back on the next open.
WebKit has the pieces — `takeSnapshot` (the visible part; a full page means `createPDF` or stitching),
`createWebArchiveData` — and a pasted picture already has a home, the attachments folder beside the
board (`copyNoteAttachment`). Open: whether a capture is a new card beside the page (an image or file
card, which needs nothing new) or a state of the web card itself that opens offline, which is what
"restorable" suggests and is a much bigger thing.

### 29. A colour for a project, or a workspace, on the window

Let a project (or a workspace) have a colour, and colour the window with it. Open: where it lives —
the notes file, which travels with the project and shows in Obsidian; the `.canvas`, which is per board;
or defaults, which syncs nowhere — and what it tints: the board's ground, the tab chip, the sidebar row,
the window's accent. The HIG's line on accent colours versus content colours is the place to start.

## Priority

**The two things that read as broken** are 19 (a deleted tile left on screen) and 18 (tiles
disordered on add), and each wants a reproduction before anyone reads code for it. The third raised
that day, 22, is fixed.

**Waiting on one decision, which unblocks three gestures:** 3. The argument is written out and comes
with a recommendation; what it needs is a yes or a no, not more thinking.

**Wants using rather than building:** 2 — drag cards around a real board and say whether the offer is
up too often — and 6, what a dropped folder should make.

**A page of its own, and it should come before the entries it absorbs:** 25, which takes 16 and 24
with it.

**Then design first, then build:** 20 and 21 together, since handles and tabs are both how you grab a
tile; 14 (pin and reorder links); 17 (the navigation grammar); 7 (tidy, the largest); 8 (the tile
picker); 23 (Arc-style drag areas); 27 (size tools); 28 (saving a page); 29 (colour).

**Blocked on an argument of its own:** 11 (BSP) — whether a stored tree is one arrangement more or a
different kind of thing entirely.

**Research with a cheap first step:** 26 — the keep-this-card-running flag, which slots into a model
that already exists.

## Open elsewhere

Open work that lives on other pages, listed so this one is the whole picture. Nothing here is a backlog
item; each is a question its own page states properly.

- [open-items.md](open-items.md) — a report of what got done. The shape is decided (an append-only log
  beside the notes, not a stamp on the task line); where the log lives and what to do about tasks
  checked outside PM are not.
- [api-contract.md](api-contract.md) Q1 — display strings in the contract, or per-surface formatting.
  Has a recommendation and wants a yes or no. Q2–Q4 are settled.
- [task-identity.md](task-identity.md) — the Mac app has no receipt line for a task mutation made
  anywhere but the quick bar, and saying it there means choosing a surface for a sentence with nowhere
  to go.
- [areas.md](areas.md) — cadence, deferred on purpose until the calendar-shaped version is worth
  having.
- [links.md](links.md) — three things deliberately not built, recorded so they are not re-proposed.

[canvas-workspaces.md](canvas-workspaces.md), [header-chrome.md](header-chrome.md) and
[structural-work.md](structural-work.md) have nothing open.

## Retired numbers

Numbers are never reused, and comments elsewhere cite them, so this is where a retired one resolves.

| | what it was | where it went |
|---|---|---|
| 1 | the placeholder sitting over a page you could already read | **Built.** The reveal is the first of the page having painted, `didFinish`, or eight seconds — a 48pt snapshot probed every 200ms standing in for WebKit's private first-paint milestone. Argued in [web-cards.md](web-cards.md) and [CanvasPagePaint](../pm-mac/PM/Canvas/CanvasPagePaint.swift) |
| 4 | ⌥-drag to duplicate a card | Folded into **3**, which is the one decision under all three modifier gestures |
| 5 | cards that are just an image | **Built.** A card within 8% of the picture's shape fills instead of letterboxing ([CanvasPictureView](../pm-mac/PM/Canvas/CanvasPictureView.swift)); the ratio-as-a-resize-snap question it left behind is carried by **27** |
| 9 | saved arrangements, already built and hard to find | [canvas-workspaces.md](canvas-workspaces.md) — they are workspaces |
| 10 | duplicate the current arrangement | canvas-workspaces §7c — the ordinary way a second workspace comes to exist |
| 12 | what a project card shows | canvas-workspaces §6 |
| 13 | offer the project's own links when adding a web card | **Built, 2026-09-15.** `CanvasLinkSuggestions` turns the combo box on when the current project has links — the engaged card if one is stepped into, else the board's own (canvas-workspaces §5). The mirror half, putting the page you are on into `## Links`, is in [web-cards.md](web-cards.md) |
| 22 | presses near the top of the window moving it | **Fixed, 2026-09-15.** Both halves were one already-known failure: AppKit builds the window-drag region from the view tree in z-order, so a *background* excluder stops working the moment a real `NSView` is drawn over it — a `Menu`'s `_FocusRingView` in the header, and the board itself under the tab strips. `HeaderCapsule` carries an overlay as well now, and `CanvasTileHandleView.refreshStripExcluders` carves out the strips alone, leaving the empty band as somewhere to grab the window. The band's depth and the region rule are measured in `WindowDragBandTests` |
| 15 | live-saving the summary and goals | canvas-workspaces §4 — the block becomes live rows like the task list, and Cancel is retired |
