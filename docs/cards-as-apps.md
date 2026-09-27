# Cards as apps, actions on the canvas

Early idea, 2026-09-25. Nothing here is built or decided, and it may not fit Folio at all. Kept so the
ideas aren't lost. Related: [web-cards.md](web-cards.md), [web-app-attention.md](web-app-attention.md) (listeners),
[canvas-workspaces.md](canvas-workspaces.md), [views.md](views.md).

## 1. The core idea: machinery on the canvas, dashboard in the workspace

- The canvas holds the machinery: sources, adapters, actions and the edges that wire them together, all
  visible and inspectable as cards.
- A workspace is a dashboard over that machinery: a selective, polished set of tiles showing only the
  outputs and controls worth looking at.
- The two stay one document: a workspace tile is a card on the board, so any dashboard tile can be
  traced back to the machinery that feeds it.
- Nothing is hidden state: the wiring is in the `.canvas` file and the code is in files.
- This follows what already exists: workspaces are selective arrangements of board cards
  ([canvas-workspaces.md](canvas-workspaces.md)); view cards already compute what they show and never
  write it to the file ([views.md](views.md)).

## 2. Terms

- **Card = app instance.** A web card already has an identity (saved address), a profile (`pmSession`),
  a lifecycle (live, frozen, snapshot) and a home. Pin works like installing.
- **Extension = adapter for a kind of page.** Matched by URL pattern. Declares:
  - readers: what the page is in Folio's terms (task, event, person, file, status);
  - actions: verbs that can be run on it;
  - signals: what's worth knowing without opening it (counts, state changes).
- **Action = a verb with many ways in.** Declared once, offered everywhere: quick bar `>` for the
  selected card, card chrome and menu, drop target, App Intent (Shortcuts, Siri), MCP tool.

## 3. Composing on the canvas

- **Edges are pipelines.** An edge from a source card to a destination sends the source's output
  there. Examples: feed card → Inbox frame; watched page → task (release its wait).
- **Dragging is calling a function.** Drop a task on a GitHub card to open an issue. Drop a file card on
  a Drive card to upload it. Drop a web card on a web card to link or share it.
- **Frames are scopes.** Actions available inside a frame can differ, for example a "Review" frame
  where every card gets Approve and Request Changes.
- **Intermediate cards are inspectable.** A filter or transform between two cards is a card too, and
  shows what it received and what it passed on.
- **Storage:** wiring lives as `pm*` keys on nodes and edges. The file stays valid JSON Canvas and
  Obsidian keeps what it doesn't know.

## 4. Layers, cheapest first

### 4a. Generic actions on every page (no site knowledge)

- Selection → task, session note or quote, with a link back to the page.
- Save the page to `resources/` (PDF, web archive or markdown), as a file card beside the web card.
- Downloads land in the project's `resources/`, not `~/Downloads`.
- Watch a page: snapshot it, diff within the page budget, badge the card when it changes.
- A page as a waiting target: `waiting: [[card]]` plus a condition ("text appears", "page changed",
  "value below X"). The task unblocks when the condition is met.
- Inputs: URL, title, selection, Open Graph, schema.org, RSS/Atom feeds, downloads.

### 4b. Site adapters (user scripts per URL pattern)

- A manifest plus JS. It lives in `~/.config/pm/extensions/` (global) or in a project folder (only that
  project).
- It reads the DOM, or calls the site's API through the card's logged-in profile.
- Examples:
  - GitHub PR: review-state badge; "make task: address review"; a wait on it releases on merge.
  - Linear/Jira issue: import as a task with `waiting: [[assignee]]`.
  - Figma: export a frame to `deliverables/`.
  - Gmail thread: task waiting on the sender, released on reply.
- Prefer site APIs and page metadata. DOM scraping is the fallback because it breaks.

### 4c. Real browser extensions

- `WKWebExtension` / `WKWebExtensionController` (macOS 15.4+) load standard browser extensions into a
  WKWebView.
- Per profile, this would bring in existing extensions: password managers, ad blockers, reader tools.
- Folio's own verbs would still come from 4b.

### 4d. Local apps as cards

- HTML in the project (`docs/apps/…`) or a localhost server, rendered as a card.
- A `folio` JS bridge: read tasks, add a task, write a session note, list cards, read the focused
  project.
- Built-in view cards (`day`, `waiting`, `time`) would become examples written against the same API.
- Permissions per card: which projects it can see, and whether it can read or write.

## 5. Agents

- An action declared by an adapter is a structured tool, which beats scraping and clicking for an
  agent.
- An agent on a project sees that project's cards' actions as MCP tools, scoped to the card's profile.
- Actions with side effects are marked `confirm: true`, and Folio asks before running them.

## 6. Constraints and risks

- Security: scripts run inside logged-in pages. Permissions are per project and per profile, and
  actions with side effects need confirmation.
- Brittleness: DOM adapters break when sites change. Generic metadata and APIs come first.
- The file is the contract: config goes in `pm*` keys, code in files, and nothing important lives only
  in UserDefaults.
- WKWebView has no passkeys (`isUserVerifyingPlatformAuthenticatorAvailable` is false), so some sign-ins always dead-end.
- Page budget: watchers and adapters compete with visible pages for the 8 live pages. Listeners are
  per account, not per card ([web-app-attention.md](web-app-attention.md) §1).
- Scope creep: each layer is plausible on its own, but together they could bury the markdown file
  at Folio's core.

## 7. Fit questions (open)

- Is the machinery/dashboard split a Folio idea, or a separate tool that Folio could host?
- Would people build wiring on a board, or only use wiring someone else built?
- Is 4a enough on its own to be worth building?
- Where does extension code live: global, per project, or both?
- Does an edge carry data (a pipeline) or only mean "related" (as Obsidian reads it)? The two could
  clash in a canvas shared with Obsidian.

## 8. Smallest test

- A generic action registry (4a verbs) in the quick bar and card menu.
- "Watch page → release waiting".
- Together these test the main claim, that a web card can take part in task flow, without committing
  to a scripting model or pipelines.
