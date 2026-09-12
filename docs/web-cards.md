# Web cards, and how much of a browser one is

A web card is a page clipped onto a board: it loads, it takes clicks, you can sign in to it. It is not
a browser, and the whole design of it is a series of answers to *how much of one*. This page is where
those answers are, because they have stopped being one-off calls and started contradicting each other
when made separately.

The mechanics — when a page runs, who holds the renderer, what it costs to cross a workspace — are in
[canvas-workspaces.md §7](canvas-workspaces.md). The chrome that drives one is in
[header-chrome.md](header-chrome.md). This page is about the *page*: where it is allowed to go, what
comes back with it, and what a board does with a link.

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
| ⌘-click | a card of its own, beside this one, joined by a line |
| middle-click | the same (the gesture's one meaning in every browser) |
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
offered nothing. That is the same answer [canvas-backlog.md](canvas-backlog.md) #13 will want from the
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

## Open

**How much more of an address bar.** Today: back, forward, reload/stop, the address field, and Home and
Pin when the card has wandered. ⌘F already searches the page. What is genuinely missing is a list, not
an argument — find-in-page in the bar rather than only on the key, a favicon and a progress state in
the field, a back-history menu on press-and-hold, copy and open-in-browser where the address is. Each
is small; the question is which of them a card is *for*, given that the answer to "I want to use this
page properly" is Open in Browser and always has been.

One of them is a real argument and is settled the other way: **the field does not search.**
`CanvasAddress` rejects what isn't an address rather than reinterpreting it, because handing what you
typed to a search engine is a network claim nobody agreed to in an app that makes exactly one.

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
