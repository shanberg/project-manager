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

**Preserving a stale page's picture.** `freeze` snapshots before tearing a renderer down, so a paused
card still shows what it was showing. Three holes: `prepareForRemoval` tears down without taking one,
so a card recycled out of the pool comes back as a globe; nothing survives a relaunch, so a cold board
opens as placeholders; and the snapshot is scaled `scaleAxesIndependently`, so a tile resized since the
capture shows a stretched one. The reveal side of the same question is
[canvas-backlog.md](canvas-backlog.md) #1 — the page is hidden until `didFinish`, which on an app-shell
page is long after it was worth looking at.

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
