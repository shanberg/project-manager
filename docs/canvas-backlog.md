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

### 26. Hearing from web apps without keeping their cards alive — **researching**

**Keep Running is built** (2026-09-17): a per-card switch beside Autoplay and Mute, in the card menu and
the tile's `…`, that makes a card in use to the page budget the way playing media is — past the
limit, the off-screen timer and the idle pause, not past the zoom ([CanvasCardMedia](../pm-mac/PM/Canvas/CanvasCardMedia.swift)).
It is for the dashboard that is only worth having live.

**It is the wrong shape for the real ask**, which is: several cards per chat workspace across several
projects, and knowing when something relevant arrives — without a renderer per card and without a
notification per message. A version that guessed which cards to keep (recognise a live app by its
title changing or a WebSocket held open, keep one card per site and profile) was built, tested and
set aside unmerged, because it still ties hearing from an app to which board happens to be open.

The direction instead: **listening belongs to the app, not to cards.** One hidden page per account,
owned by the app, costing one renderer per account however many cards point at it. The app's own
notification rules — mentions, DMs, keywords — are the relevance filter, caught where the page calls
the web `Notification` API. The board is the routing table: a card's address names the workspace and
channel, so a notification lands on the projects whose cards match. Quiet by default — counts on cards,
dots on projects and the menubar — with system notifications grouped per project.

**The research so far is [web-app-attention.md](web-app-attention.md)** — what WebKit gives an
embedder, what each app gives, whether a hidden page keeps listening, and what is left to measure.

Open, and research before design, across chat, mail and work apps (Slack, Discord, Teams, Google Chat,
Gmail, Outlook, Linear, GitHub, Notion, Figma, WhatsApp and the like), not Slack alone:

1. Does a WKWebView page get a working `Notification` on macOS 26, and if not, does a page call one PM
   supplies? The Badging API (`navigator.setAppBadge`), title counts and favicon badges as the quieter
   signals.
2. What each app passes — does a notification carry ids (workspace, channel, thread) or only text?
3. Does one page hear every workspace or account signed in, or only the one on screen?
4. Does a page in no window keep its connection for hours, or does WebKit suspend it — and what does
   a service worker or Web Push give an embedder?
5. Where there is an API instead (Slack, GitHub, Linear), whether it is the better listener.

### 28. Save a page: PNG, web archive, restorable — **iced**

Save a web card's page as a PNG or a web capture, and have the capture come back on the next open.
WebKit has the pieces — `takeSnapshot` (the visible part; a full page means `createPDF` or stitching),
`createWebArchiveData` — and a pasted picture already has a home, the attachments folder beside the
board (`copyNoteAttachment`). Open: whether a capture is a new card beside the page (an image or file
card, which needs nothing new) or a state of the web card itself that opens offline, which is what
"restorable" suggests and is a much bigger thing.

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
project moves the wrong window — instrumented, waiting to be caught in the log). 18, 19, 22, 32 and 39 are fixed.

**Wants using rather than building:** 2 — drag cards around a real board and say whether the offer is
up too often.

**Iced:** 28 (saving a page) — set aside 2026-09-17, not wanted yet.

**Blocked on an argument of its own:** 11 (BSP) — whether a stored tree is one arrangement more or a
different kind of thing entirely.

**Research, now:** 26 — hearing from web apps (chat, mail, work tools) through one listener per
account rather than live cards: what WebKit and each app will give an embedder. 43 and 38 are the same research from two ends and should be done at once: what
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
| 5 | cards that are just an image | **Built.** A card within 8% of the picture's shape fills instead of letterboxing ([CanvasPictureView](../pm-mac/PM/Canvas/CanvasPictureView.swift)); the ratio-as-a-resize-snap question it left behind is carried by **27**, which chose not to |
| 6 | a folder dropped on a board | **Built, 2026-09-16.** A folder card: the Finder's list of its top level, folders first, watched while the card is up, every row a link zone so a click opens the item and a drag carries it off as a card (`CanvasFolderCard`, `CanvasFolderCardTests`). Stored as the ordinary file card it was |
| 7 | tidy a rough cluster into a grid | **Built, 2026-09-16.** FigJam's Tidy Up, ⌃⌥T and Edit ▸ Tidy Up: two or more selected cards, or the cards a lone frame holds, laid out with their rows kept and their columns aligned — each column as wide as its widest card, each row as tall as its tallest, a 20pt gutter on the 10pt lattice, sizes untouched, one undo. A frame grows to hold its grid and never shrinks; in a larger selection it is one item and carries its contents. Rows are read off top edges rather than `CanvasTiling.order`'s middles, so a second tidy is a no-op (`CanvasTidy`, `CanvasTidyTests`) |
| 8 | swap the card in a tile | **Built, 2026-09-16.** Replace With, in a tile's and a tab's contextual menu: the board's cards not already up, grouped by frame, the project note first (and first in Add Card from Canvas too). The chosen card takes the old one's slot — tab position, size, tabs on the side, maximized — and is focused; the old card leaves the workspace and stays on the board. The rest of the picker was already tabs, [canvas-workspaces.md](canvas-workspaces.md) §7k (`CanvasTileSession.replace`, `CanvasTileReplaceTests`) |
| 9 | saved arrangements, already built and hard to find | [canvas-workspaces.md](canvas-workspaces.md) — they are workspaces |
| 10 | duplicate the current arrangement | canvas-workspaces §7c — the ordinary way a second workspace comes to exist |
| 12 | what a project card shows | canvas-workspaces §6 |
| 13 | offer the project's own links when adding a web card | **Built, 2026-09-15.** `CanvasLinkSuggestions` turns the combo box on when the current project has links — the engaged card if one is stepped into, else the board's own (canvas-workspaces §5). The mirror half, putting the page you are on into `## Links`, is in [web-cards.md](web-cards.md) |
| 14 | pin and reorder a project's links | **Reorder built, 2026-09-16; pinning dropped.** Drag a link along its project card's list and it moves there — the order of the lines in `## Links` is the order, so the drag writes the notes file and nothing else (`movingLink(from:to:)`, `ProjectLinksOrderTests`). Only plain links move; a group and the blank line keep their places. The drag reorders while the pointer is on the card and carries the link off as a card once it leaves (`CanvasLinkReorder`, `CanvasLinkZones.List`) |
| 16 | deliberately starting a new session | **Built, 2026-09-16,** as part of 25: ⌥ New Session starts a new sitting inside the idle window, unless the current one is still empty (`session.start` `new`, contract 1.8.0). See [tile-sessions.md](tile-sessions.md) D1 |
| 17 | zoom to fit the selection, and the rest of the navigation keys | **Built, 2026-09-16.** Figma's fits join the ⌘ set rather than replace it: ⇧1 fits the board and ⇧2 the selection, read by key position on the board and never as menu equivalents, so a card still types ! and @ (`CanvasBoardKeys.fit`, `CanvasBoardKeysTests`). View ▸ Zoom to Selection is new; ⌘+/− and ⌘0 (Actual Size) stay, ⇧0 was not added. ⌘9 came off Zoom to Fit — it was Go to Tab ▸ Last Tab's too, which won. "Back to where I was" not taken |
| 18 | adding a tile disordering the workspace | **Fixed, 2026-09-15.** Neither the model nor the layout: the columns were right the whole time and `readingOrder` was wrong. It asked `CanvasTiling.order`, which is the *board's* rule — scattered cards have no rows, so it invents them from the median card height, measured from each card's middle. Tiles are columns and their rows are a fact. A full-height tile's middle is level with nothing in particular, and the band moved when the median did, so adding one tile changed what counted as a row for tiles that had not moved. It reads off each tile's own top-left corner now, which cannot depend on the population. Worst symptom found on the way: an untouched master and stack read its first stack tile before its master, so re-running Master and Stack promoted the wrong card. `CanvasTileOrderTests` |
| 19 | a deleted card tile leaving part of itself on screen | **Fixed, 2026-09-15.** None of the three suspects: the build pass kept the view. A layout that is not the document keeps every card already built — a workspace of six on a board of forty-three must not tear the other thirty-seven down — and that rule went on answering for a card the file no longer had, while `layoutNodeViews` skips a view whose node it cannot find. So the orphan sat at its old tile's frame until the workspace was left. The decision is `CanvasVisibleCards` now, asserted in `CanvasVisibleCardsTests` |
| 20 | where a tile's move handle goes | **Built, 2026-09-16.** A grip over the tile's top centre, shown only while the pointer is near there, modelled on Claude's desktop panels; a tile with tabs has none, its strip moves it. A catcher view above the card takes the press over a page (`CanvasBoardView.tileHandle`, `CanvasTileGripView`). [canvas-workspaces.md](canvas-workspaces.md) §7k |
| 21 | how a tile's tabs look, and reordering them | **Built, 2026-09-16.** Tuned in an artifact: a 32pt strip, tabs to 190pt, the showing tab a lit glass chip that slides between tabs, hover fill and close button fading in. Dragging a tab reorders the strip the way the window's tab bar does and pulls the card out past 24pt off it (`CanvasTileSession.moveTab`, `CanvasTabSlide`). §7k |
| 22 | presses near the top of the window moving it | **Fixed, 2026-09-15.** Both halves were one already-known failure: AppKit builds the window-drag region from the view tree in z-order, so a *background* excluder stops working the moment a real `NSView` is drawn over it — a `Menu`'s `_FocusRingView` in the header, and the board itself under the tab strips. `HeaderCapsule` carries an overlay as well now, and `CanvasTileHandleView.refreshStripExcluders` carves out the strips alone, leaving the empty band as somewhere to grab the window. The band's depth and the region rule are measured in `WindowDragBandTests` |
| 23 | page headers that drag the window, Arc's way | **Already works, 2026-09-16** — found solved in use; nothing built for it |
| 24 | switching tiles ending the session you were editing | **Fixed, 2026-09-16.** The smaller answer: engagement stays single, and a card stepped out of with a session note open keeps the note (by `SessionRef`) and its caret, and reopens both on the way back in (`CanvasProjectCardDisplay.returnTo`, `MarkdownTextEditor.startsAt`, `NoteEditorReturnTests`). Once per return; a session that has gone shows the project. The rest of the tile-session review is still 25 |
| 25 | review of tile session entry, project data and sessions | **Reviewed and built, 2026-09-16** — [tile-sessions.md](tile-sessions.md): ⌥ New Session, Delete Session on an empty session's caption, empty sessions drawn with a quiet call to action, and the takeover's dead titlebar placement removed. Captions as handles was not taken |
| 27 | card size tools: an aspect ratio, an exact size | **Built, 2026-09-17.** Size ▸ in a card's menu and under Edit: 16:9, 3:2, 4:3, 1:1, 3:4, 5:7, 2:3, 11:19, 9:16 — each keeping the width and top-left, widened rather than flattened under the 40pt floor, ticked when every selected card is already there — and Exact Size…, seeded where the selection agrees, a blank field leaving that side alone. One undo, every selected card from its own width, dim when tiled; no Settings switch, and no picture-ratio snap (`CanvasCardSize`, `CanvasCardSizeTests`) |
| 29 | a colour for a project on its window | **Built, 2026-09-17.** Project only, in the notes' frontmatter as `pm-color` (a system colour's name, or quoted hex), set in Project Settings from twelve named colours or the colour well. A wash down from the top of the window, 3½ header bands deep on a smootherstep with dithered pixels, painted *behind* the board — the board paints no ground of its own now — and the sidebar's ring or symbol takes the colour (an emoji gets a dot). The header's grey blur-and-tint edge became a mask on the scroll view, so cards fade out to the real ground, washed or not, and stands down over a tiling (`ProjectColor`, `CanvasColorWash`, `CanvasSoftEdge`, `ProjectColorTests`) |
| 30 | the header in full screen, never designed | **Built, 2026-09-16.** At rest the header keeps a window's 26pt drop; when the system's bar comes down it rides down under it frame by frame, following the bar window's move notifications (`NSWindow.fullScreenTitlebarReach`). The bar is 32pt with the empty toolbar hidden, and clear so the ground shows through. Settled in [header-chrome.md](header-chrome.md) §3, Full screen |
| 31 | say we are a different browser, and the per-site layer around it | **Built, 2026-09-17.** Per site, in one store (`CanvasSiteSettings`, `PMCanvasSites`) that also took over the ad-blocking exceptions, migrated from `PMCanvasUnfilteredSites`. Safari, Chrome or Firefox — the other two as whole user agents with versions counted from the calendar — from "Identify <site> As ▸" in the card menu and the tile's `…`, carried into sign-in windows and popups; Settings ▸ Boards lists every changed site. A change rebuilds every running card on that site. 26 and 43 add fields here. |
| 32 | restored windows forgetting their size | **Fixed, 2026-09-16.** `openWindowFrames` was read on launch and written by nothing: `rememberOpenProjects` saved the keys alone, so every restored window fell back to the one `PMProject` autosave frame or a cascade off it. Both lists are built in one pass now, index for index, so the filter that drops a projectless window cannot drift between them ([WindowManager](../pm-mac/PM/Windows/WindowManager.swift)) |
| 35 | one frozen picture per card, shown at either shape | **Fixed, 2026-09-16.** Two pictures per card, filed by whether it was tiled when the picture was taken (`CanvasPageSnapshots`, the tile's under `#tile`). A card with a picture only at the other shape shows its placeholder rather than a cropped one; crossing between the board and a workspace swaps the picture of a card not showing its page (`CanvasLinkNodeView.refreshTiledness`). The on-disk cap doubled to 800 files. `CanvasFrozenPageTests` |
| 36 | tabs down the side of a tile | **Built, 2026-09-16.** Tabs on the Side, per tile from its menus and saved with the workspace (`CanvasTiling.Tile.tabsOnSide`, written only when on). A 180pt column of icon and name on a tile at least 540pt wide, 40pt of icons alone on a narrower one; the top strip's chip, drag and pull-out turned on their side (`CanvasTileSession.TabStrip`). A column longer than its tile scrolls, and showing a tab scrolls it into view. [canvas-workspaces.md](canvas-workspaces.md) §7k |
| 37 | combining projects: a master, and a merge | **Master built, 2026-09-16** — a member names its master in `pm-part-of`, one level, rolled up on the card and in the sidebar ([combining-projects.md](combining-projects.md)). **The merge was dropped** the same day, undecided |
| 39 | a page's own drags being taken by the board | **Fixed, 2026-09-16.** Reordering a list in a card is HTML5 drag-and-drop and therefore a real dragging session, and the board took every one of them — refusing the ones it could make nothing of without handing them back, which is why the symptom was silence. The precedence is reversed: the page is asked first, since an element claims a drop by preventing the default on `dragover` and WebKit answers a drag with that decision. Argued in [CanvasPageView](../pm-mac/PM/Canvas/CanvasPageView.swift); what WebKit does, including that its first reply is `.copy` to everything, is measured in `CanvasPageDragOriginTests` and the rule is pinned in `CanvasPageViewTests` |
| 40 | a second view of a card, and a tile made of the page you are on | **Built, 2026-09-17,** as the honest version of both asks: Open Page as New Card puts a second card beside this one on the address it is showing now, not the one it was saved with, and the new card resumes the page where it was — scroll and Back history, handed over through `CanvasPageHandover` — with no arrow between them, named by the page title. From the page's right-click menu, the tile's `…`, Page ▸ Open Page as New Card, and `app.openPageAsNewCard` (an affordance, contract 1.10.0). While tiled it comes up as a tile, since every add ends in the same place. "The same card twice" stays impossible for peek's reason (34) |
| 41 | maximize a card from the board | **Built, 2026-09-16,** as one command rather than a second grammar: ⌥⌘↩ (Maximize Card) with one card selected tiles it alone, and Escape, ⌥⌘↩, ⌘↩ or ⌘− fly back to the board as it was. It is a workspace of one that is never saved — no tab, no view state, no departure pose (`maximizeCard`, `restoreMaximizedCard`). Not stepped into, so one Escape is the way back. Peek (Space) stays its own act |
| 42 | the second link dragged off a web card making a card of the first | **Fixed, 2026-09-16.** Neither suspect in the entry: the drag pasteboard. It is shared and keeps the last drag's contents, and WebKit writes a dragged link to it a few hundredths of a second *after* the drag begins — clearing it and writing twice. A drag started on a page is over the board from its first moment, and the board read the pasteboard once on the way in and kept that. It now reads again whenever the change count has moved (`CanvasDropSession.pasteboardChange`). The premise is measured with real WebKit drags in `CanvasPageLinkDragTests` |
| 44 | the dragged picture and the card that lands not in the same place | **Fixed, 2026-09-16.** Decided that a drop is the exception to the proxy-holds-still rule of 21: the outline already says where it lands, so the picture agreeing with it costs only the jump. `place` puts the dragging items at the snapped `landing` frame on every update once `carry` has swapped in the board's picture, and `carry` draws from `carried` but places at `landing` |
| 15 | live-saving the summary and goals | canvas-workspaces §4 — the block becomes live rows like the task list, and Cancel is retired |
