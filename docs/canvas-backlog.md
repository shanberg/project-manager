# Canvas backlog

One entry per item: what it is, where it lives, and — where there is one — the question that has to be
answered before it can be built. Deliberately short. An item that turns out to need a real design
argument graduates to [open-items.md](open-items.md) or a page of its own.

Finished items are deleted rather than kept, because the reasoning that was worth having outlives them
in the code: this codebase argues in its comments, and a done entry here is a second copy going stale.
What is below is what is left to do.

Priorities are at the bottom.

## Fixes

### 1. The placeholder sits over a page you could already read — **built**

A card showed its globe-and-host placeholder until the page *finished loading*, which on an app-shell
page — the kind a dashboard is made of — is long after the page is worth looking at.

The signal was the whole of it. The reveal is now the first of three things rather than one: the page
having **painted**, then `didFinish`, then the eight seconds. `didCommit` was rightly ruled out here as
a blank frame, and the honest milestone — WebKit's first visually-non-empty layout — is private, so the
card reads its *effect* instead: from `didCommit` it takes a 48pt-wide snapshot every 200ms and asks
[CanvasPagePaint](../pm-mac/PM/Canvas/CanvasPagePaint.swift) whether there is a page on it, which is a
poll standing in for the notification. Two or three snapshots is the usual cost of a load. The 0.2s
cross-fade stays, and both old signals stay under it: a page whose first paint is genuinely uniform
never trips the probe and behaves exactly as it did before.

`estimatedProgress` was the expected answer and is not the one: it counts bytes, and the reveal is a
question about pixels — a page can sit at 0.9 with nothing drawn and paint its shell at 0.3.

**The measurement that decided the shape, because it contradicts the obvious reading of the API.**
`suppressesIncrementalRendering` sounds like the private milestone made public. It is not: against a
page that paints its shell and then holds a request open for three seconds, a suppressed view answered
*blank* to all ten probes and arrived only at `didFinish` — the property means what its documentation
says, fully loaded. With incremental rendering allowed, the first probe after the shell painted saw it,
**2.7 seconds earlier**. So the card no longer suppresses, and the half-painted frame suppression used
to guard against is covered by the probe (which only fires on a view with something drawn) and the
cross-fade over it.

The other half of the same complaint — what a card shows *instead* of the page — is **built**: the
snapshot now belongs to the card rather than to the view, survives recycling and relaunching, and is
drawn to the card's width instead of stretched. See [web-cards.md](web-cards.md). Which sharpens this
entry rather than settling it: the placeholder a card falls back to is now usually a picture of the
page, so what is left here is the narrower case of a card that has genuinely never loaded — and the
*cross-fade* from a stale picture to a live page, which is the thing an earlier signal would improve.

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

And the offer now says what it is an offer *against*: the cards that produced it get an 8pt glow,
appearing and fading with the ghost. Not the old bands returning — those were one per kind of claim,
around every card in an agreement, at the instant the snap fired. These are the one or two cards that
actually won, up while you are still deciding. The geometry says what kind of agreement it is; it does
not say which of six cards sharing an edge you found, and that is the part worth knowing when the offer
is the one you didn't mean.

The glow is deliberately not the ghost's shape. It started as the same offset band at half the weight,
which read as the board offering two slots — a band stands *off* a frame, and that gap is what makes it
mean "a card is going here". A glow sits on the card's own edge with no gap to cross, so it says the
opposite: this one is not moving, it is the reason.

The snap now fires at a full grid unit — 10 view points — which settles which of the two systems has
the last word. The lattice never carries a card further than half a unit, so a guide always gets there
first where it applies, and a card that declines a guide as too far can never then be carried further
than that guide would have taken it.

And the mark is at one opacity the whole time it is up. It used to be drawn at a strength that tracked
how near the match was, which over most of the approach put it at a fraction of an already quiet alpha
— the offer you most needed early, drawn faintest, and the marks on the cards being agreed with fainter
still. Now there is a threshold and a fade: inside 48 points it fades in, outside it fades out, and in
between it simply is.

What is left is that 48, which is a thing to feel rather than derive, and which the flat opacity has
made a stronger setting than it was — everything inside it is now drawn at full strength. Drag a few
cards around a real board and say whether the offer is up too often.

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

### 5. Cards that are just an image — **built**

An image card letterboxed every picture, so a board of photographs was a board of grey margins in a
dozen different proportions.

A card whose shape is within **8%** of the picture's now fills instead, and the overflow is clipped;
beyond that it goes on fitting, because a card deliberately shaped against its picture is a decision
and filling it would throw away the composition the card was made for. See
[CanvasPictureView](../pm-mac/PM/Canvas/CanvasPictureView.swift) — built around `NSImageView` so a GIF
still animates and the picture still names itself to VoiceOver, with the fill done by *layout*: the
image view is given the smallest frame of the picture's own shape that covers the card, centred, and
the card clips.

The tolerance is **a constant nobody sees**, which was the open question. A preference is a question
about every picture, asked once, in a window nobody opens, to change a thing you would rather judge
per card; a per-card switch is a control on a card whose entire content is a picture, for a few per
cent of its edges. The thing to do with a card that is the wrong shape for its picture is resize the
card, and this follows.

Still open, and now the whole of what is left here: whether a resize should *offer* the picture's own
aspect ratio as a snap, which 2 would then have to say out loud — and which would make the fill
something you land on deliberately rather than something that happens to be true.

### 6. Dropping files on the board — **verified, and mostly built**

The board takes `.fileURL`, `.string`, `.URL` and image types, and a dropped file becomes a file card
centred on the drop point ([CanvasDrop.swift](../pm-mac/PM/Canvas/CanvasDrop.swift)). The instruction
here was to try it and find out what was actually missing; that has been done, and the four suspected
gaps turned out to be three real ones and one that was worse than suspected:

- ~~no visible feedback while dragging over the board~~ — built, 2026-09-10: over the board a drag
  turns into the card it will make, with the move guides around it, and settles into the snapped place
  ([CanvasBoardView+Dropping.swift](../pm-mac/PM/Canvas/CanvasBoardView+Dropping.swift)). Links
  dragged out of web and text cards arrive as link cards; a web card keeps a drop only over a field
  ([CanvasPageView.swift](../pm-mac/PM/Canvas/CanvasPageView.swift)),
- a file from outside the vault is stored as the absolute path it has
  ([CanvasBoardView+Commands.swift:140](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:140)),
  for want of a vault-relative one. **Half of this was worse than the entry said, and is fixed**
  (2026-09-12): PM did not read those paths back either. An absolute path missed every literal step in
  `CanvasFileResolver` and reached the match-by-name step, where the last component alone is matched
  against the whole vault — so a `Salary.pdf` dropped from Downloads resolved to a *different*
  `Salary.pdf` filed in some project, reported `.moved`, and the window offered to rewrite the card to
  point at it. An absolute path is now the file it names or nothing at all, with one exception kept:
  one that lands inside the vault is a vault-relative path spelled the long way and goes on through the
  drift steps as one. See `CanvasFileResolverTests`, which pins the decoy.

  **The other half is now asked rather than decided** (2026-09-12): a drop holding a file from outside
  the vault raises one alert for the whole drop — *Copy In* (the default, since it is the answer that
  makes the card mean the same thing in both apps, and where a pasted picture already goes: the
  attachments folder beside the board, under the file's own name) or *Point At It*, which keeps one copy
  of a file that is large, or changing, or living where it lives on purpose. Asked on the next turn of
  the runloop, because the call comes from inside `performDragOperation` and a modal session started
  there is a nested loop inside AppKit's own drag loop. See `askWhereOutsidersGo` and
  `copyNoteAttachment`,
- ~~several files cascade by 30pt rather than laying out~~ — **built**, 2026-09-12, and for links too:
  several of a kind are laid out as a block, reading order across then down, `ceil(sqrt(n))` columns
  and a 20pt gutter on the lattice, the whole thing centred on the pointer the way one card already
  was ([CanvasDrop.block](../pm-mac/PM/Canvas/CanvasDrop.swift)). A cascade is the right shape for
  windows, where the top one is the one you asked for; a board's cards are all equally present, so six
  files meant six cards each hiding the one behind it. Rows are pitched by their own tallest card,
  since a file's card is 400 or 300 tall depending on what it holds. The drag preview shows the same
  block, for free — it asks the same `frames(centredOn:)`, which is what that value is for.

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

### 13. Offer the project's own links when adding a web card

Adding a web card means typing or pasting an address, when nine times in ten the address is already in
the project's `## Links` block.

Sketch: the add-a-link field suggests the current project's links first, so switching between them is a
pick rather than a paste. And the mirror: putting a card on an address the project doesn't know about
offers — never requires — to add it to the block. An offer, because a board is where you try things,
and half the pages you put on one are not worth writing down.

Open: what "the current project" means on a board with six project cards on it — **answered by
[canvas-workspaces.md](canvas-workspaces.md) §5**: it is the card you are stepped into. The window's
project was the obvious answer and is nothing at all for a board opened from a file; the engaged card
is an answer that board has too.

The mirror half is **built**, from inside a page rather than from the board: right-click a link, or the
page, and it goes into the project's `## Links`. That surface could not use the engaged-card answer —
what you have stepped into is a web card — and takes the board's own folder instead; see
[web-cards.md](web-cards.md). Which leaves this entry as the half that is still open: the *offer*, made
at the add-a-link field, of the links the project already has.

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

### 16. Deliberately start a new session

A write joins the last session unless the project has been left alone for 90 minutes
([SessionWindow.swift:25](../pm-swift/Sources/PmLib/SessionWindow.swift:25)). The window is a good
default and there is no override: two distinct sittings inside an hour and a half land in one block.

The panel already has a New Session command — the question is whether it is the same thing, and
whether the override belongs on every surface that writes (the CLI, Raycast, quick capture) or only on
the one place you would deliberately say "this is new work". Probably the latter, since the whole point
of the window is that the other surfaces should not have to think about it.

A project card is now a third surface that starts one, and it calls the same `openCurrentSession`, so it
inherits the window and this question along with it. That does not change the answer — a card is a place
you work, not a capture surface — but it is one more place the override would have to appear if the
answer turns out to be "wherever you would say it deliberately".

### 17. Zoom to fit the selection, and the rest of the grammar

⇧2 for "fit what is selected", explicitly asked for — and asked for as part of a larger want: one
coherent set of navigation keys rather than the current scatter.

What exists: ⌘0 fits the whole board, ⌘+/− step, ⌃1…9 go to a frame, ⌘↩ tiles, the arrow keys move by
direction ([CanvasNavigation](../pm-mac/PM/Canvas/CanvasNavigation.swift)). What is missing is fit-to-
selection and, arguably, "back to where I was".

Design first. The nearest existing grammar is Figma's — ⇧1 fit all, ⇧2 fit selection, ⇧0 100% — and
adopting it wholesale would put ⇧1 next to a ⌘0 that already means the same thing, which is two keys
for one act. Decide whether the Figma set replaces the ⌘ set or joins it before adding a single key.

## Raised 2026-09-14

A batch of notes from a day of using workspaces in earnest. The quick ones are built (see Priority);
these are the rest. Several are bugs that want a reproduction before anyone reads code for them.

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

### 22. Presses near the top of the window move the window

Dragging a tab at the top of a tile, and pressing the top-right menu, start a window move instead.

Unverified cause, and the first thing to check: the board runs under the transparent titlebar, and
AppKit decides a titlebar-band press by asking the hit view's `mouseDownCanMoveWindow`. The header's
capsules sit on a `WindowDragExcluder`, but a SwiftUI `Menu` brings its own AppKit view that answers for
itself; and `CanvasBoardView` never overrides the property, so a tab drawn by the board inside that band
may be answering yes. Log the hit view and its answer on a press there before changing anything.

### 23. Header areas that drag, the way Arc finds them

Arc treats a page's own header or toolbar as somewhere to grab the window, found automatically. Wanted
most when a web tile is maximized and fills the window, where there is no other chrome to grab.

Sketch: the same question `CanvasPageView.acceptsTyping` already asks a page, in the app's own script
world — here, whether the point is in a top band with nothing interactive under it — and on yes,
`window.performDrag(with:)`. Open: whether the drag moves the window or the tile (maximized, they are
nearly the same thing; tiled, they are not), and how a page that draws its own drag regions is left
alone. Depends on 22 being understood, since it is the same band.

### 24. Switching tiles ends the session you were editing

Editing a session in a project tile, then clicking another tile, steps out of the first — and the editor
with it. A tile click selects and engages together (`tileClicked`), and one card is engaged at a time,
so `selectionChanged` disengages the other.

Open: whether a project tile should keep its editor across losing focus (the way two text views in two
windows both keep their state), or whether engagement stays single and what comes back is the editing
position when you return. The second is smaller and doesn't touch the one-engaged-card rule that the
header, undo routing and New Session all lean on.

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
  the model it would slot into exists as of today.
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
switch in Settings that is off by default. Belongs with 5's open question (offering a picture's own
ratio as a resize snap) and with 2, which would have to show a ratio snap the way it shows the others.
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

**Nothing here reads as broken any more.** 1 was that entry — a card kept its placeholder until the
page finished loading — and it is built: the reveal is the first of painted, finished, or eight
seconds.

[canvas-workspaces.md](canvas-workspaces.md) is **built, and closed**. A card you have stepped into is
the project and draws as much or as little of it as you set; the words go to the right things — frames
are frames, a saved tiling is a **workspace**, and `CanvasTiling.Arrangement` keeps *arrangement* by
being the only one of the three using it correctly; a workspace has a name you can see and no Save,
because a named one is adjusted live; and its home is a tab, which is where its commands live, what
switching between them goes to, and what duplicating one makes another of. The one thing left on that
page is the question under its Open heading — whether a workspace can span boards — which is a question
and not a task.

**Waiting on one decision, which unblocks three gestures:** 3. The argument is written out and comes
with a recommendation; what it needs is a yes or a no, not more thinking.

**Then — design first, then build:** 13 (suggest the project's links), 14 (pin and reorder them), 17
(the navigation grammar), 7 (tidy, the largest), 8 (the tile picker).

**Blocked on an argument of its own:** 11 (BSP) — whether a stored tree is one arrangement more or a
different kind of thing entirely.

**What 6 has left** is the half that was always a question rather than a defect: a card pointing
outside the vault now asks whether to copy the file in, and what remains is whether anything more is
wanted for a *folder* dropped on a board.

**Raised 2026-09-14 (18–29).** Bugs first, each wanting a reproduction before code: 19 (a deleted tile
left on screen), 18 (tiles disordered on add), 22 (presses at the top moving the window). Then design:
20 and 21 together (handles and tabs are both how you grab a tile), 24 (a session kept across tiles),
23 (Arc-style drag areas, after 22), 27 (size tools), 28 (saving a page), 29 (colour). A page of its
own: 25. Research with a cheap first step: 26, a keep-running flag.

**Built from the same notes, 2026-09-14:** the mouse's Back and Forward buttons on web cards and tiles;
Space-drag to pan with nothing stepped into; undo and redo for Home and Pin, where undoing a Pin keeps
the page on screen; a page that is playing keeps running through the idle pause and the budget, window
hidden or not; files dropped on a tile's page go into the page. And outside the board, windows open at
quit come back, each where it was and at its size — quitting used to close them one at a time and empty
the saved list before the next launch could read it.

**Built since this list was last read before that:** 1 (the reveal), 5 (pictures fill a card that is nearly their
shape, bar the aspect-ratio snap, which belongs with 2), and most of 6 — the drop feedback, the
absolute-path resolution, the copy-in question, and the block layout for several files at once.
