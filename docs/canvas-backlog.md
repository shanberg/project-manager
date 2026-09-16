# Canvas backlog

One entry per item: what it is, where it lives, and — where there is one — the question that has to be
answered before it can be built. Deliberately short. An item that turns out to need a real design
argument graduates to a page of its own.

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

### 32. Restored windows forget their size — **one cause fixed, wants using**

The cause, and it was the whole of the restore half: `WindowSettings.openWindowFrames` was read on
launch and handed to each restored window and **never written by anything**. `rememberOpenProjects`
saved the keys alone, so the list was always empty and every restored window fell back to the one
`PMProject` autosave frame — which only the window opening into an empty screen claims in the first
place ([ProjectWindowController.swift:182](../pm-mac/PM/Windows/ProjectWindowController.swift:182)) —
or to a cascade off it. `PMWindowOpenFrames` had never been written on this machine, which is as plain
as the evidence gets.

Both lists are now built in one pass, index for index, so the filter that drops a projectless window
cannot drift between them ([WindowManager.swift:255](../pm-mac/PM/Windows/WindowManager.swift:255));
and the write on opening a window moved to after the window has been placed, since one asked earlier
answers with the frame it was made at rather than the one it was given.

What is left is **using it**: quit with three windows at three sizes on two screens and say what comes
back wrong. The remaining suspects if something still forgets are all in the *when*, not the what —
the list is written on opening, retargeting, closing by hand, and at `willTerminate`, so a window
resized and then lost to a crash was never recorded, and a resize on its own still writes nothing.

### 39. Drags inside a page were the board's — **rewritten, wants using**

Figma's layer list could not be reordered inside a card, and nothing else that reorders by dragging
could either. Every step of it is now measured rather than supposed (`CanvasPageDragOriginTests`):

- A page's reorder is **HTML5 drag-and-drop**, so WebKit turns it into a real AppKit dragging session
  whose source is the `CanvasPageView` itself — confirmed from the page's side by a `dragstart` in
  Figma, and from ours by a test that hung in `NSCoreDragManager` until it was given a mouse-up.
- `route` then handed it to the board, because the only thing that made a drag the page's was somewhere
  to *type* under the pointer. The page got a `dragstart` and then nothing: no `dragover`, no `drop`.
- Where the board could make nothing of the payload it answered `[]` — and still held it. **Refused by
  the board and never offered back**, which is why the symptom was silence rather than a stray card.
  (The card would have been visible: since 6fd7a1c a drop in a tiled view goes up as a tile.)

**The rule is now the other way round: the page decides, and the board takes what the page declines.**
An element claims a drop by preventing the default on `dragover`, WebKit answers a drag with that
decision, so asking WebKit is asking the page — and it is a better question than the one we were
asking, because "is there a drop target here" is not something `elementFromPoint` can answer.

Nothing is lost by asking first, which is the part that had to be measured: WebKit answers `.none` over
ordinary page and `.move` over an element that claimed the drop, for a link, a string and a page's own
custom data alike. So a link let go over a page still falls through to the board and still becomes a
card, or a tile beside the others. The hazard the old rule was built around — a card navigating to a
link dropped on it — **does not reproduce**: a real `NSURL` dropped on a page with nothing to fall back
on left the page where it was.

One thing to know before touching it: **WebKit's first reply is a lie.** It answers `.copy` to
everything before the web process has been consulted, `.none` on the second ask, and the truth on the
third. So the first answer is discarded and the board holds the drag until one has arrived — which is
the old behaviour's safety property kept on purpose: an undecided drag belongs to the side that can
make a card of it. The four rows of the rule are pinned in `CanvasPageViewTests`, along with that one.

What is left is using it. Reorder a layer list in a tile, then check the two the rewrite touches from
the other side: a link dropped on a tile should still become a tile, and a file dropped anywhere on one
should still go into the page. `acceptsTyping` has no caller now; it is kept for 23.

### 45. Switching project changes both windows

With two windows open, clicking a project in one sometimes retargets both; closing a window is reported
the same way. Not the retarget itself, which is per-controller and deliberately "this window, always"
([WindowManager.swift:133](../pm-mac/PM/Windows/WindowManager.swift:133)). The suspect is which
controller a command is resolved against: `frontmost` takes the main window, else the key window, else
`controllers.first` ([WindowManager.swift:142](../pm-mac/PM/Windows/WindowManager.swift:142)) — and
`controllers.first` is a window nobody clicked.

Read through on 2026-09-16 and not found. Every path to a retarget names one controller — the
sidebar and a board's card through their own window, Open Recent through `frontmost`, a rename through
the windows already on the old key — and the focus write that follows only moves the menubar's store:
stores are bound to one key and nothing rebinds one in place. One suspect was tested and cleared: the
sidebar sorts by recency, so a switch in one window re-sorts the other's list, but SwiftUI's `List`
keeps a selection on its tag through a reorder and writes nothing back (checked in a PMViewTests probe,
not kept).

So it needs catching rather than reading. The log now says every retarget with its caller and every
window's project after it, every window becoming main, closing, and every move of the focused store —
`window #412 retargeted: … → … (PM/Menu/AppDelegate+Commands.swift:224); windows now [#412 Self, #518
H-004 Maxwell Carmody]`. Open: the next time it happens, the lines in `~/.config/pm/pm-mac.log` around
it. If the second window changed and no retarget names it, what changed isn't its project — its tabs,
its board or its title — and that is a different bug.

## Features

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
[done-report.md](done-report.md)), but a token on a link line is visible in Obsidian in a way a token on
a task line has already earned. The alternative is a defaults-side pin, which is invisible in Obsidian
and does not sync — the same trade `CanvasWorkspaces` made, and it came out the other way there.

Wants a better answer to "what are this project's links" than order-of-the-file — the same want that
built 13 (offering them at the add-a-link field), which settled *whose* links but not their relative
importance.

### 17. Zoom to fit the selection, and the rest of the grammar

⇧2 for "fit what is selected", explicitly asked for — and asked for as part of a larger want: one
coherent set of navigation keys rather than the current scatter.

What exists: ⌘0 fits the whole board, ⌘+/− step, ⌃1…9 go to a frame, ⌘↩ tiles, the arrow keys move by
direction ([CanvasNavigation](../pm-mac/PM/Canvas/CanvasNavigation.swift)). What is missing is fit-to-
selection and, arguably, "back to where I was".

Design first. The nearest existing grammar is Figma's — ⇧1 fit all, ⇧2 fit selection, ⇧0 100% — and
adopting it wholesale would put ⇧1 next to a ⌘0 that already means the same thing, which is two keys
for one act. Decide whether the Figma set replaces the ⌘ set or joins it before adding a single key.

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

### 31. Say we are a different browser, and the layer that belongs around it

A card is a real browser and some sites still turn it away. What PM says about itself today is one
line — `applicationNameForUserAgent`, with the installed Safari's version read off disk
([CanvasWebSession.swift:165](../pm-mac/PM/Canvas/CanvasWebSession.swift:165)). `customUserAgent`
replaces the string outright and is per web view, so the mechanism is a property; what is missing is
somewhere to keep the decision.

The larger want is that place: **per-site web compatibility**, with the filtering exceptions rolled
into it rather than sitting alongside. Those already exist — a site you have excused is remembered by
`CanvasBlockPolicy.siteKey` in `PMCanvasUnfilteredSites`
([CanvasContentBlocker.swift:30](../pm-mac/PM/Canvas/CanvasContentBlocker.swift:30)) — so this is
widening a store that is there, not inventing one.

Open: whether a claim is per site or per card (the card is the thing you are looking at; the site is
the thing that has the problem); what else is per-site rather than per-card once there is a home for it
— blocking, `pmAutoplay`, page zoom, 26's keep-this-card-running, 43's script freeze; and where it is
edited, a list of sites in Settings or the card's own menu writing the site's row.

### 33. Read Craft for what a polished Mac app holds itself to

Not a feature: a pass over Craft with a list at the end. It is the nearest thing to what PM is — a
document app whose whole claim is that it feels made rather than assembled — and it is worth reading
for its standards as much as its features: how it animates a state change, what it does with the
sidebar and the window chrome, how much of the HIG it follows and where it knowingly doesn't.

Open: nothing to decide. The findings come back as entries here, and the ones that turn out to be about
the same thing as an entry we already have should go into it rather than beside it.

### 34. A tile as a real window

Pop a tile out and have it be an ordinary window — the thing every tiling window manager lets you do,
and the obvious answer to "I want this dashboard on the other screen".

The constraint is known and it is the one peek ran into: a web card moved to a different parent view is
a page torn down and started again, which is why peek is a zoom rather than a second copy
([canvas-workspaces.md](canvas-workspaces.md) §7k *Peek is a zoom, not a copy*). A second window is a
different view tree by definition, so a popped tile reloads unless what moves is the card's whole view
and its `interactionState` goes with it.

Open: what the board shows where the tile was — the card back on the board, a gap, a placeholder that
says where it went; whether the window is a project window holding one tile or a kind of its own; and
what closing it means. A board is already allowed to be up in two windows at once, sharing one
refcounted store (`CanvasStoreRegistry`), so the document half of this is answered and the view half is
not.

### 36. Tabs down the side of a tile

An option for a tile's tabs to run down its leading edge instead of across its top. Wanted where the
tile is tall and narrow, or where five tabs on a wide one become a row of 220pt buttons you read
left to right and then lose your place in.

Cheap in the geometry: one band and one function decide where a tab is, and the drawing and the hit
test both read it ([CanvasTiling.tabStrip](../pm-mac/PM/Canvas/CanvasTiling.swift:437),
[tabs(in:count:)](../pm-mac/PM/Canvas/CanvasTiling.swift:444)), so a second direction is a parameter
rather than a rewrite.

**Decided 2026-09-16:** per tile, from the tile's menu (Tabs on the Side), saved with the workspace.
The strip is about 180pt wide with the icon and name, and a column of icons alone on a narrow tile.
It looks and drags as the top strip does since 21 — the chip, the hover, the close button, reordering
along the strip and pulling off it. Open: what a tile too short for its tabs does.

### 38. What macOS's compositor does that our freeze doesn't

Moving around the system, windows keep their content: switch a Space, unhide an app, come back from
sleep, and what was there is there, unblinking. A board's frozen card is visibly a picture of a card.
The observation is worth chasing rather than admiring.

The likely difference is not subtle: the window server holds each window's backing store and composites
it, so nothing is restored because nothing was thrown away — the app is alive behind the image the
whole time. Our freeze deliberately throws the renderer away, because taking its memory back is the
entire point ([CanvasPageBudget](../pm-mac/PM/Canvas/CanvasPageBudget.swift)), and what stands in for it
is a bitmap that has to be scaled to a card that has since changed shape (35).

Open: which parts of what it does are actually ours to have — a layer that survives a view being
rebuilt, WebKit's own suspension of a view out of the window hierarchy versus our teardown, and whether
the honest version of this is 43 (freeze the script, keep the page) rather than a better picture.

### 40. A second view of a card, and a tile made of the page you are on

Two asks with one wall behind them. A second tab of the same card in the same tile, and "make a card of
what I am looking at and open it as a tile".

The second is nearly built, for links: middle-click or the page's menu makes a card beside this one
(`openInNewCard` →
[addLinkCard(_:beside:)](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:1315)), and an add while
tiled comes up as a tile, since every add command ends in the same place. What is missing is the card's
*current* address rather than a link under the pointer — the page you navigated to, which
`CanvasPageVisits` is already holding.

The first runs into peek's wall (see 34): one card is one view, and a web card in a second view is a
second page. So "the same card twice" can only honestly mean "a second card on the same address" —
which is exactly what the second half makes. Open: whether that is a good enough answer to say so in
the menu, and what the new card is called when it is a second view of the same page.

### 41. Maximize a card from the board

⌘Return and a double-click on the handlebar maximize a *tile*
([toggleMaximizeTile](../pm-mac/PM/Canvas/CanvasBoardView+Tiling.swift:384)), and a tile only exists
inside a workspace. On the board the nearest thing is Space, which zooms to the card. Asked for as
"fullscreen this card the way I can a tile", and flagged in the asking as a product smell: two ways of
looking should not have two grammars for the same want.

Open, and the smell is the more interesting half: whether this is one command (maximizing a card is a
workspace of one tile, and Escape brings the board back) or whether peek and maximize should have been
one act all along. Decide with 17, which is the same want one level up — one navigation grammar rather
than a scatter.

### 43. Freeze the script, not the whole page

A cheaper freeze: stop a card's JavaScript and leave the page standing, instead of tearing the renderer
down and putting a picture in its place. Per site, so the dashboard that is only worth having live stays
live and the page that spins a timer forever does not.

Open, and the first question is whether WebKit offers it at all: there is no public "suspend scripts" on
`WKWebView`. What exists is media (`setAllMediaPlaybackSuspended`) and whatever WebKit does on its own
for a view out of the window hierarchy, which is worth measuring before it is designed around —
38 is the same question asked from the other end. If it exists it is a third state between live and
frozen for `CanvasPageBudget`, where today there are two, and a per-site switch that belongs in 31's
layer rather than in a preference of its own.

## Priority

**What reads as broken**, roughly in the order a day of using the board meets it: 45 (switching
project moves the wrong window — instrumented, waiting to be caught in the log).
18, 19 and 22 are fixed. **32 and 39 are fixed and want using** — the first
wants a few days of quitting and relaunching, the second wants a layer dragged in a tile, and a link
and a file dropped on one to check the two rules the rewrite moved.

**Wants using rather than building:** 2 — drag cards around a real board and say whether the offer is
up too often — and 32, which now writes the frames it always
read.

**Decided, building next:** 36 (tabs down the side of a tile).

**Then design first, then build:** 14 (pin and reorder links); 17 with 41, which is the same want at two
altitudes; 7 (tidy, the largest); 8 (the tile picker); 23 (Arc-style drag areas); 27 (size tools); 28
(saving a page); 29 (colour); 31 (a per-site compatibility layer, which 43 and 26 would both live in);
40 (a second view of a card).

**Blocked on an argument of its own:** 11 (BSP) — whether a stored tree is one arrangement more or a
different kind of thing entirely.

**Research with a cheap first step:** 26 — the keep-this-card-running flag, which slots into a model
that already exists. 43 and 38 are the same research from two ends and should be done at once: what
WebKit will let us suspend, and what the window server is doing that we are not.

**Reading rather than building:** 33 — a pass over Craft, with the findings coming back as entries
here.

## Open elsewhere

Open work that lives on other pages, listed so this one is the whole picture. Nothing here is a backlog
item; each is a question its own page states properly.

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
| 3 | the modifiers a board was missing, and ⌥ already meaning no snapping | **Built, 2026-09-16.** The design-tool grammar every tool agrees on: ⇧ keeps the aspect and ⌥ resizes about the centre (`CanvasHandle.resize(_:by:keepingAspect:fromCentre:)`, `CanvasSelectionTests`), and ⌥-drag leaves a copy behind (`duplicateInPlace`, one undo). Snapping's escape moved off ⌥ to **⌘ or ⌃** — tools split on it (⌘ in Keynote, tldraw, Excalidraw, Miro; ⌃ in Figma) and neither is otherwise read mid-drag (`suspendsSnapping`). A constrained resize does not snap; revisit if missed |
| 4 | ⌥-drag to duplicate a card | Folded into **3**, which is the one decision under all three modifier gestures |
| 5 | cards that are just an image | **Built.** A card within 8% of the picture's shape fills instead of letterboxing ([CanvasPictureView](../pm-mac/PM/Canvas/CanvasPictureView.swift)); the ratio-as-a-resize-snap question it left behind is carried by **27** |
| 6 | a folder dropped on a board | **Built, 2026-09-16.** A folder card: the Finder's list of its top level, folders first, watched while the card is up, every row a link zone so a click opens the item and a drag carries it off as a card (`CanvasFolderCard`, `CanvasFolderCardTests`). Stored as the ordinary file card it was |
| 9 | saved arrangements, already built and hard to find | [canvas-workspaces.md](canvas-workspaces.md) — they are workspaces |
| 10 | duplicate the current arrangement | canvas-workspaces §7c — the ordinary way a second workspace comes to exist |
| 12 | what a project card shows | canvas-workspaces §6 |
| 13 | offer the project's own links when adding a web card | **Built, 2026-09-15.** `CanvasLinkSuggestions` turns the combo box on when the current project has links — the engaged card if one is stepped into, else the board's own (canvas-workspaces §5). The mirror half, putting the page you are on into `## Links`, is in [web-cards.md](web-cards.md) |
| 16 | deliberately starting a new session | **Built, 2026-09-16,** as part of 25: ⌥ New Session starts a new sitting inside the idle window, unless the current one is still empty (`session.start` `new`, contract 1.8.0). See [tile-sessions.md](tile-sessions.md) D1 |
| 18 | adding a tile disordering the workspace | **Fixed, 2026-09-15.** Neither the model nor the layout: the columns were right the whole time and `readingOrder` was wrong. It asked `CanvasTiling.order`, which is the *board's* rule — scattered cards have no rows, so it invents them from the median card height, measured from each card's middle. Tiles are columns and their rows are a fact. A full-height tile's middle is level with nothing in particular, and the band moved when the median did, so adding one tile changed what counted as a row for tiles that had not moved. It reads off each tile's own top-left corner now, which cannot depend on the population. Worst symptom found on the way: an untouched master and stack read its first stack tile before its master, so re-running Master and Stack promoted the wrong card. `CanvasTileOrderTests` |
| 19 | a deleted card tile leaving part of itself on screen | **Fixed, 2026-09-15.** None of the three suspects: the build pass kept the view. A layout that is not the document keeps every card already built — a workspace of six on a board of forty-three must not tear the other thirty-seven down — and that rule went on answering for a card the file no longer had, while `layoutNodeViews` skips a view whose node it cannot find. So the orphan sat at its old tile's frame until the workspace was left. The decision is `CanvasVisibleCards` now, asserted in `CanvasVisibleCardsTests` |
| 20 | where a tile's move handle goes | **Built, 2026-09-16.** A grip over the tile's top centre, shown only while the pointer is near there, modelled on Claude's desktop panels; a tile with tabs has none, its strip moves it. A catcher view above the card takes the press over a page (`CanvasBoardView.tileHandle`, `CanvasTileGripView`). [canvas-workspaces.md](canvas-workspaces.md) §7k |
| 21 | how a tile's tabs look, and reordering them | **Built, 2026-09-16.** Tuned in an artifact: a 32pt strip, tabs to 190pt, the showing tab a lit glass chip that slides between tabs, hover fill and close button fading in. Dragging a tab reorders the strip the way the window's tab bar does and pulls the card out past 24pt off it (`CanvasTileSession.moveTab`, `CanvasTabSlide`). §7k |
| 22 | presses near the top of the window moving it | **Fixed, 2026-09-15.** Both halves were one already-known failure: AppKit builds the window-drag region from the view tree in z-order, so a *background* excluder stops working the moment a real `NSView` is drawn over it — a `Menu`'s `_FocusRingView` in the header, and the board itself under the tab strips. `HeaderCapsule` carries an overlay as well now, and `CanvasTileHandleView.refreshStripExcluders` carves out the strips alone, leaving the empty band as somewhere to grab the window. The band's depth and the region rule are measured in `WindowDragBandTests` |
| 24 | switching tiles ending the session you were editing | **Fixed, 2026-09-16.** The smaller answer: engagement stays single, and a card stepped out of with a session note open keeps the note (by `SessionRef`) and its caret, and reopens both on the way back in (`CanvasProjectCardDisplay.returnTo`, `MarkdownTextEditor.startsAt`, `NoteEditorReturnTests`). Once per return; a session that has gone shows the project. The rest of the tile-session review is still 25 |
| 25 | review of tile session entry, project data and sessions | **Reviewed and built, 2026-09-16** — [tile-sessions.md](tile-sessions.md): ⌥ New Session, Delete Session on an empty session's caption, empty sessions drawn with a quiet call to action, and the takeover's dead titlebar placement removed. Captions as handles was not taken |
| 30 | the header in full screen, never designed | **Built, 2026-09-16.** At rest the header keeps a window's 26pt drop; when the system's bar comes down it rides down under it frame by frame, following the bar window's move notifications (`NSWindow.fullScreenTitlebarReach`). The bar is 32pt with the empty toolbar hidden, and clear so the ground shows through. Settled in [header-chrome.md](header-chrome.md) §3, Full screen |
| 35 | one frozen picture per card, shown at either shape | **Fixed, 2026-09-16.** Two pictures per card, filed by whether it was tiled when the picture was taken (`CanvasPageSnapshots`, the tile's under `#tile`). A card with a picture only at the other shape shows its placeholder rather than a cropped one; crossing between the board and a workspace swaps the picture of a card not showing its page (`CanvasLinkNodeView.refreshTiledness`). The on-disk cap doubled to 800 files. `CanvasFrozenPageTests` |
| 37 | combining projects: a master, and a merge | **Master built, 2026-09-16** — a member names its master in `pm-part-of`, one level, rolled up on the card and in the sidebar ([combining-projects.md](combining-projects.md)). **The merge was dropped** the same day, undecided |
| 42 | the second link dragged off a web card making a card of the first | **Fixed, 2026-09-16.** Neither suspect in the entry: the drag pasteboard. It is shared and keeps the last drag's contents, and WebKit writes a dragged link to it a few hundredths of a second *after* the drag begins — clearing it and writing twice. A drag started on a page is over the board from its first moment, and the board read the pasteboard once on the way in and kept that. It now reads again whenever the change count has moved (`CanvasDropSession.pasteboardChange`). The premise is measured with real WebKit drags in `CanvasPageLinkDragTests` |
| 44 | the dragged picture and the card that lands not in the same place | **Fixed, 2026-09-16.** Decided that a drop is the exception to the proxy-holds-still rule of 21: the outline already says where it lands, so the picture agreeing with it costs only the jump. `place` puts the dragging items at the snapped `landing` frame on every update once `carry` has swapped in the board's picture, and `carry` draws from `carried` but places at `landing` |
| 15 | live-saving the summary and goals | canvas-workspaces §4 — the block becomes live rows like the task list, and Cancel is retired |
