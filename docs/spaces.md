# Spaces, focus, switcher, command bar

Design, 2026-11-04. Decided in the interactive mock (`.claude/mocks/folio-spaces.html`).
Related: [web-cards.md](web-cards.md), [concepts.md](concepts.md), [canvas-workspaces.md](canvas-workspaces.md).

## Spaces

Rebuilt 2026-11-04 on workspaces (`Spaces`, `SpaceModel`). The first build, a browser window of its own with a tab sidebar, is gone.

- A space is a board and its workspaces that belong to no project: a canvas file, `~/.config/pm/spaces/<id>.canvas`, opened in the ordinary window.
- So it holds any tile a project's board does: web, folder, file, note, view. Workspaces, tabs in tiles, pop-outs, the address bar, Copy Sign-In From all work as they do on a project.
- `~/.config/pm/spaces.json` keeps what a file can't: name, icon, colour.
- File ▸ New Space: untitled, an empty board in its window. Named with Rename… on its dock mark; clearing the name makes it untitled again.
- A dock mark's right-click menu: Show Window, Rename…, Colour, Delete Space… (the canvas goes to the Trash).
- The window is named for the space (Untitled Space until named).
- Never the focused project: a window on a file changes nothing (concepts.md § Workspace).
- Comes back at launch with the other windows (Settings' Restore).
- Web cards in a space use the shared sign-ins, or a card's own Session; there's no per-space store.
- Spaces from the first build: their tabs became web cards in a row on the new board, once (`Spaces.carryOverTabs`).
- Links from other apps (Folio as the default browser) go to a space whenever one exists: the space whose window is furthest forward, else the one last in front (`Spaces.lastUsed`), else the first. The card on that address if the space has one, else a new card in Today, shown. With no spaces, the front window's board as before.

## The frame

Decided 2026-11-04 in `.claude/mocks/folio-space-frame.html`. Built for spaces the same day (`SpaceFrame`, `SpaceCardMarks`); not yet for projects.

- Built: the sidebar in place of the project list in a space's window (the tab row hidden); favourites, Board, workspaces among Pinned, pinned and Today cards, frames as folders (click to fold); click, ⌥-click, ⌘-click + ⌘↩ ("Tile N as a Workspace"); Pin, Favourite, Open in a Tile Beside, Close on a row's menu; the address field (⌘T) making a web card; ⌘W on the card in front.
- Polished 2026-11-04 against renders of a real window: Arc's row and favourite styles (the card in front a raised chip), a rule between pinned and Today, workspace rows led by their tiles' icons, the space's colour and name at the foot, the window washed in the space's colour.
- No header in a space's window (`CanvasPaneController.hidesHeader`): no title pill, tab bar or trailing controls. Tiles have the usual 6pt gap on every side, sidebar or not.
- Dead space, as Arc: in a layout (a space's or, since 2026-11-05, a project's, and the one card filling the window in focus mode), a press in the top 96pt of a tile's page (`CanvasPageView.deadSpaceBand`; 56pt missed Apple Music's header) on nothing usable moves the window; double-click is the title bar's action. Nothing usable = WebKit's cursor is the plain arrow (not a hand or an I-beam) and its last hover report was no link, image, media or editable field (`isDeadSpace`, `hoverIsInteractive` from `mouseDidMoveOverElement`). And the page itself says nothing there is its own (`CanvasPageView.pageUses`, asked on each WebKit hover report — `mouseMoved` and the view's own tracking areas never hear the moves; a press before the answer for the latest report is the page's; "page kept a press in the band" logs one): not inside a button, form control, ARIA widget role, `tabindex` ≥ 0, `draggable`, `contenteditable` or `onclick`; not on a `canvas`, `iframe`, `video`, `embed` or `object`; not inside a dialog, or a fixed/absolute box inset from the viewport's left, right and top (a floating panel). Figma's toolbar buttons keep the arrow cursor and its Variables panel has a blank header, 2026-11-05. Whether a page is a space's tile is asked of the board it's in at the press, not the card that built it: running pages are handed between panes. A drag from a page logs "window drag from page dead space: <host>".
- The window's top 3–4pt is its resize edge, so the 6pt gutter above the tiles is mostly that; the page's dead space is the handle that matters.
- The sidebar's list fills its scroll area, so empty sidebar below the last row is drag area too. Each gutter or sidebar drag writes "window drag from …" to the log.
- Sidebar shortcut: ⌘S in a space (Arc's), and ⌃⌘S / View ▸ Show Sidebar. A space's sidebar is a plain pane, so the split's own toggle (which only moves a sidebar-behaviour item) is replaced there (`toggleSpaceSidebar`).
- With the sidebar folded, it floats back over the content (`SidebarPeek`, the same `SpaceFrame` model): while the pointer is at the window's left edge (6pt, `EdgeReveal`), going 0.35s after it leaves; and for ⌘T / ⌘L, with the address field taking the keys, going when Return or Esc ends it.
- With the sidebar folded the window's buttons are hidden; they fade in while the pointer is in the window's top-left corner (96×44pt, `CornerReveal`), over the page, as in Arc.
- Dragging, as Arc: the frame round the tiles (`WindowDragView` gutters, 6pt, and the top band) and the sidebar's empty space move the window; double-click follows System Settings' title-bar action. Pages never do: a click-through `WindowDragBlocker` carves the titlebar band over the tiles' tops only. The gutters are plain views, not `NSControl`s: in the band, a control carves the band's own drag and its press goes to the titlebar's views, so a gutter there moved nothing; now the band's own drag answers there, and the gutters answer below it. Dividers between tiles still resize them. A ground press on the board also drags, and ends the board's press first (a window drag swallows the mouse-up, which left the board "pressed").
- Beside the sidebar, the gutter at the tiles' leading edge is the sidebar's edge (`SidebarEdgeHandle`): a column-resize cursor, and dragging it resizes the sidebar within its min and max. With the sidebar folded it's window ground again. It replaces the divider: the split's divider in a space has no width and nothing to grab.
- A click on a tile in a layout clicks through to its content as well as focusing it — every board, not only spaces. It always meant to (`tileClicked` listens, never consumes), but stepping in raised the page's frame rate with one frame of "hidden", in the frame the press arrived, and WebKit dropped the press. The pulse now waits for the button to come up (`CanvasPageView.pulseWhenReleased`).
- The sidebar is a plain split pane in a space (no glass plate), painting the content's `CanvasColorWash` in the space's colour, so the two are one ground; the split's divider line is clear (`ProjectSplitView.hidesDivider`). The custom split view must be set up as the controller's own is (`arrangesAllSubviews = false`, vertical) or every window crashes at launch.
- The tile grip opens the tile's controls on every board's layouts, project or space (2026-11-05); Pin and Favourite only in a space; ✕ is Out of the Layout everywhere, which ⌘Z or ⇧⌘T undoes; search is Settings' engine everywhere. Was: in a space, (`CanvasTileControls`; mock `.claude/mocks/folio-tile-grip.html`): rest on the grip 0.3s, or click it; a click on the grip never closes it. A capsule unfolds from the middle of its top edge (SwiftUI scale and fade on a spring), 4pt under the grip; it ignores the titlebar safe area (a hosting view there pushed it 28pt down); the grip stays above it and still drags the tile. Back, Forward, Reload, the site (click: the address field in place, with suggestions; Return goes, Esc puts it back); Pin, Favourite, Maximize (with two or more tiles), Out of the Layout (as ⌘W, so ⇧⌘T brings it back), More (the tile's right-click menu). A tile that isn't a web page has the second half. Closes 0.45s after the pointer leaves grip and capsule (not while editing), when the tile leaves the layout, and on a window resize.
- The grip stays shown while its capsule is open, through a click on it (a press starts a tile drag in case; only dragging 4pt closes the capsule and hides the grip with the others).
- A lone tile has a grip too, on any board, for its controls; a press on it drags nothing.
- Not built: Keep as Workspace for an unnamed tiling.
- Dragging a card's row (spaces and projects, 2026-11-05; `SpaceRowDrag`, `SpaceRowDropTarget`). A line marks where it would land; nothing moves until it's let go. The row being dragged dims.
  - Within a list: reorders it. Order is `pmOrder` on each card in the list (`SpaceCardMarks.orderKey`), renumbered on each drop; unmarked cards follow marked ones in reading order.
  - Into Pinned: pins (out of Favourites if it was one). Into Today / Cards: unpins. Onto the favourites: favourites; an empty dashed well appears there while a row is dragged and there are none.
  - The rule between Pinned and Today: its top half is the end of Pinned, its bottom half the start of Today; it turns accent while targeted. New Tab: the start of Today.
  - Into a folder (between its rows, or on its header): the card moves into that frame on the board, under the cards in it, the frame growing to hold it. Out of a folder: the card moves right of everything on the board. Favourites don't move the card.
  - Onto a workspace row (ringed): the card joins that workspace, which comes up with it focused.
  - Onto the tiles: the board's own drop mark, labelled (New Column, New Tile Above / Below, As a Tab, Replace). A card not up replaces a tile in its middle; a card already up moves as a pulled tab (middle: into that tile's tabs; its own tile: nowhere). Over the Board overview: refused. Over a page: always the board's, never the page's.
  - A drag held at the edge of the tiles (or over the band above the top tile) doesn't scroll them, any drag (`CanvasClipView`, 2026-11-05: it slid the layout partly out of view). Off the tiles, a drag at the board's edge still scrolls it.
  - A web row carries its address: another app, or another board, takes it as a link.
  - Onto a space's dock mark (lit while over it): the card moves to that space as Today, unpinned, off the board it came from, a space's or a project's (`CanvasSatelliteDock.rowDrop`, `Spaces.move(_:fromCanvas:to:)`). Onto a project's mark: a space's web card goes onto that project's board, as the flyout's Send ▸ Card. Its own board's mark refuses it.
- Dragging a workspace row among the workspace rows reorders them (2026-11-05). The order is kept per board in defaults (`PMCanvasWorkspaceOrder`, `CanvasWorkspaces.ordered`); unordered ones follow alphabetically; a rename keeps its place. Menus stay alphabetical. The row carries a tab chip's type (`ProjectTabDrag`), which nothing else takes.
- The frame for projects, decided 2026-11-05 in `.claude/mocks/folio-project-frame.html`; built the same day (`SpaceFrame` with `project`, `ProjectSplitViewController.syncFrame`). Off with `defaults write <bundle> PMProjectFrameOff -bool YES`. A window on a file that's neither a space nor a project's board has no frame. Spaces and projects behave alike unless there's a reason (one sidebar, one rule per key).
  - Other projects: the project's name at the sidebar's top opens a popover: filter chips, then the project list (`ProjectSidebar`, Up Next first). Picking one switches the window. File ▸ All Projects… opens the same popover. Was planned: a window of its own for All Projects….
  - Up Next leads the project list wherever it's shown.
  - Filters (Active / Archived / All, by due / by domain): chips over the list.
  - Favourites: as a space's, icon tiles under the name.
  - Cards not pinned: a Cards section, every unpinned card on the board, frames as folders. Nothing archives; no Today, no Clear.
  - Notes: a row above Board.
  - The foot: the focused task (tick to complete) and the session's time, in place of a space's name.
  - Everything keyed to a space's frame applies to a project's too: no header or tab row (so no title pill, board capsule, Away or browser chips), ⌘T / ⌘L the sidebar's address, ⌘1…⌘9 and ⌃⇥ the sidebar's cards, ⌘W the card in front (in Notes: back to the board), ⇧⌘C the page's address, ⌘S the sidebar, Pin and Favourite in the tile capsule.
  - ⌘-click and new-window links in a project: a new card, shown in the tile you're in, as a space's.
  - The notes card is the Notes row, not a card row; its Notes workspace isn't a workspace row.
  - No List lens under the frame (its rows were the sidebar's again): Board is Freeform or Grid; a board remembered as List opens as Freeform, and View ▸ Show Canvas As ▸ List is dimmed. Windows without the frame keep it.
- A new card from the address field or a link (`openNewCard`) goes onto the board and into the tile you're in; it no longer joins the named workspace up as well (2026-11-05: ⌘T in a space's named workspace grew the workspace).

- An Arc-style sidebar over a board's workspaces. The sidebar lists what's on the board; the main area is the workspace tiling.
- For spaces and projects alike. A project's sidebar has Notes as a row. Replaces the window's tab row; supersedes "projects keep their window" above.
- Sidebar, top to bottom: the address; favourites as icons; Board (the freeform canvas, the overview); Pinned; Today (spaces only), with New Tab.
- A row is a card: web, folder, file, note, view. Frames on the board are folders in the sidebar.
- Named workspaces are rows among Pinned, showing their tiles' icons.
- Pinned and favourite are marks on the card, stored on the node (`pm*` keys), so the board stays the one record. The rest of a space's cards are Today; they stay until closed.
- Clicking a card that isn't showing replaces the tile you're in, as Arc. In a named workspace of several tiles, that leaves the workspace for the card on its own.
- Clicking a card that's in another named workspace jumps to that workspace, with the card's tile picked.
- ⌥-click: a tile beside the one you're in. Dragging a row onto the tiles: beside, as a tab, or in place, where it's let go.
- ⌘-click rows, then ⌘↩: tile them as a new workspace (a new Pinned row).
- Tiles keep grid / master-and-stack, sizes, maximize, pop-out. A tile's strip shows only in a split.
- ⌘T: a new card in Today, shown in the tile you're in (File ▸ New Tab is enabled in a space though it has no project).
- ⌘W: the focused tile out of the layout; the card stays on the board and in the sidebar, ⌘Z puts it back. With no tile focused, the window closes. A row's Close in the sidebar still takes the card off the board (a pinned one is unpinned).
- ⌘L: the sidebar's address field on the page in front, which Return sends there (the header's field is hidden in a space).
- ⌘1…⌘8: the sidebar's cards in order (favourites, pinned, today), ⌘9 the last; the menu items are titled after them.
- An unnamed tiling of several tiles offers Keep as Workspace.



- Projects, a divider, then every space, open or not. Same squircle marks; a closed space's is dimmed. A space's window and pop-outs belong to its mark. The dock shows whenever a space exists.
- The focused project's mark has a ring in its colour. Built.
- Not built: a grey bar beside the mark of the window in front, apart from focus.
- Playing sound: WebKit's own `_isPlayingAudio`, observed on the page (`CanvasPageView.isPlayingAudio`, posted as `audioChanged`) — on the page because pages move between panes. Shown as a speaker on the card's sidebar row (click: pause) and favourite tile, on the card and tile rows of the ⌥Tab switcher, a dot under the dock mark, and in the space's flyout.
- A space's dock flyout (`SpaceDockCard`): name, card count, Show Window; a Now Playing row with pause for each card making sound; the cards, pinned first, which open in the space; a web card's menu sends it to a recent project as a card (off the space), into its Links, or as a task.

## Browsing

Built 2026-11-05.

- A link that asks for a new window (`target=_blank`, not a sized pop-up) in a space: a new card in Today, in front (`CanvasBoardView.opensNewTab`). On a project's board, what ⌘-click makes there (2026-11-05; was: it navigated the card).
- ⌘-click in a space: a new card in Today, in front; ⇧⌘-click leaves it in the sidebar.
- ⌃⇥ / ⌃⇧⇥ and ⇧⌘] / ⇧⌘[ in a space: the next / previous card in the sidebar's order, wrapping.
- The sidebar's address field is the header's (`CanvasAddressTextField`): suggestions, filled-in addresses, ↑↓, Tab, two-step Esc. Searches go to Settings' engine; with None, only addresses (2026-11-05; was DuckDuckGo over None).
- The sidebar's address field shows the focused tile's page as it is now (host and path, not the card's saved address), following focus between tiles and the page's navigation.
- Suggestions (header and sidebar): the board's web cards, the card's back list, history (most visited, then newest), pages with a remembered name.
- History: `~/.config/pm/history.json`, one row per address (title, last visit, count), newest 10,000 kept (`CanvasHistory`). Recorded on a card's finished load and on title changes (sites that move without loading). Not from a Private card; http and https only.
- History menu: Reopen Closed Card (⇧⌘T), Show All History (⌘Y), the last 15 pages, Clear History… (all, or today).
- History window: search, pages by day, Open / Copy Address / Remove from History; double-click opens. Opening a page goes where links from other apps go.
- ⇧⌘T: the last card closed in a space (⌘W or a row's Close) or taken out of a project's layout, this run only, 50 kept. Still on the board (⌘W): shown again; gone: a new card on the address it was at.
- File ▸ Print… (⌘P) and Export as PDF…: the page you're in, else the focused tile's, else the one selected web card. Paged to the paper's width.
- Clear: on the rule above Today while the pointer is in the sidebar; every Today card off the board (⌘Z brings them back). Pinned and favourites stay.
- Archive (the rule's or the space name's menu, per space, `Space.archiveAfter`): Never, 12 hours, a day, a week, 30 days. A Today card not on screen (and not playing) for that long goes, checked at most once a minute. When a card was last on screen: `PMSpaceCardSeen`, by space and card; a card first seen counts from then.
- Downloads: Window ▸ Downloads (⌥⌘L) and an arrow at the sidebar's foot (a ring while one runs, a dot when one has finished). Progress while running; click opens, the magnifier shows in Finder, a row drags out as the file. Newest 30 kept (`PMRecentDownloads`). Clear forgets finished rows; files stay.
- A row's menu: Copy Address, Duplicate (the page it's at, with its back list), Mute / Unmute (the card's own Mute), Move to Space ▸ (off this board, onto the other's as Today, unpinned), or drag the row onto the space's dock mark.
- ⇧-click a link, in a space or (since 2026-11-05) a project: a preview over the window, Arc's Peek (`CanvasLinkPreview`). Same sign-ins, blocking and scripts as the card. Open as Card (⌘↩) makes it a Today card in front; Esc, ✕ or a click outside drops it. Links inside stay in the preview.
- The hovered link's status says what ⌘ (a new tab in a space, a new card elsewhere) and ⇧ (a preview) do.
- Mini player at the sidebar's foot: a card making sound that isn't on screen, or one it paused until that card is shown. Click goes to the card; play/pause; picture in picture (the page's largest video); ✕ pauses and hides it.
- Page menu: Show Reader (⇧⌘R) — the page's article (`<article>`, `<main>`, or the block with the most paragraph text) over the page in plain type; again, Esc or Close Reader takes it away (`CanvasReader`). Mute Page. More Page Commands ▸ Copy Address.
- ⇧⌘C in a space: the page's address on the pasteboard, as Arc's (in project windows it stays Canvas in New Window).

## Adding cards from the sidebar

Decided 2026-11-05 in `.claude/mocks/folio-add-cards.html` (two rounds); built the same day (`SpaceCardKinds`, `SpaceRecentFolders`, `SpaceFrame.make`, `CanvasAddressTextField.cards`). Spaces and projects alike.

Was: the sidebar made only web cards (address field, New Tab, ⌘T); every other kind was File ▸ New Card, a tab strip's +, or Board's right-click.

- The door is the sidebar's address field (⌘T, click). Typing a kind's name makes that card. New Tab stays the web row.
- Kinds and the names that match them: Card (card, text), File, Folder, Private (a private web card), Day, Leftovers, Coming Up, Projects, Time, Waiting, Search, Frame. No Web: the field makes web cards already. No note: a project's notes are its Notes row.
- File: the open panel (a project's starts in its folder). Private: the field again, for the private card's address.
- The empty field lists up to 3 recent pages, then every kind; Folder there types "folder" (its rows are the recent folders).
- Return on a kind's name makes the card. The name is filled in after the caret as you type (2+ characters), as an address is; Tab accepts it, deleting drops it. Anything more than the name ("time zones") is a search, as before.
- An address fills in before a kind does ("we" → weather.com, not Web). A kind fills in only when no address does.
- Otherwise kinds are rows after the search and the pages; ↑↓ Return picks one. A row says what it makes ("Time — New view").
- "folder": the rows are recent folders, Folder · <name> (a project's own folder first, then folders used on cards lately, Downloads), then Choose Folder…. One Return.
- A path (typing ~ or /): folders and files on this Mac; Return makes a folder or file card, Tab goes into a folder.
- A card from the field goes at the top of Today (space) or Cards (project), shown in the tile you're in; the card that was there stays listed. Frame: an empty frame on the board, a new sidebar folder.
- A folder's row has a + on hover: the add menu (File ▸ New Card's list, views in a submenu); the card goes into that frame, shown in the tile you're in.
- Right-click empty sidebar, or a project's Cards rule: the same menu; the card goes to the top of Today / Cards. A space's Today rule keeps its Clear / Archive menu.
- Web Card… and Private Web Card… in the menu: the field, then the card goes where the menu said.
- In the menu, New Folder is a submenu of the same recent folders, then Choose….
- Recent folders: `PMRecentCardFolders`, 12 kept, 5 shown; noted whenever a folder card is made, from the sidebar or the board.
- ⌘L (the page in front) offers no kinds: its field sends that page somewhere.
- "Folder" keeps both meanings: a frame is a folder in the sidebar; New Folder… / "folder" makes a Finder-folder card.

## Motion

Decided 2026-11-05 in `.claude/mocks/folio-spaces-motion.html`. All of it through `Motion` (Shared/Motion.swift): Reduce Motion drops the movement, and a fade stays only where noted.

- Switching cards in a space (a row, ⌃⇥, ⇧⌘] / ⇧⌘[, ⌘1…⌘9, the mini player, Open as Card) is a cut: `replaceInTiling(_:with:animated: false)`. From the Board overview it stays a crossing.
- Rows: closing, Clear, archive, Move to Space, ⌘T, pinning and favouriting animate the rows to their new places (0.22s ease-out). The card in front changing doesn't. Folders snap.
- Add to / Remove from Favourites: the card's icon moves between its row and its favourite tile (`matchedGeometryEffect`).
- Mini player: rises 8pt with a fade (0.2s); goes 4pt with a fade (0.12s).
- Clear on the rule fades (0.12s); the finished-download dot scales in from 40% (0.15s).
- ⇧-click preview: the window dims and the panel grows from 97% out of the click (0.2s); Esc, ✕ or a click outside fades it (0.12s); Open as Card moves the panel onto the page it came from (0.25s), then the card takes its place. Reduce Motion: fades.
- ⌘S: the sidebar folds and unfolds over 0.18s on an ease-out, no overshoot.
- Floating sidebar: after the pointer rests 0.08s at the window's left edge (`EdgeReveal.rest`); in from 24pt with a fade (0.18s), out 12pt with a fade (0.12s).
- Tile capsule: drops 4pt into place with a fade (0.16s); when the pointer leaves, rises back with a fade (0.12s); every other close is a cut. Widens and narrows round the address field (0.18s).
- Capsule symbols: Pin and Favourite replace (SF Symbols `.replace`) and bounce once turning on; Maximize / Restore replaces; Reload is Stop (✕) while the page loads. A control shrinks to 92% while pressed.

## Focus

Built 2026-11-04. Facts in [concepts.md § Focus](concepts.md#focus).

- A project can be unfocused: no focused project at all.
- Unfocus from: the menu bar item's menu, the dock mark's menu, the quick bar's `>` (and the Project menu).
- Unfocusing ends the attention span, so timing stops.
- Capture with nothing focused asks which project: a row per recent project.
- Not in the contract yet: no `project.unfocus` for the CLI, Raycast or MCP.

## Switcher

Built 2026-11-04 for projects (`SwitcherController`, `SwitcherModel`); spaces join the row when they exist.

- ⌥Tab, held: a row of open projects (most recent first), a divider, then spaces.
- First press lands on the item after the one in front, as ⌘Tab.
- Tab / ⇧Tab move along the row; ↓ ↑ move into a card's list; letting go of ⌥ jumps. Return and click also jump; Esc stays.
- A project card: icon, name, Focused, current session, focused task, then Notes and each workspace with its tiles.
- Open spaces follow the projects, past a divider, with their workspaces and tiles like a project's card. Built.
- Jumping to a project focuses it (its window becoming key does).
- The row is the dock's groups: project windows, projects with windows out, windows on a file. Ordered by window stack.
- A quick tap (⌥ up within 0.12 s) switches without drawing the panel.
- Bindable in Settings ▸ Shortcuts as Switch Between Projects; held by whatever modifiers it's bound with.
- Tiles are named from the canvas file, as a tile's tab names its card. Jumping to a tile opens its workspace and brings that card forward (`showTab`).

## Command bar

Not built.

- The quick bar, grown: one bar, one shortcut.
- Typing with no prefix finds: projects, workspaces, tiles, spaces, tabs in every space, tasks, commands.
- Capture is the last row: add what was typed to the focused project; with nothing focused, it asks which.
- Prefixes stay: `@` projects, `/` tasks, `>` commands.
- ⌘T in a space opens the same bar scoped to it, with "Open in <space>" first.
- Commands include Unfocus, New Space…, Show Switcher.
