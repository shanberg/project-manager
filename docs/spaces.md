# Spaces, focus, switcher, command bar

Design, 2026-11-04. Decided in the interactive mock (`.claude/mocks/folio-spaces.html`).
Related: [web-cards.md](web-cards.md), [concepts.md](concepts.md), [canvas-workspaces.md](canvas-workspaces.md).

## Spaces

Not built.

- A space is a browser window apart from projects: a name, an icon, a colour, its own sign-ins.
- Never the focused project. No notes, tasks, sessions or time tracking.
- No board: a space holds tabs, not cards on a canvas.
- One window per space.
- Sidebar, hidden by default; ⌘S or the window's left edge shows it:
  - the address, which opens the command bar scoped to the space;
  - favourites, as icons;
  - Pinned tabs;
  - Today: New Tab, then today's tabs. They stay until closed.
- Tab strips only on a split. A split is one sidebar row.
- Tab actions: split with the current tab, send to a project, close (unpin, for a pinned tab).
- Send to a project: as a card on its board (the tab leaves the space), into its `## Links`, or as a task linked to the page.
- Links from other apps: with a project window in front, onto its board, as today. Otherwise a Today tab in the front (or most recent) space.

## Dock

- Projects, a divider, then spaces. Same squircle marks.
- The focused project's mark has a ring in its colour. Built.
- Not built: a grey bar beside the mark of the window in front, apart from focus.
- A space playing audio: a dot under its mark.

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
- A space card: icon, name, tab count, its first tabs. Not built.
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
