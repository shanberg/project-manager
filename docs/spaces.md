# Spaces, focus, switcher, command bar

Design, 2026-11-04. Decided in the interactive mock (`.claude/mocks/folio-spaces.html`).
Related: [web-cards.md](web-cards.md), [concepts.md](concepts.md), [canvas-workspaces.md](canvas-workspaces.md).

## Spaces

Rebuilt 2026-11-04 on workspaces (`Spaces`, `SpaceModel`). The first build, a browser window of its own with a tab sidebar, is gone.

- A space is a board and its workspaces that belong to no project: a canvas file, `~/.config/pm/spaces/<id>.canvas`, opened in the ordinary window.
- So it holds any tile a project's board does: web, folder, file, note, view. Workspaces, tabs in tiles, pop-outs, the address bar, Copy Sign-In From all work as they do on a project.
- `~/.config/pm/spaces.json` keeps what a file can't: name, icon, colour.
- File ▸ New Space: untitled, an empty board in its window. Named with Rename… on its dock mark; clearing the name makes it untitled again.
- Also made from (2026-11-06, `Spaces.newSpace`): Spaces ▸ New Space, the dock's +, the switcher's New Space card, `>space` / `>space <name>` and `@`'s New Space “…” in the quick bar. A new space's window comes forward with Folio active.
- A dock mark's right-click menu: Show Window, Keep in Dock, Space Settings…, Rename…, Colour, Delete Space… (the canvas goes to the Trash).
- Space Settings (2026-11-07, `SpaceSettings.present(spaceID:)`): a window per space, brought forward if open. From the dock mark's menu and the sidebar foot's.
  - Name (empty: Untitled Space), Color (the named colours and a well; no None), Icon (Symbol or Emoji, Project Settings' pickers, `IconPickers`), Archive (Today's cards; `SpaceFrame.archiveChoices`), Delete Space… (`Spaces.delete`'s confirmation; the window closes with the space).
  - Live: each change goes through `Spaces.change`; the window title, sidebar foot, wash and dock mark follow. No Save or Cancel; Done closes.
- The window is named for the space (Untitled Space until named).
- Never the focused project: a window on a file changes nothing (concepts.md § Workspace).
- Comes back at launch with the other windows (Settings' Restore).
- Web cards in a space use the shared sign-ins, or a card's own Session; there's no per-space store.
- Spaces from the first build: their tabs became web cards in a row on the new board, once (`Spaces.carryOverTabs`).
- Links from other apps (Folio as the default browser) go to a space whenever one exists: the space whose window is furthest forward, else the one last in front (`Spaces.lastUsed`), else the first. The card on that address if the space has one, else a new card in Today, shown. With no spaces, the front window: under its frame, as a space's (the card on that address, else a new one in Cards, shown); a window without one, its board as before (2026-11-13).

## The frame

Decided 2026-11-04 in `.claude/mocks/folio-space-frame.html`. Built for spaces the same day (`SpaceFrame`, `SpaceCardMarks`); for projects 2026-11-05 (below).

- Built: the sidebar in place of the project list in a space's window (the tab row hidden); favourites, Board (until 2026-11-28; § below), workspaces among Pinned, pinned and Today cards, frames as folders (click to fold); click, ⌥-click, ⌘-click + ⌘↩ ("Tile N as a Workspace"); Pin, Favourite, Open Beside, Close on a row's menu; the address field (⌘T) making a web card; ⌘W on the card in front.
- Polished 2026-11-04 against renders of a real window: Arc's row and favourite styles (the card in front a raised chip), a rule between pinned and Today, workspace rows led by their tiles' icons, the space's colour and name at the foot, the window washed in the space's colour.
- No header in a space's window (`CanvasPaneController.hidesHeader`): no title pill, tab bar or trailing controls. Tiles have the usual 6pt gap on every side, sidebar or not.
- Dead space, as Arc: in a layout (a space's or, since 2026-11-05, a project's, and the one card filling the window in focus mode), a press in the top 96pt of a tile's page (`CanvasPageView.deadSpaceBand`; 56pt missed Apple Music's header) on nothing usable moves the window; double-click is the title bar's action. Nothing usable = WebKit's cursor is the plain arrow (not a hand or an I-beam) and its last hover report was no link, image, media or editable field (`isDeadSpace`, `hoverIsInteractive` from `mouseDidMoveOverElement`). And the page itself says nothing there is its own (`CanvasPageView.pageUses`, asked on each WebKit hover report — `mouseMoved` and the view's own tracking areas never hear the moves; a press before the answer for the latest report is the page's; "page kept a press in the band" logs one): not inside a button, form control, ARIA widget role, `tabindex` ≥ 0, `draggable`, `contenteditable` or `onclick`; not on a `canvas`, `iframe`, `embed` or `object`; not inside a dialog, or a fixed/absolute box inset from the viewport's left, right and top (a floating panel). Figma's toolbar buttons keep the arrow cursor and its Variables panel has a blank header, 2026-11-05. A video's picture (2026-11-05, `CanvasPageView.Press.video`) is held rather than taken: a visible `<video>` at least 200×100, above the 96pt strip along its foot (player controls), not under a control; an ancestor that only holds the video (a player's `tabindex=0` wrapper) or a layer covering the whole picture is not a control. Anywhere on it, not only in the top band. The press is not passed to the page: moved 4pt (`videoDragSlop`) it moves the window; released first, the page gets the mouse-down and mouse-up together (a click pauses, a double-click goes full screen). A hover over media no longer counts as `hoverIsInteractive` (`hoverIsMedia`; it still blocks the top band). Logs "window drag from a video: <host>". Whether a page is a space's tile is asked of the board it's in at the press, not the card that built it: running pages are handed between panes. A drag from a page logs "window drag from page dead space: <host>".
- The window's top 3–4pt is its resize edge, so the 6pt gutter above the tiles is mostly that; the page's dead space is the handle that matters.
- The sidebar's list fills its scroll area, so empty sidebar below the last row is drag area too. Each gutter or sidebar drag writes "window drag from …" to the log.
- Sidebar shortcut: ⌘S in a space (Arc's), and ⌃⌘S / View ▸ Show Sidebar. A space's sidebar is a plain pane, so the split's own toggle (which only moves a sidebar-behaviour item) is replaced there (`toggleSpaceSidebar`).
- With the sidebar folded, it floats back over the content (`SidebarPeek`, the same `SpaceFrame` model): while the pointer is at the window's left edge (6pt, `EdgeReveal`), going 0.35s after it leaves; and for ⌘T / ⌘L, with the address field taking the keys, going when Return or Esc ends it.
- With the sidebar folded the window's buttons are hidden; they fade in while the pointer is in the window's top-left corner (96×44pt, `CornerReveal`), over the page, as in Arc.
- Dragging, as Arc: the frame round the tiles (`WindowDragView` gutters, 6pt, and the top band) and the sidebar's empty space move the window; double-click follows System Settings' title-bar action. Pages never do: a click-through `WindowDragBlocker` carves the titlebar band over the tiles' tops only. The gutters are plain views, not `NSControl`s: in the band, a control carves the band's own drag and its press goes to the titlebar's views, so a gutter there moved nothing; now the band's own drag answers there, and the gutters answer below it. Dividers between tiles still resize them. A ground press on the board also drags, and ends the board's press first (a window drag swallows the mouse-up, which left the board "pressed").
- Beside the sidebar, the gutter at the tiles' leading edge is the sidebar's edge (`SidebarEdgeHandle`): a column-resize cursor, and dragging it resizes the sidebar within its min and max. With the sidebar folded it's window ground again. It replaces the divider: the split's divider in a space has no width and nothing to grab.
- Sidebar and content meet as one ground (2026-11-27): the split's `NSSplitDividerView` (kept by AppKit at 4pt across the seam even with no divider thickness; the window server drew a 1pt light line at its leading edge, 2pt into the sidebar) is hidden (`ProjectSplitView.hideDividerViews`); a tiling under the frame leaves the project's texture off (`CanvasScrollView.tilesHideTexture`), which showed only in the gutters, a tone step against the sidebar; the board keeps its texture. Beside tiles, the docked sidebar's rows have 4pt on their trailing side (10 leading), so with the 6pt gutter they sit as far from the tiles as from the window's edge; on the Board (no gutter) and in the floating sidebar, 10. The edge handle runs 3pt into the leading tile (`sidebarEdgeOverlap`), so the resize cursor is on the tiles' edge itself.
- A click on a tile in a layout clicks through to its content as well as focusing it — every board, not only spaces. It always meant to (`tileClicked` listens, never consumes), but stepping in raised the page's frame rate with one frame of "hidden", in the frame the press arrived, and WebKit dropped the press. The pulse now waits for the button to come up (`CanvasPageView.pulseWhenReleased`).
- The sidebar is a plain split pane in a space (no glass plate), painting the content's `CanvasColorWash` in the space's colour, so the two are one ground; the split's divider line is clear (`ProjectSplitView.hidesDivider`). The custom split view must be set up as the controller's own is (`arrangesAllSubviews = false`, vertical) or every window crashes at launch.
- The tile grip opens the tile's controls on every board's layouts, project or space (2026-11-05); Pin and Favourite under any frame, a space's or a project's; ✕ is Close, as ⌘W (§ Closing), and Out of the Layout on a board without a frame; search is Settings' engine everywhere. Was: in a space, (`CanvasTileControls`; mock `.claude/mocks/folio-tile-grip.html`): rest on the grip 0.3s, or click it; a click on the grip never closes it. A capsule unfolds from the middle of its top edge (SwiftUI scale and fade on a spring), 4pt under the grip; it ignores the titlebar safe area (a hosting view there pushed it 28pt down); the grip stays above it and still drags the tile. Back, Forward, Reload, the site (click: the address field in place, with suggestions; Return goes, Esc puts it back); Pin, Favourite, Maximize (with two or more tiles), Close (as ⌘W, so ⇧⌘T brings it back; was "Out of the Layout" off a space until 2026-11-27), More (the tile's right-click menu). A tile that isn't a web page has the second half. Closes 0.45s after the pointer leaves grip and capsule (not while editing), when the tile leaves the layout, and on a window resize.
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
  - Nor does anything else, 2026-11-27: a press carried past a tile's edge (`CanvasClipView.autoscroll(with:)`), a two-finger double-tap on the ground (`CanvasScrollView.smartMagnify`), and, as a net under every other way in (a view in a tile asking to be scrolled into view, the board's frame pulling the clip), any same-size move of the visible region that the scroll view didn't make is put back before anything is built for it (`putBackStrayMove`, `CanvasTiling.strayMove`). Each put-back logs "tiled board held still" with the call stack that moved it.
  - A web row carries its address: another app, or another board, takes it as a link.
  - Onto a space's dock mark (lit while over it): the card moves to that space as Today, unpinned, off the board it came from, a space's or a project's (`CanvasSatelliteDock.rowDrop`, `Spaces.move(_:fromCanvas:to:)`). Onto a project's mark: a space's web card goes onto that project's board, as the flyout's Send ▸ Card. Its own board's mark refuses it.
- Files from Finder (or any app) dropped on the sidebar, a space's or a project's (2026-11-06; `SpaceFrame.landFiles`, `SpaceRowDropTarget`): a file card each (a folder card for a folder), in drop order, the last one shown. Same line marks as a row: between rows, into Pinned / Today / Cards, onto a folder (first in it), onto the favourites. Onto a workspace row: the cards join that workspace. Between workspace rows: refused. Anywhere else (Notes, Board, the empty sidebar): the end of Today / Cards. Outside the vault asks Copy In / Point At It, as a drop on the board. One undo step; a copied-in file stays on undo.
- Dragging a workspace row among the workspace rows reorders them (2026-11-05). The order is kept per board in defaults (`PMCanvasWorkspaceOrder`, `CanvasWorkspaces.ordered`); unordered ones follow alphabetically; a rename keeps its place. Menus stay alphabetical. The row carries a tab chip's type (`ProjectTabDrag`), which nothing else takes.
- Double-click a workspace row (or its menu's Rename Layout…) to rename it in place (2026-11-05). Return or clicking away keeps it, Esc abandons; same rename as the tab chip (`ProjectSplitViewController.renameWorkspace(named:to:)`): chips follow, a taken name asks first, one ⌘Z. No drag while editing.
- The frame for projects, decided 2026-11-05 in `.claude/mocks/folio-project-frame.html`; built the same day (`SpaceFrame` with `project`, `ProjectSplitViewController.syncFrame`). Off with `defaults write <bundle> PMProjectFrameOff -bool YES`. A window on a file that's neither a space nor a project's board has no frame. Spaces and projects behave alike unless there's a reason (one sidebar, one rule per key).
  - Other projects: the project's name at the sidebar's top opens a popover: filter chips, then the project list (`ProjectSidebar`, Up Next first). Picking one switches the window. File ▸ All Projects… opens the same popover. Was planned: a window of its own for All Projects….
  - Up Next leads the project list wherever it's shown.
  - Filters (Active / Archived / All, by due / by domain): chips over the list.
  - Favourites: as a space's, icon tiles under the name.
  - Cards not pinned: a Cards section, every unpinned card on the board, frames as folders. No auto-archive, no Today, no Clear; a closed card goes to Archived Cards (§ Closing).
  - Notes: the first row of the list.
  - The foot: the focused task (tick to complete) and the session's time, in place of a space's name.
  - Everything keyed to a space's frame applies to a project's too: no header or tab row (so no title pill, board capsule, Away or browser chips), ⌘T / ⌘L the sidebar's address, ⌘1…⌘9 and ⌃⇥ the sidebar's cards, ⌘W the card in front (in Notes: back to the board), ⇧⌘C the page's address, ⌘S the sidebar, Pin and Favourite in the tile capsule.
  - ⌘-click and new-window links in a project: a new card, shown in the tile you're in, as a space's.
  - The notes card is the Notes row, not a card row; its Notes workspace isn't a workspace row.
  - No List lens under the frame (its rows were the sidebar's again): Board is Freeform or Grid; a board remembered as List opens as Freeform, and View ▸ Show Canvas As ▸ List is dimmed. Windows without the frame keep it.
- A new card from the address field or a link (`openNewCard`) goes onto the board and into the tile you're in; it no longer joins the named workspace up as well (2026-11-05: ⌘T in a space's named workspace grew the workspace).

- An Arc-style sidebar over a board's workspaces. The sidebar lists what's on the board; the main area is the workspace tiling.
- For spaces and projects alike. A project's sidebar has Notes as a row. Replaces the window's tab row; supersedes "projects keep their window" above.
- Sidebar, top to bottom: the address; the filter field; favourites as icons; Pinned; Today (spaces only), with New Tab.
- The board is not a row (2026-11-28). Go ▸ Canvas (⌥⌘C) shows it, in a space's window as in a project's; on it, a Board row is listed (lit, with the card count) to say where you are, and goes when you leave. Was: a Board row, always, under the address. The sidebar is the way in: the free canvas is kept, as one way to look at the same cards, not the place you go to find them.
- A row is a card: web, folder, file, note, view. Frames on the board are folders in the sidebar.
- Named workspaces are rows among Pinned, led by a drawing of the layout: its columns and tiles, a web card's tile in its site's hue (`LayoutShapeGlyph`).
- Pinned and favourite are marks on the card, stored on the node (`pm*` keys), so the board stays the one record. The rest of a space's cards are Today; they stay until closed.
- Clicking a card that isn't showing, and that no layout holds, replaces the tile you're in, as Arc. In a named workspace of several tiles, that leaves the workspace for the card on its own.
- Clicking a card that a layout holds (the one on screen, or another named workspace) opens it alone, on the board's own tab; the layouts are left as they were (2026-11-05, `SpaceFrame.openAlone`; was: jumped to the workspace with the card's tile picked).
- A card's menu has "Show in “<layout>”" for each layout holding it, in the sidebar's order: that workspace's tab with the card's tile forward (`showInLayout`). Jumps from search, the ⌥Tab switcher, ⌘1…9 and ⌃⇥ still go to the layout (`show`).
- ⌥-click: a tile beside the one you're in. Dragging a row onto the tiles: beside, as a tab, or in place, where it's let go.
- ⌘-click rows, then ⌘↩: tile them as a new workspace (a new Pinned row).
- Picking (2026-11-07, `SpaceFrame.click`): ⌘-click picks or unpicks a row; ⇧-click picks the run of visible rows from the last row clicked (else the card in front). The first pick takes the card in front along, as Arc's. Picked rows: accent fill and outline; a bar over the foot, "New Layout from N" (⌘↩) and ✕. Esc lets go (not while a field has the keys; `SidebarEventCatcher`). A plain click lets go.
- A picked row's menu acts on every picked row, each item counting: Pin / Unpin N Cards, Add N to / Remove N from Favourites, New Layout from N Cards, Copy N Addresses, Move N to Space ▸, Close N Cards (one ⌘Z).
- Dragging a picked row carries every picked row (`SpaceRowDrag.companions`): along the lists in sidebar order (`SpaceCardMarks.move(_ ids:…)`), into a folder or layout row, onto the tiles (the rest join its tile as tabs, `landRow(_:_:with:)`), or onto a space's dock mark.
- Double-click a card's row (or its menu's Rename…) to name it in place: `pmTitle` on the node, which beats the page's name everywhere a card is named (`describeCard`). "Use the Page’s Name" clears it.
- A row's tooltip: its whole title and, for a web card, its saved address.
- Rows follow System Settings ▸ Appearance ▸ Sidebar icon size (`SidebarMetrics`: 28 / 32 / 38pt rows, 12 / 13 / 15pt text).
- A row's trailing controls (layout mark, count, folder +, folder chevron, speaker, ✕) keep fixed slots: hovering never re-truncates the title. A pinned card under a layout shows its pin in the ✕'s slot until hovered.
- The icon column (`SpaceSidebarGlyphs.swift`, polished 2026-11-27): every icon in one box (`SidebarMetrics.glyph`) at one x, so every title starts on one edge; a folder's chevron is at its end for the same reason. A card with no favicon wears its initial on its site's hue (`SidebarHue`, one of eight, stable across launches), its title's when it has no site. Favicons are fitted, not stretched, with a hairline edge, and fade in when they arrive. A folder's or the open layout's cards hang from a hairline under its icon; only the card in front is raised. Neighbouring rows lit the same way (picked, or on screen) join: square corners between them, the fill across the gap, one outline (`SpaceRowGround`), as a run of selected rows in Finder. The front card's chip never joins.
- The sidebar scrolls to the card in front when it changes (⌃⇥, ⌘9, a link); to its folder's row when the folder is folded.
- Rows are a container labelled Tabs (Cards in a project) for VoiceOver; each row says pinned / playing / on screen / expanded, and has a Close action.
- Favourite tiles: deeper fill when on screen but not in front; accent outline when picked; the speaker pauses; middle-click takes it off the screen. A drop on a tile is before or after by the tile's own middle (tiles are 44–80pt).
- Folders (2026-11-07): the add list's New Folder makes one named "New Folder", its name selected for typing; Finder folders are the add list's Finder Folder ▸. An empty folder shows in Today. Double-click a folder row (or Rename Folder…) names it. Its menu: Collapse / Expand, Rename Folder…, Delete Folder (its cards stay, loose). A folded folder shows its card count. Dragging a folder row reorders the folders of its list (the frame's `pmOrder`). Folded folders are kept per board in `PMSidebarClosedFolders`.
- The space's foot: every space as a mark (icon in its colour; the current one on a chip), click to go there; a sideways two-finger swipe over the sidebar goes to the next / previous space. Right-click: Space Settings…, Archived Cards…, Clear Today, Archive Today's Cards.
- The project frame's list popover carries the window sidebar's bottom bar (New Project, kind, Show / Group By / Sort By / Up Next).
- Tiles keep grid / master-and-stack, sizes, maximize, pop-out. A tile's strip shows only in a split.
- ⌘T: a new card in Today, shown in the tile you're in (File ▸ New Tab is enabled in a space though it has no project).
- ⌘W: the card in front closed, as § Closing. With no tile focused, the window closes. Unpin is only a pinned card's menu's first item.
- ⌘L: the sidebar's address field on the page in front, which Return sends there (the header's field is hidden in a space).
- ⌘1…⌘8: the sidebar's rows in order as you see them (favourites, layouts, pinned, today; a folded folder's cards skipped), ⌘9 the last; the menu items are titled after them. ⌃⇥ goes along the same rows.
- An unnamed tiling of several tiles offers Keep as Workspace.



- Projects, a divider, the Due section and a divider when it has any, then the spaces. Same squircle marks; a closed one's is dimmed. A space's window and pop-outs belong to its mark.
- Shown: a project or space with a window or windows out, or kept. Closed and not kept: off the dock (still in the Spaces menu, quick bar, sidebar).
- Keep in Dock (2026-11-07): on any project's or space's mark menu, checked when kept. A kept project's mark is dressed from what it was last seen as (`CanvasSatelliteDock.Pin`, `PMDockPinnedProjects`); kept spaces by id (`PMDockKeptSpaces`). Every space that existed before spaces could be kept starts kept. A new space starts not kept, as a new project.
- No flyout opens while the dock is dragged, or with the mouse button down.
- Due section (2026-11-07, `DockDue`): projects not otherwise in the dock with an open task due within Settings ▸ Windows ▸ Dock's window (Off, Today, By tomorrow, Within 2 days (default), Within a week; overdue always counts), earliest first; archived never. Dimmed; click opens the project. Leaves once nothing is due in the window.
- Due dot: red overdue, orange due today, on any project mark; the top corner toward the screen's middle (flips when the dock is on the right half). Not faded with a closed mark.
- A project's flyout lists up to 5 tasks due in the window, the date coloured by how soon.
- The focused project's mark has a ring in its colour. Built.
- The + (2026-11-06, `NewSpaceMark`): a + on a glass plate of its own, no outline, 4pt (the marks' spacing) under the dock (above it when the dock is at the screen's foot; switched once a drag is let go), centred; the dock's size never changes for it. In the dock's own window, so it moves with the dock (2026-11-07; was a panel of its own that followed a frame behind and juddered). Shown while the pointer is on the dock or the +, or a drag is over a mark or the +; fades in and out (0.12s), going 0.35s after the pointer is off both. Click: a new space. A sidebar row let go on it: a new space holding that card, moved off its board and shown. A web link (http/https) from any app: a new space on that page. Files and other schemes refused. Pressing and moving drags the dock, as any mark.
- Right-click on the + or the dock's glass: New Space, New Project….
- Not built: a grey bar beside the mark of the window in front, apart from focus.
- Playing sound: WebKit's own `_isPlayingAudio`, observed on the page (`CanvasPageView.isPlayingAudio`, posted as `audioChanged`) — on the page because pages move between panes. Shown as a speaker on the card's sidebar row (click: pause) and favourite tile, on the card and tile rows of the ⌥Tab switcher, a dot under the dock mark, and in the space's flyout.
- A space's dock flyout (`SpaceDockCard`): name, card count, Show Window; a Now Playing row with pause for each card making sound; the cards, pinned first, which open in the space; a web card's menu sends it to a recent project as a card (off the space), into its Links, or as a task.

### Filtering the sidebar

(2026-11-28; `SidebarFilter`, `SpaceFrame.refilter`.)

- A field under the address: Filter Cards in a project, Filter Tabs in a space. View ▸ Filter Sidebar (⌥⌘F) puts the keyboard in it, unfolding a folded sidebar first.
- Typing narrows the list to the layouts and cards that match; favourites, Notes, the rules and New Tab go while it does. Every word must be found, in any order, case and accents aside.
- A card matches on its name, its site, its address and its folder's label (so a folder's name finds what's in it), and on what it says, as the board's search finds it (`CanvasSearch`): a document card's text, a web card's remembered page name. A card only a layout shows is listed too.
- A layout matches on its name, or when it shows a card that matches.
- The list: the layouts, then loose cards, then each folder's under its label, in the sidebar's order. "No Matches" when nothing does.
- ↑ ↓ move a highlight (a ring, drawn while the field has the keyboard); Return opens it and clears the field; Esc or the field's ✕ clears it. A click opens a result as a click on its row would and keeps the filter, for looking through several. Right-click is the row's menu.
- Not kept: the filter starts empty in every window and at launch. Rows can't be dragged while it's up.

## Browsing

Built 2026-11-05.

- A link that asks for a new window (`target=_blank`, not a sized pop-up) in a space: a new card in Today, in front (`CanvasBoardView.opensNewTab`). On a project's board, what ⌘-click makes there (2026-11-05; was: it navigated the card).
- ⌘-click in a space: a new card in Today, in front; ⇧⌘-click leaves it in the sidebar.
- ⌃⇥ / ⌃⇧⇥ and ⇧⌘] / ⇧⌘[ in a space: the next / previous card in the sidebar's order, wrapping.
- The sidebar's address field is the header's (`CanvasAddressTextField`): suggestions, filled-in addresses, ↑↓, Tab, two-step Esc. Searches go to Settings' engine; with None, only addresses (2026-11-05; was DuckDuckGo over None).
- The sidebar's address field shows the focused tile's page as it is now (host and path, not the card's saved address), following focus between tiles and the page's navigation.
- Suggestions (header and sidebar): the board's web cards, the card's back list, history (most visited, then newest), pages with a remembered name.
- History: `~/.config/pm/history.json`, one row per address (title, last visit, count), newest 10,000 kept (`CanvasHistory`). Recorded on a card's finished load and on title changes (sites that move without loading). Not from a Private card; http and https only.
- History menu: Reopen Closed Card (⇧⌘T), Show All History (⌘Y), Archived Cards… (the front window's, a space's or a project's; off when the front window has no frame), the last 15 pages, Clear History… (all, or today).
- History window: search, pages by day, Open / Copy Address / Remove from History; double-click opens. Opening a page goes where links from other apps go.
- ⇧⌘T: the last card closed (§ Closing) or taken out of a layout, this run only, 50 kept. Still on the board (a pinned card, Keep, ⌘Z): shown again. Gone: put back as it was, any kind of card, with its lines, and out of Archived Cards; a web card at the page it had got to. A board without a frame: a new card on the address. A project's closed window is opened first (`Closed.projectKey`, `whenFramed`).
- File ▸ Print… (⌘P) and Export as PDF…: the page you're in, else the focused tile's, else the one selected web card. Paged to the paper's width.
- Clear: on the rule above Today while the pointer is in the sidebar; every Today card off the board (⌘Z brings them back). Pinned and favourites stay.
- Archive (the rule's or the space name's menu, per space, `Space.archiveAfter`): Never, 12 hours, a day, a week, 30 days. A Today card not on screen (and not playing) for that long goes, checked at most once a minute. When a card was last on screen: `PMSpaceCardSeen`, by space and card; a card first seen counts from then.
- Archived cards (2026-11-07, `SpaceArchive`): every Today card that leaves the board by Archive or Clear, and every card closed off a space's or project's board (2026-11-13), is kept, reason with it. Survives relaunch.
  - Kept per board: a space by its id, a project by `canvas:` and its board's path (`SpaceArchive.key`).
  - `~/.config/pm/spaces/archive.json`, every space's together. The whole card (its node as the board's file has it), title, address and host for a web card, when, reason (auto / cleared / closed). Written on its own queue, in order.
  - Newest 500 per space; older than 90 days dropped.
  - Archived Cards window (`SpaceArchive.present(spaceID:)`): one per space, brought forward if open. Search (title, address), by day newest first; favicon or the card's symbol, title, reason · address, time. Restore (↩, double-click, or the menu), Copy Address, Remove from Archive; Clear Archive… (asks). Empty: No archived cards.
  - Restore: the card back as it was, unpinned, at the top of Today, right of everything on the board; one undo step (Restore Card) on that board; the entry goes. Shown when the board's window is open. A card still on the board (⌘Z) is left as it is.
- Downloads: Window ▸ Downloads (⌥⌘L) and an arrow at the sidebar's foot (a ring while one runs, a dot when one has finished). Progress while running; click opens, the magnifier shows in Finder, a row drags out as the file. Newest 30 kept (`PMRecentDownloads`). Clear forgets finished rows; files stay.
- A row's menu: Copy Address, Duplicate (the page it's at, with its back list), Mute / Unmute (the card's own Mute), Move to Space ▸ (off this board, a space's or a project's, onto the space's as Today, unpinned; out of its layouts first), or drag the row onto the space's dock mark.
- ⇧-click a link, in a space or (since 2026-11-05) a project: a preview over the window, Arc's Peek (`CanvasLinkPreview`). Same sign-ins, blocking and scripts as the card. Open as Card (⌘↩) makes it a Today card in front; Esc, ✕ or a click outside drops it. Links inside stay in the preview.
- The hovered link's status says what ⌘ (a new tab under a frame, a space's or a project's; a new card on a board without one) and ⇧ (a preview) do.
- Mini player at the sidebar's foot: a card making sound that isn't on screen, or one it paused until that card is shown. Click goes to the card; play/pause; picture in picture (the page's largest video); ✕ pauses and hides it.
- Page menu: Show Reader (⇧⌘R) — the page's article (`<article>`, `<main>`, or the block with the most paragraph text) over the page in plain type; again, Esc or Close Reader takes it away (`CanvasReader`). Mute Page. More Page Commands ▸ Copy Address.
- ⇧⌘C under a frame, a space's or a project's: the page's address on the pasteboard, as Arc's. Windows without a frame keep Canvas in New Window.

## Closing

Decided 2026-11-13: a tile is a tab. Spaces and projects alike (`SpaceFrame.close`, `SpaceClosing`).

- Close: ⌘W, a row's ✕ or Close, middle-click, the grip's ✕, a tab's ✕, a tab strip's Close Tab and Close Other Tabs, a picked row's Close N Cards.
- A pinned card or favourite: off the screen, stopped, still pinned (Arc's; `closePinned`). Its ✕ shows only while it's on screen.
- A project's notes card: as a pinned card. ⌘W in Notes goes to the board.
- Any other card: off the board, a space's or a project's. Into Archived Cards (reason Closed) and ⇧⌘T. One ⌘Z puts the card and the layout back.
- Never asks and never trashes a file: a document card's file stays in the project's docs. The board's Delete still asks.
- What comes forward, as a browser closing a tab (`SpaceClosing.plan`):
  - a tab in a tile of several: the tab of that tile in front most lately;
  - a tile among others: the tile goes and the layout closes up, as Arc's split;
  - the only tile of an unnamed tiling: the card in front before it, into its slot; a named layout's slot is never filled from outside it (§ Cards in layouts);
  - nothing remembered: the neighbouring tab or tile, else the board.
- Toast at the window's foot after an unpinned close (`CanvasToast`): Closed “<name>” (or Closed N Cards), Undo, Keep in Space / Keep in Project.
  - Undo: the cards back as they were, and the layout if nothing has changed it since (else the first card shown). Out of Archived Cards and ⇧⌘T.
  - Keep: the cards back in the sidebar where they were, not on the screen. Out of Archived Cards and ⇧⌘T.
  - Stays while the pointer is on it; goes 5s after it leaves, on a button, or when another toast or HUD line comes. Fades in and out.
- Close Tile, Close Tab and Close Tile and Its Tabs (a tile's, tab's and strip's menus; Canvas ▸ Layout ▸ Close Tile): out of the layout only, the card stays on the board. Were Remove from Layout and Remove Tile from Layout until 2026-11-27 (see concepts.md § Menu words).
- Windows without a frame (a file that's neither, `PMProjectFrameOff`): ✕ and ⌘W only take the tile out of the layout, as before.

## Cards in layouts

Decided 2026-11-13 in `.claude/mocks/folio-layout-cards.html`; built the same day (`SpaceLayoutCards`, `SpaceFrame.autoPin`, `removeFromLayout`). Spaces and projects alike.

- An unpinned card lives in one place: Today / Cards, or one layout.
- A layout's own cards are rows under the layout's row, and nowhere else. Arc's split.
- A card used in a second layout is pinned. A pinned card can be in any number of layouts.
- Under each layout using it, a pinned card is a row with a pin mark at its end. Its own row is in Pinned.
- A pinned card's row in Pinned: a layout mark with a count (no count for one). Click: that layout, the card in front; with two or more, a menu of them.
- Layouts are pinned: rows at the head of Pinned, always.
- Only the layout on screen is unfolded. A folded layout row shows its drawing.
- Which layout is up is the board's once it has tiled, and its tab's until then, so the sidebar never shows the in-between (Board lit, every layout folded) while a layout's tab is being built. Its cards unfold with a 0.2 s fade, dropping 4 pt from under its row; folding is instant, and its row's chip lights at once.
- Click a row under a layout: that layout, that tile in front. Click a row in Pinned or Today: the card alone (`openAlone`).
- Add to Layout (a row's menu, or a drag onto a layout row or its tiles): an unpinned card moves under that layout, out of Today / Cards. One already in a layout is pinned, and a toast says so: Pinned “<name>”: it’s in 2 layouts, with Undo.
- Move to Today / Cards (a row's menu, or dragging it out): out of the layout.
- Close a layout's own card: as § Closing; Keep puts it back under its layout. Close a pinned card under a layout: Remove from “<layout>”, it leaves that layout only.
- A layout whose last card goes goes too (`dropEmptiedWorkspace`, no question); ⌘Z brings it back, and so do the close toast's Undo and Keep. Closing the last card of the layout on screen shows the card in front before it, alone.
- Unpin a card two or more layouts use: dimmed, “Unpin (used in Dashboard, Reading)”. Used by one: it then lives under that layout. By none: Today / Cards.
- A project's notes card: as a pinned card, never under a layout as its own. The Notes layout isn't a layout row.
- The layout on screen is read as its board has it; the others as saved. A card in front in the layout on screen is the front row under it; its Pinned row is only on screen.
- Cards under a layout aren't in ⌘1…9, ⌃⇥ or ⇧-click runs: the layout's row is. They never auto-archive.
- The auto-pin's Undo: the card out of the layouts it had just joined, and unpinned. The first look at a board after launch pins shared cards quietly.
- Existing boards, once: a card in two or more layouts is pinned; an unpinned card in one layout leaves Today / Cards for it.

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

## Spaces menu

Built 2026-11-06 (`SpacesMenu`, in MainMenu.swift), between Go and History.

- New Space (no key: ⌃⌥N is Write Session Note, ⌃⌘N New Project).
- Next Space ⌃⌥], Previous Space ⌃⌥[: the list's order, wrapping. From a window that isn't a space: the first / the last (`SpaceOrder.step`).
- Overview first (no key; ⌥Tab then Space), then New Space.
- Every space, open or closed, with its colour; a check on the space in front. The first nine on ⌃⌥1…⌃⌥9 (⌃1…9 are Go ▸ Frame, ⌃⌘1…6 a note's headings, ⌃←/⌃→ the system's). Past nine: listed, no key.
- Going to a space opens it if closed and brings its window forward.
- Rename “…”… and Delete “…”…: the space in front; dimmed when the front window isn't a space.

## Quick bar

Built 2026-11-06.

- `>`: New Space. `>space <name>` makes it named.
- `>` with New Project, New Space, Settings or Take Notes for This Meeting selected: no session preview under the rows, and no project name in the hint (`PMCommand.actsOnFocusedProject`).
- `@`: spaces after the projects. Empty field: recent projects, then spaces, 7 rows in all. Typed: projects that match, then spaces whose name starts with it, then spaces with a word that does (`SpaceOrder.matching`).
- `@` with nothing matching: New Project… and New Space “<typed>”.
- A project row with a page carried in from a browser (2026-11-13): under the project's frame, the card on that address or a new one in Cards, shown in the tile you're in; without a frame, into a workspace as before.
- A space row: goes to it. With a page carried in from a browser: the page goes into that space as a link from another app does.
- Not while the bar picks a project for something (Services ▸ Send to Project): no spaces, no New Space.

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
- New Space (2026-11-06): the last card, after the spaces; choosing it makes a space. Not shown with nothing else to switch between. Doesn't count for the first press: with one window, ⌥Tab lands on that window.
- Space: the overview, on the card picked, the cards growing into its tiles (2026-11-06). Not ↑: that moves through a card's list.

## Overview

Built 2026-11-06 (`OverviewController`, `OverviewModel`, `WindowSnapshot`); designed in `.claude/mocks/folio-overview.html`.

- Opened by Space in the switcher, Spaces ▸ Overview, Window ▸ Overview, or `>overview` in the quick bar (also found as mission control, exposé, all windows). No key of its own (⌃↑ is macOS Mission Control).
- One grid in the dock's order: projects, a divider, the dock's spaces, then +. As Mission Control: the fewest columns that fit, so the largest tiles; centred top to bottom.
- A tile: the place's own window large; its windows out at half its scale, in a column beside it on the side each is on screen, top to bottom as on screen, never overlapping (a column taller than the window shrinks to its height). Name and mark under them; Focused, Closed or Playing after the name.
- Each window picture: a one-pixel mid-grey hairline at 30% (the front window's white at 45%), so light windows show on a light desktop and dark on dark.
- Pictures taken in the app: `cacheDisplay` for the views, WebKit's `takeSnapshot` laid over each page showing. The front window's at once; the rest as last seen, then fresh, one a turn. No Screen Recording permission.
- A closed space: dimmed, desaturated, in its place; the picture it was closed on, or its colour and mark. Kept for the session only.
- Behind it: the desktop, dimmed and blurred. The dock stays above it.
- From the switcher: each card grows into its tile. From a menu: the front window zooms into its tile. Reduce Motion: a fade.
- One selection, as the switcher: the pointer over a tile selects it; arrows and Tab clear the pointer's marks until it moves.
- The selection is the plate: a faint panel behind the tile's windows (white at 14%), on the selected tile only. A window under the pointer, in a tile with windows out, is ringed in the accent colour. No lift on hover. Chosen in the round 3 mock.
- The + : a plain plate, no border.
- Click a window: only that window comes forward, key. Click the plate or the name, Return, or a dock mark: every window of the place, its own as the dock shows it, its windows out over it.
- Going: the windows going zoom out of the tile into place and come forward once they land. A dock mark clicked: the same.
- Pictures of the other windows wait until the entrance is over.
- + (or Return on it): a new space, gone to.
- Drag a tile among its kind: a drop mark, the move on drop; the dock follows. Spaces in `spaces.json`; projects in `PMDockProjectOrder`, remembered when closed.
- Tab / ⇧Tab, arrows: the selection. Typing finds places (`SpaceOrder.matching`), hiding the +; Delete edits; Esc clears, then leaves.
- Letting go of ⌥ does nothing.
- Esc or a click off the tiles: back to the front window.
- Not built: pictures kept across launches; moving cards between places.

## Command bar

Not built.

- The quick bar, grown: one bar, one shortcut.
- Typing with no prefix finds: projects, workspaces, tiles, spaces, tabs in every space, tasks, commands.
- Capture is the last row: add what was typed to the focused project; with nothing focused, it asks which.
- Prefixes stay: `@` projects, `/` tasks, `>` commands.
- ⌘T in a space opens the same bar scoped to it, with "Open in <space>" first.
- Commands include Unfocus, New Space…, Show Switcher.
- Already in the quick bar (2026-11-06): New Space, spaces in `@`.
