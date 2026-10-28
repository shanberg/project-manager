# Web cards, and how much of a browser one is

A web card is a page clipped onto a board: it loads, it takes clicks, you can sign in to it. It is not
a browser, and the whole design of it is a series of answers to *how much of one*. This page is where
those answers are, because they have stopped being one-off calls and started contradicting each other
when made separately.

The mechanics — when a page runs, who holds the renderer, what it costs to cross a workspace — are in
[canvas-workspaces.md §7](canvas-workspaces.md). The chrome that drives one is in
[header-chrome.md](header-chrome.md). This page is about the *page*: where it is allowed to go, what
comes back with it, and what a board does with a link.

## Making one, and making one as nobody

A web card is added from the same list everything else on a board is added from
([CanvasAddCommand](../pm-mac/PM/Canvas/CanvasAddCommand.swift)), which the board's right-click, the
header's `+`, a tile's strip and its `+` all draw. Two things about that list are this page's business.

**It says Web, not Link.** "New Link…" described the address you type rather than the thing you get,
and in an app where a project keeps a `## Links` list it described a different command that already
exists. What you get is a card showing a live page, which is what the settings pane, this document and
anyone who has used one has called a web card for as long as it has embedded the page.

**New Private Web Card is the same card on the ephemeral session.** A card could always be moved onto
the private session afterwards — that is the Session submenu, and `CanvasWebSession.ephemeralName` is
the jar with a hole in the bottom, never written to disk and gone when Folio quits. But *afterwards* is
too late for the case it is for: by then the page has loaded once as your signed-in self, which is the
thing you opened a private card to avoid. So the session is set on the node before the card exists, and
choosing it is one decision made at the point the card is made, beside the ordinary one.

Everything else about it is an ordinary web card, including that it shares the one ephemeral store with
every other private card — two private cards are nearly always two views of one signed-out session, and
one jar each would mean signing in twice to look at a site twice.

**And the address bar says which jar you are in.** A card on anything but the shared session wears a
pill at the head of the address ([CanvasSessionPill](../pm-mac/PM/Canvas/CanvasSessionPill.swift)) — the
profile's name, or Private in the browsers' purple. It is in that row because that row is already where
the page says whose it is, and for the same reason the host is stated at full size there: the same host
signed in as somebody else is a different page, and both halves of that sentence should be readable
before you type a password into one. It is drawn while you are typing an address too.

The shared session wears nothing. A badge on every card is furniture, and furniture is what the lock
was before it became a warning that only appears when a page is unencrypted.

Note what this does *not* cover: a card you have not stepped into. The pill is in the window's chrome,
which only ever describes the one card whose page is live under your hands, so a board of private cards
looks like a board of ordinary ones until you step into one.

## The card has two addresses, and only one of them is the document's

`CanvasContent.link(url:)` is the address written on the board — what the card is **for**, and the only
thing in the `.canvas` file. Where the page has actually got to is separate, and always was: the header
calls it *wandered* and offers the two buttons that resolve it, Home and Pin.

Keeping those apart is the load-bearing decision. A card whose saved address quietly followed wherever
you looked would be a board that rewrites itself while you read it — in a file Obsidian also has open
and git may well be watching. So navigation never writes the document; only Pin does, and Pin is a
button you press.

**But forgetting the second address is not neutral either.** Until now the wandered location lived in
`CanvasPageHandover.resumes`, a dictionary in memory, so it survived a pause — a page frozen on the
canvas woke in a workspace tile where you left it — and died at quit. You followed three links out of a
tracker, closed the lid, and the board had tidied up after you. Losing it was never the safe option:
Home and Pin are how a wandered card is resolved, and an app that forgets overnight has taken that
choice away rather than made it.

[`CanvasPageVisits`](../pm-mac/PM/Canvas/CanvasPageVisits.swift) writes it down. Two rules make it
small and make Home mean something:

- **The address, never the session.** `interactionState` carries the scroll position and the
  back-forward list, and it is a blob of WebKit's own making — half-filled forms, a POST body. That is
  a thing to hold in memory for the length of a pause, not to write into a file that outlives the
  session. Across a relaunch a card opens at the page; the history starts again.
- **A card on its own address has no row.** The board already says where that is, so Home is a real
  erasure rather than something the next launch undoes.

Recorded as each navigation commits and as a card is paused, which between them cover every way a page
moves and every way a card stops — quitting freezes nothing, and `prepareForRemoval` tears a card down
without asking the page anything.

## A link on a page can become three things

A board can do something with a link that a browser cannot, and the answer is now offered in the place
every browser has taught people to look for it.

| gesture | what happens |
|---|---|
| click | the card goes there — wandered, with Home and Pin in the header |
| ⌘-click | on the board: a card of its own beside this one, with no line. In a workspace: a tab in this tile, showing |
| ⇧⌘-click | the same, but a workspace tab opens behind and you stay on this page |
| middle-click | the same as ⌘-click (the gesture's one meaning in every browser) |
| right-click ▸ Open Link as New Card | the same, and findable |
| right-click ▸ Add Link to *Project* | into the project's `## Links` |
| right-click on the page ▸ Add Page to *Project* | the same, for where you have ended up |

⌘-click always did the useful half of this and never announced itself; a gesture nobody is told about
is a gesture for the person who wrote it. The menu is the announcement.

**Which link was right-clicked is the page's to say, and it says so asynchronously** — macOS `WKWebView`
has no public API for it, so the answer is a hit test in the app's own script world, the same one
`acceptsTyping` makes for a drag ([CanvasPageView](../pm-mac/PM/Canvas/CanvasPageView.swift)). A drag
can be told late because AppKit keeps asking; a menu is built once. So the right-click event is held
until the answer arrives and then passed on, which costs nothing visible — the menu was always going to
appear a round trip after the press.

**"The current project" here is the board's, not the engaged card's.** Everywhere else on a board that
question is answered by `engagedProjectCard`, and it cannot answer this one: you are inside a web card,
so no project card is engaged at the moment the answer is wanted. What is left is where the board lives
— `CanvasProjectNoteCard` already asks it — and a canvas elsewhere in the vault has no project and is
offered nothing. That is the same question retired [canvas-backlog.md](canvas-backlog.md) #13 answered from the
other side, and it is a *different* answer, for a reason: #13 is asked from the board.

## Links get named, and mostly for free

A link row that reads `https://wiki.example.com/spaces/ENG/pages/8814593` is a row you have to decode
every time you look at it. Four sources, in order, and only the last one is a network call:

1. **A label you typed.** Always wins.
2. **`CanvasPageTitles`** — what any web card has ever loaded, keyed by address and shared across
   boards. Free, instant, and already there for anything you have had on a board.
3. **What the source said.** The text of the link you right-clicked; `public.url-name` beside a link
   dragged out of a browser; the label of a markdown link pasted as words. All of these are the page's
   own name, already fetched by somebody else.
4. **The page, asked** — [`LinkTitleLoader`](../pm-mac/PM/Model/LinkTitleLoader.swift), which reads to
   `</head>` and stops, and hands the bytes to [`HTMLTitle`](../pm-swift/Sources/PmLib/HTMLTitle.swift).

The fetched name lands *second*: the row appears immediately and acquires its label a moment later, and
only if nobody has typed one in the meantime. Holding the write until a page answers would put an
eight-second pause, on the timeout of a site that may never reply, between asking for a link and seeing
one.

**It rides the favicon switch rather than growing one of its own.** Same host, same moment, same claim
— ask the site you linked to about itself — and the Settings row already carries the sentence. A second
toggle would be a second decision about one thing.

**A card falls back to the icon its page declares.** The loader asks for `/favicon.ico`; plenty of
sites serve theirs only through `<link rel="icon">`. When a card finishes loading and its host still
has no icon, it reads that URL out of the page and hands it to `FaviconLoader.adopt(declared:for:)`,
which fetches it (https only, same cookie-less session) and caches it under the host, so the tab strip,
the card menus and the address bar all pick it up. The URL is one the page you are viewing chose, so
it reveals nothing the visit didn't, and the same switch turns it off.

## Open

**How much more of an address bar.** Today: back, forward, reload/stop, the address field, and Home and
Pin when the card has wandered. ⌘F already searches the page. What is genuinely missing is a list, not
an argument — find-in-page in the bar rather than only on the key, a favicon and a progress state in
the field, a back-history menu on press-and-hold, copy and open-in-browser where the address is. Each
is small; the question is which of them a card is *for*, given that the answer to "I want to use this
page properly" is Open in Browser and always has been.

**Searching from the field is off until chosen.**
- Words that aren't an address go to the engine picked in Settings (`CanvasSearchEngine`): DuckDuckGo, Google, Bing, Ecosia, Kagi or Startpage.
- The default is `none`. With none, the field rejects what isn't an address.
- Why: sending what you typed to a search engine is a network request, and nobody has agreed to it until they pick one.

**What ⌘-click makes — decided 2026-10-24, in a mock.**
- In a workspace: a tab in the tile it was clicked in, shown and stepped into. ⇧ leaves it behind.
- In a satellite: a tab in that satellite (`CanvasSatelliteWindow.adopt`), as well as in its tile. Was: a new tile beside, which split the workspace smaller with every link followed.
- On the board: a card beside, with no line. Was: joined by an edge, so every quick look added an edge to the `.canvas` file.
- ⌘-click, middle-click and Open Link as New Card all go through `CanvasLinkNodeView.openAsNewCard`.
- Rejected: a loose card saved only on Keep; pages stacked inside one board card.
- Checked in a whole-app scratch harness: a tab joins the tile and shows, with no new column, tile or edge. On the board: one node, no edge. A negative control (forcing the old path) fails it. The ⇧ behind path isn't tested, because it reads the live modifier keys.

## Browser habits a card follows

**Links from other apps open in Folio, if you choose it.**
- `http` and `https` are declared in `CFBundleURLTypes` with `LSHandlerRank: Alternate` (project.yml). Folio shows up in Open With and in System Settings' default-browser list, and never becomes the default on its own.
- An incoming link with a satellite in front becomes a tab in that satellite, and shows. It goes into the satellite's tile in the workspace too, so Bring Back and Gather keep it.
- Otherwise it lands on the front project window's board, or on the focused project's window if none is open. That window switches to its canvas tab and from List or Grid to the board ([CanvasIncomingLinks](../pm-mac/PM/Canvas/CanvasIncomingLinks.swift)).
- Before the fix (2026-10-24), from a satellite: the satellite isn't a project window, so the link went to the project window behind it, which was in List view, and the card wasn't visible.
- A board that already has a card on that address reveals that card instead of adding a second one.
- The card is stepped into, so the page is live and the keyboard goes to it.
- These are three of Apple's criteria for the browser passkey entitlement (S-008).

**Go to Project over a browser carries its front tab — added 2026-10-28.**
- Summoned over Safari or a Chromium browser (Chrome, Brave, Edge, Arc, Vivaldi), go-to-project shows the front tab as a page chip beside the field ([BrowserTab](../pm-mac/PM/QuickBar/BrowserTab.swift)).
- A browser not on the list is recognised by its scripting dictionary: `active tab` means Chromium (Helium, Thorium), `current tab` means Safari.
- With the chip, ⏎ on a project opens the page as a tile in one of that project's workspaces. ⌘⏎ opens it in a new satellite whose card keeps a tile in that workspace (`CanvasIncomingLinks.open(_:inProject:inNewWindow:)`).
- Which workspace: the tab that's up if it's a workspace or the notes; else the first workspace tab in the row; else the Notes workspace (`ProjectSplitViewController.goToWorkspaceForIncomingPage`).
- Never the canvas tab. The first version used the incoming-link path, which switches to the canvas; the page landed on the freeform board, which isn't a useful view (2026-10-28).
- The page is placed once the workspace's tiles are laid out (`CanvasPaneController.whenTiled`). A board that hasn't tiled after a second gets the page anyway.
- The project's focus doesn't change. ⌫ on an empty line drops the chip, and the rows go back to focus / open.
- A page already on that board is reused, not added again. If it isn't in the workspace's tiles, it joins them. If it's already out in a satellite, that satellite comes forward.
- The tab is read with Apple Events: `com.apple.security.automation.apple-events` plus `NSAppleEventsUsageDescription` (project.yml). macOS asks once per browser.
- Not Accessibility, which would also cover Firefox but is a grant over every app. Firefox has no scripting dictionary, so no chip.
- Only http and https pages; a new-tab or settings page gives no chip.
- The read runs off the main queue. The bar is up before the browser answers, and an answer for a bar that's gone is dropped.
- Not offered when Services ▸ Send to Project in Folio is choosing a project.
- Checked in a whole-app scratch harness: a page becomes a workspace tile; a card elsewhere on the board joins the workspace (fails without the fix); `whenTiled` waits for tiles and gives up after a second; ⌘⏎'s satellite path works tiled and untiled, and a second carry reuses the card.
- Tried in the installed app with Helium (2026-10-28): the chip appears. Tab choice isn't covered by a test, because it needs a whole project window.

**The status line shows where a link goes.**
- It sits at the bottom-left of the card, as in Safari ([CanvasLinkStatus](../pm-mac/PM/Canvas/CanvasLinkStatus.swift)).
- With ⌘ held it reads "Open as a new card: …", because ⌘-click writes to the `.canvas` file.
- It is fed by WebKit's private `_webView:mouseDidMoveOverElement:withFlags:userInfo:` and `_WKHitTestResult.absoluteLinkURL`. Both were confirmed present on macOS 26 (2026-10-24).
- Synthetic `mouseMoved` events never reach a page: WebKit takes hover position from the real pointer. The callback can only be checked by hand.
- `javascript:` links and non-links show nothing. The line hides 0.25s after the pointer leaves a link, so moving between links doesn't make it flicker.

**Two-finger swipe goes Back and Forward, in the engaged card only.**
- `allowsBackForwardNavigationGestures` follows `isEngaged`. It is set when the page is built, when a page is handed over and in `engagementChanged`. A focused tile and a satellite card count as engaged.
- WebKit offers the horizontal swipe to the page first, and it becomes Back only at the page's left edge. A carousel still scrolls.
- Unengaged cards keep it off. The board passes a wheel over any card to that card's page (`CanvasBoardView.scrollWheel`), so with it on, panning sideways across the board would send each card it crossed Back.
- It follows System Settings ▸ Trackpad ▸ Swipe between pages.

**Revealing a page on an earlier signal than "finished" — settled, and the argument is worth keeping.**
The page used to be hidden until `didFinish`, which on an app-shell page is long after it was worth
looking at. It is now revealed when it has *painted*: the honest milestone is private, so the card
photographs itself every 200ms from `didCommit` and asks
[CanvasPagePaint](../pm-mac/PM/Canvas/CanvasPagePaint.swift) whether there is a page on the picture.
`didFinish` and the eight-second give-up stay behind it for pages whose first paint is one flat colour.

The API reading that had to be measured rather than assumed:
`suppressesIncrementalRendering` is not the milestone made public — it withholds painting until the
load *ends*, so with it on there is nothing to photograph until the very event this stopped waiting
for. Measured at 2.7 seconds of difference on an app shell. See [canvas-backlog.md](canvas-backlog.md)
#1.

## A card that isn't running a page still shows one

Freezing a card has always left a snapshot behind, because a board where the cards you aren't looking at
turn back into globes tells you less the more of it you can see. The picture belonged to the **view**,
though, which is the shortest-lived thing in this story — so it was missing from the two moments it was
most wanted, and stretched in a third.

- **A card recycled out of the pool.** Cards are built as they scroll into view and thrown away as they
  leave, and `prepareForRemoval` tore the page down without asking it anything: no picture, no fresh
  session, nothing. Scroll a card off the board and back and it came up as a globe and a hostname,
  having been a page a second ago — and this is the *common* path, far commoner than a pause.
- **A relaunch.** Every board opened cold and filled itself in over the next several seconds as the
  budget woke the cards one at a time. That is the moment a board most needs to say what it is, and it
  was the moment it said least.
- **A card that changed shape.** The picture was an `NSImageView` set to `scaleAxesIndependently`, so a
  tile whose workspace had been rearranged showed a page squashed into a column or pulled across the
  screen. That is the one way a placeholder can be *worse* than a globe: a globe admits it isn't the
  page.

The first two are one answer — [`CanvasPageSnapshots`](../pm-mac/PM/Canvas/CanvasPageSnapshots.swift)
keeps the picture for the **card**, keyed exactly as the page and the resume address are, in memory for
this session and in the caches directory for the next. It is a cache in every sense that matters: it is
derived entirely from pages PM happened to load, throwing it away costs one board opening as
placeholders, and it is bounded at both ends — 80 cards in memory, 400 files on disk, the longest edge
capped at 1400px and stored as JPEG, because it is a stand-in a loaded page crosses out in a fifth of a
second and is sized to read *as* the page rather than to be read.

The third is [`CanvasFrozenPageView`](../pm-mac/PM/Canvas/CanvasFrozenPageView.swift), which draws the
picture **scaled to the card's width and anchored at the top** — how a picture of a page degrades
honestly: the column keeps its proportions, the headline stays a headline, and a card that got taller
shows the top of the page and then stops, which is what a page scrolled to the top actually looks like.
Fitting the whole picture inside and letterboxing it was the alternative, and it reads as a photograph
of a screen rather than as a screen.

**Forgetting is a remembered miss, not a deleted row.** Deleting the file is IO and happens when it
happens; dropping the row would send the very next lookup back to a disk that still has the old picture
— and the next lookup is usually immediate, because changing a card's address rebuilds the card.

## Suspending a page, instead of freezing it

Measured 2026-09-25 on macOS 26, one page timestamping a 100ms timer and every animation frame
(harness test `ScriptFreezeTests`).

| Way | Timers/s | Frames/s | Renderer CPU | Page state |
|---|---|---|---|---|
| On screen | 9.7 | 60 | 1.5% | kept |
| View hidden, out of its window, or window ordered out | 1.3 | 0 | — | kept |
| `setAllMediaPlaybackSuspended(true)` | 9.7 | 60 | — | kept |
| `_suspendPage:` | 0 | 0 | 0.0% | kept |
| Freeze as built (snapshot, then tear down) | — | — | none | lost; restored from `interactionState` |

- WebKit throttles a page on its own once its view isn't visible: `visibilityState` goes to hidden, frames stop and timers drop to about 1 per second.
- `setAllMediaPlaybackSuspended` stops media only; scripts run on.
- `_suspendPage:` / `_resumePage:` are private WebKit API (`WKWebViewPrivate`), present on macOS 26, each with a completion block.
  - Suspended, the page runs no timers and draws no frames.
  - It resumes where it was: script variables are kept, and timers carry on.
  - The renderer process and its memory stay (28 MB for the test page). Suspending saves CPU, not memory.
- Freezing as built saves memory and loses page state: a web app's in-memory state and unsaved form input don't survive `interactionState`.
- Also present, not tried: `WKPreferences` `_setHiddenPageDOMTimerThrottlingEnabled:`, `_setHiddenPageDOMTimerThrottlingAutoIncreases:` and `_setPageVisibilityBasedProcessSuppressionEnabled:`.
- Why a frozen card looks like a picture: it *is* one. It's a JPEG capped at 1400px on its longest edge, drawn scaled to the card, with no hover, no selection and no live text. A suspended page keeps its own layers in the view.
- Not measured: whether a suspended page's layers stay sharp when the board zooms.
- A third page-budget state (live, suspended, frozen) would trade memory for keeping state. A per-site switch in `CanvasSiteSettings` would choose it for the pages that can't afford to lose state. Not built.

How stable `_suspendPage:` is:

- Added May 2021: [WebKit bug 225333](https://bugs.webkit.org/show_bug.cgi?id=225333), r277356, `WK_API_AVAILABLE(macos(12.0), ios(15.0))`. Unchanged in WebKit main as of 2026-09.
- Covered by WebKit's own API tests (`ProcessSuspension.mm`).
- Made for an Apple-internal client (a private radar); no public documentation or promise of support.
- It suspends the page in place, as the back/forward cache does, without a history item.
- On a suspended view most calls throw — script evaluation, find and snapshots among them. URL, title, `isLoading` and `canGoBack` still answer. Navigating resumes the page first. Deallocating or closing a suspended view is safe.
- `_isSuspended` read 0 while the test page was suspended, so it can't be relied on.
- If built: check `responds(to:)` and fall back to freezing; route every call on a suspended card's view through one wrapper that resumes first; offer it per site only. Decided 2026-09-25: not now.

## Frame rate, and what filtering costs a page

Measured 2026-09-30 on an M1 Max with a 120 Hz display, with scratch harnesses.

- WebKit rounds page rendering to about 60 fps by default (`PreferPageRenderingUpdatesNear60FPSEnabled`), in a `WKWebView` as in Safari. Figma's desktop app and Chrome run at 120.
- The card you have stepped into, which includes the focused tile and a card in a satellite, runs at full rate. Every other card stays at 60. See `CanvasPageView.setFullFrameRate`.
- An animating page at 60 fps: 8% GPU process, 7% web process. At 120: 15% and 12%. A page that isn't animating draws nothing at either rate.
- A running page reads the preference only when its visibility changes. The card makes WebKit see a one-frame visibility change without hiding anything, so the page gets `visibilitychange` to hidden and back, and keeps focus.
- Board zoom, a tile's shape mask and the card shadow cost nothing measurable.

| Content rules on a page | Style recalc, 12,000 elements |
|---|---|
| none | 17.6 ms |
| network rules only (119,517) | 17.8 ms |
| generic hiding only (596 rules, 55,715 selectors) | 20.8 ms |
| as shipped | 20.8–23.0 ms |

- Generic hiding rules (`css-display-none` without `if-domain`) go into every filtered page as one stylesheet, and every style recalc pays for them. Network rules cost nothing per recalc.
- Nothing about this has a frequency to lower: the stylesheet is matched on each recalc, and WebKit indexes the selectors.
- The same selectors run from a script with `querySelectorAll` took 2.7 s per pass on 4,000 elements and 7.9 s on 12,000.
- Rule lists attach when a page is built, so which pages get generic hiding can only change with a rebuild.

## Which of the two addresses each command means

Every command on a web card has to answer this, and the answer is not the same one twice in a row. It
is written down here because two of them used to get it wrong silently.

| means the **saved** address | means the **live** one |
|---|---|
| Home — the whole point of it | Open in Browser |
| Pin, which overwrites the saved one with the live one | Copy Address |
| the placeholder's name and host: a card is *for* something | the header's field, and what VoiceOver reads |
| Sign In / Sign Out / Block Ads — per site, and the site is the card's | Add Link/Page to Project |

Open in Browser and Copy Address were on the left-hand column until they had no business being there:
following three links out of a tracker and asking for a browser handed you the tracker — the one page
you could already see, instead of the one you had gone to the trouble of finding.

The sign-in and filtering row is the interesting one, and it stays on the left deliberately. Those are
per *site* rather than per page, and the site a card belongs to is the site it is for; a card that has
wandered onto an identity provider mid-redirect should not offer to sign you out of the identity
provider.
