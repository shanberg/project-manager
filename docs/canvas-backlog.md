# Canvas backlog

Raised 2026-09-06. One entry per item: what it is, where it lives, and — where there is one — the
question that has to be answered before it can be built. Deliberately short. An item that turns out to
need a real design argument graduates to [open-items.md](open-items.md) or a page of its own.

Priorities are at the bottom.

## Fixes

### 1. Don't autoscroll while resizing — **done 2026-09-06**

A drag near the window's edge pans the board so you can drag further across it. A *resize* gets the
same treatment, so grabbing an edge and pulling drags the whole board along under the card, which is
never what a resize means — the card's other edge is the fixed thing you are sizing against.

`mouseDragged` called `autoscroll(with:)` for every gesture. It now asks the gesture —
`Gesture.pansTheBoard` — and a resize says no. The marquee and a dragged connection keep it: both are
going somewhere, and reaching past the edge of the window is how you get there.

### 2. ⇧ and ⌥ while resizing — **parked 2026-09-06**

The design-tool grammar: **⇧ keeps the aspect ratio, ⌥ resizes about the centre**, and together, both.
Neither exists today — a resize is the dragged grip and nothing else
([CanvasSnapping.resize](../pm-mac/PM/Canvas/CanvasSnapping.swift:94)).

**Parked on the collision, which is real:** ⌥ already means *no snapping*, on both a move and a resize
([CanvasBoardView+Input.swift:341](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:341)), and that is
the standard Mac override — it is the reason snapping can be on by default. Giving ⌥ to "from centre"
needs somewhere else for the escape hatch (⌘ is the other candidate, and is currently an
extend-selection modifier on mouse-down). Not worth trading one muscle memory for another without
deciding it deliberately, so this waits.

### 3. ⇧ and ⌥ for the marquee — **done 2026-09-06**

The rectangle you sweep over empty board. ⇧ was already spoken for — it is what makes a sweep add to
what is selected ([CanvasBoardView+Input.swift:26](../pm-mac/PM/Canvas/CanvasBoardView+Input.swift:26))
— so the new one is **⌥, which sweeps from the centre**: the press is the middle of the rectangle
rather than a corner, which is what you want when every corner you could start from is inside another
card. Free of ⌥'s other meaning, since a sweep has nothing to snap to.

### 4. Say *what* the alignment indicator is claiming — **done 2026-09-06**

A guide said "these agree" without saying what they agree about, and said the size half of it in a
different visual language: a hairline bar with a tick at each end, ruled beside each card — a
measurement drawing on a board that otherwise speaks in soft rounded bands.

**One mark now, and how much of it is drawn is the claim.** The band is the loop that already stood
off an aligned card; the other cases are that same loop with parts left out, at the same standoff,
the same 5pt breadth, the same neutral tone and the same fade. They are drawn by clipping the one
path rather than by building shapes of their own, so they cannot drift apart:

- **closed loop** — they line up, or (round exactly two cards) they are the same size in *both*
  dimensions and so the same shape. The strongest mark for the two strongest claims, and in the
  congruent case the two loops are congruent, which is the proof.
- **two runs**, top and bottom or left and right — the same width, or the same height. What survives
  is the pair of runs that span the dimension being claimed.
- **four corners** — the 10pt lattice, which used to draw nothing at all, so a card clicking to a
  grid nobody had mentioned read as a card refusing to go where you put it. Emitted only when there
  is no other guide, because the grid is the fallback and not the rule.

`CanvasGuide.sameSize` now carries `axes: [Axis]` rather than one axis, because "the same width *and*
the same height" is one claim rather than two — and a dimension that was already right counts towards
it, so a corner drag reaches the congruence case. The resize guides are also built from the settled
frame instead of axis by axis, which fixes a width guide being drawn around a rectangle carrying the
card's pre-resize height.

### 5. Pan freely, with or without overflow — **done 2026-09-06**

The board is the document's bounds plus a 1600pt margin
([CanvasBoardView.swift:60](../pm-mac/PM/Canvas/CanvasBoardView.swift:60)), and a scroll view will not
scroll a document smaller than its clip view. So a board with three cards on it is nailed in place:
you can zoom, but you cannot push the cards aside to have room to think. Panning should always be
available in both axes.

`CanvasClipView` now overrides `constrainBoundsRect` and constrains only the *losing* of the board:
you can pan until 120pt of it is left in the window, in any direction, whether or not it overflows.

### 6. Don't flash the notes view when switching to a project that opens on its board — **done 2026-09-06**

A window remembers which tab a project was last read in. When that is a board, the switch shows the
**notes** first and the board a moment later, because the canvas path is learned asynchronously and
the wait is spent on the notes tab
([ProjectWindowController.swift:215](../pm-mac/PM/Windows/ProjectWindowController.swift:215)).

Waiting was right; waiting *on the notes* was what made it a flash. The store can now tell "nobody has
looked" from "there isn't one" (`PMStore.hasResolvedCanvasPath`), so the tabs come up correct and the
board tab holds an empty pane for the moment it takes — and a project that turns out to have no canvas
gets the empty state that offers to make one, rather than the task list.

## Features

### 7. Mute, and don't autoplay, on a web card — **done 2026-09-06**

A board of YouTube embeds all start playing at once the moment the zoom brings them inside the page
budget ([CanvasPageBudget](../pm-mac/PM/Canvas/CanvasPageBudget.swift)) — a dozen soundtracks from a
gesture that meant "look closer".

`WKWebViewConfiguration` is built per card at
[CanvasLinkNodeView.swift:393](../pm-mac/PM/Canvas/CanvasLinkNodeView.swift:393) and sets no media
policy, so the platform default (play on load) applies.

`CanvasCardMedia` now holds both, saved on the node beside `pmSession`:

- **Autoplay is off for every card** unless the card says otherwise
  (`mediaTypesRequiringUserActionForPlayback = .all`), and "Autoplay Media" on the card's menu is the
  opt-in for the stream or the dashboard you do want running.
- **Mute** is a user script — WebKit has no public switch — injected at document start in every frame,
  which is what an embed needs, since a YouTube card is a page containing a player.
- **Neither one restarts the card**, because you reach for these while something is playing. The mute
  script is injected into every card whether or not it is muted, so it is a switch that can be thrown
  later: the app throws it in the main frame, and each frame relays the message down to its iframes,
  which is the only way to reach the cross-origin frame a YouTube card actually is. The user scripts
  are reinstalled at the same time so a link followed inside a muted card stays muted. Autoplay needs
  nothing live — it decides whether a page may start *by itself*, which is only asked as a page loads
  — so it applies the next time the card's page does, and nothing is taken away from you meanwhile.

### 8. A "New Project Note" card, when the board hasn't got one — **done 2026-09-06**

`createProjectCanvas` starts every project's board with one card: a file card pointing at
`docs/Notes - <Title>.md`. It is an ordinary card and deleting it is a keystroke — and there was no
way to get it back short of knowing the filename and hunting for it through New File….

Both add menus — the board's right-click and the header's `+` — now offer **New Project Note** as a
fifth item, and only when the board hasn't got it. Conditional was the whole point: a permanent item
would be an invitation to put a second copy of one document on one board. Offered this way it is not
really a fifth command, it is the board noticing something is missing in the place you would go to fix
it. No ellipsis, because unlike New File… there is nothing to ask.

[CanvasProjectNoteCard](../pm-mac/PM/Canvas/CanvasProjectNoteCard.swift) answers both halves, and the
two are deliberately asked at different rates. *Which* file is the project's is decided once and
remembered — the canvas doesn't move, so neither does its project — and tested by
`resolveNotesPath` finding a real `Notes - *.md` a step above the board, **not** by a `ProjectIndex`
lookup: the index is built after launch, and a board asked before it is ready would cache "no
project" forever. *Whether* the card is already there is re-asked on every document change, which
during a drag is every frame, so it compares the vault-relative path the card would be stored as
rather than calling the resolver, which touches the disk. The card it builds is the one
`createProjectCanvas` writes: same content, same 400×400.

### 9. Cards that are just an image

An image card letterboxes: `scaleProportionallyUpOrDown`
([CanvasFileNodeView.swift:145](../pm-mac/PM/Canvas/CanvasFileNodeView.swift:145)), so a board of
photographs is a board of grey margins in a dozen different proportions.

Sketch: when the card's aspect ratio is within some tolerance of the image's, fill instead of fit —
the crop is invisible at that tolerance and the board tidies itself. Beyond the tolerance, keep
fitting, because a deliberate wide crop of a tall picture is a decision.

Open: is the tolerance a preference, a per-card switch, or a constant nobody sees? Also whether a
resize should *offer* the image's own aspect ratio as a snap, which item 4 would then have to explain.

### 10. Swap the card in a tile

In a tiled view, a way to say "this slot, different card" — a control on the tile that raises a
picker of the cards on the board that are not currently up.

- Rows are `[thumbnail] [title / preview text]`.
- **The project note sorts first when it isn't already on screen**, since that is the card you most
  often meant.
- Existing pieces: `CanvasPageTitles` for names, and the summary/preview text in `CanvasSummary`.
  Thumbnails are the unknown — a web card's snapshot exists, a file card's does not.

Where it lives: the tile handlebar's neighbourhood, or the tile's contextual menu, which already has
promote and pin.

### 11. Tidy

FigJam's tidy-up: take a rough cluster and make it a clean grid, keeping the reading order and the
rows people already meant. Different from the tiling — a tiling is a temporary *way of looking*, this
edits the document.

`CanvasTiling.order` already answers the hard half: what reading order a scatter of cards is in, rows
banded by the median card height ([CanvasTiling.swift:120](../pm-mac/PM/Canvas/CanvasTiling.swift:120)).
Tidy is that order, laid back out on the board at a regular pitch, as one undoable change.

Open: whether it acts on the selection, on a frame, or on everything; whether card sizes are made
uniform or only their positions regularised (Figma keeps sizes — probably right); what the spacing is
and whether it is the 10pt grid.

### 12. Dropping files on the board — verify, then polish

Mostly built already: the board takes `.fileURL`, `.string`, `.URL` and image types, and a dropped
file becomes a file card at the drop point
([CanvasBoardView+Commands.swift:76](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:76)). So the
first job is to try it with a markdown file and find out what is actually missing. Suspected gaps:

- no visible feedback while dragging over the board — the drop lands with no indication of where,
- a file from outside the vault is stored as an absolute path
  ([CanvasBoardView+Commands.swift:159](../pm-mac/PM/Canvas/CanvasBoardView+Commands.swift:159)),
  which Obsidian cannot resolve. Copy it in, or say so,
- several files cascade by 30pt rather than laying out.

## Priority

**~~First — small, unambiguous, and each one is a thing that reads as broken: 1, 6, 5, 7.~~** Done
2026-09-06.

**Next:** ~~8 (project-note card)~~ done 2026-09-06. 12 — find out what dropping a markdown file
actually does today before designing anything. Item 2 is parked on the ⌥ collision; 3 is done without
it.

**Then — design first, then build:** 9 (image cards), 10 (the tile picker), 11 (tidy, the largest).
Item 4 was in this tier and came out of it early: the design turned out to be one mark drawn three
ways rather than three marks.
