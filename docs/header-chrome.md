# The canvas header: states and motion

**Status: built, 2026-09-10.** This is the one description of what the board's header looks like in
every state and how it gets from one to the next. Code comments explain *how* a piece does its part;
this says what the parts add up to. When the two disagree, fix whichever one is wrong — but decide it
here first.

Scope: the canvas header in a project window — the title pill, the tab bar, and the trailing chrome
(page capsule, tile capsule, control capsule). The session-note header is out of scope for now.

## 0. Why this exists

Every piece of the header was designed on its own, with a good reason written beside it, and the sum
stopped being designed. Counted on 2026-09-10:

- **One act, four clocks.** Going from the canvas to a workspace ran the glass fade (0.18s ease-out),
  the board's flight (0.3s, overshooting), the current-tab slide (0.2s snappy), and the tile capsule
  appearing in one frame.
- **Two vocabularies for arriving.** Anything that changed a capsule's width cut; anything that
  didn't, faded. That split came from a real bug (below, R3) and was never a design decision, so
  capsules popped in beside glass that eased.
- **A dead state.** `HeaderChrome` has dormant / resting / engaged. Once the backing became glass,
  resting and engaged draw identically, and the doc comment still says a background window has no
  glass, which it does.
- **A rule broken quietly.** The tab bar animates its own width when a chip is added.

**Revised the same day.** The first draft turned the glass off over a workspace. That makes the same
controls two different materials depending on what is under them, which reads as two different
controls. The glass now belongs to the controls and never changes; the job glass was being asked to do
on the canvas — keep the header distinct from a board that scrolls under it — belongs to the board's
edge instead (L1).

## 1. Decisions

| Question | Answer | Settled |
|---|---|---|
| Glass | On every control group, in every state, and it never changes — `.regular` | 2026-09-10 (revised) |
| What separates the header from the canvas | The board's own edge: a soft edge along its top — drawn by us, since the system's won't switch on here (P5) | 2026-09-10 |
| What says which things belong together | One glass capsule per group — the tabs (canvas and workspaces) are one group | 2026-09-10 |
| Where the edge is | Both views, always — it only shows when something passes under it (Q6) | 2026-09-10 |
| How capsules and fields arrive | Follow the macOS 27 HIG — see §2 | 2026-09-10 |
| Background (inactive) windows | Follow the HIG — see §2 | 2026-09-10 |
| The title pill's glass | None; a scroll edge effect keeps the name legible instead (Q1) | 2026-09-10 |
| How find opens | The field materializes in place at its final width (Q2) | 2026-09-10 |
| More than three groups | Live with it: three with a page up, four only with a focused web tile (Q3) | 2026-09-10 |
| The current-tab highlight | Rides the board's clock, 0.3s (Q5) | 2026-09-10 |
| Background windows, in practice | Keep what's there: content at 85%, the glass as the system draws it (P3) | 2026-09-10 |
| Hover | Ours: a soft capsule behind the control under the pointer. The system has none for custom glass (P2) | 2026-09-10 |
| A chip arriving in the tab bar | Snap + fade (B) — P4 found the bar's width snaps on the first frame, so there is no growth to show | 2026-09-10 |

## 2. What the HIG says, and what it does to us

Read 2026-09-10. HIG pages at `developer.apple.com/design/human-interface-guidelines/<page>`.

**Arriving and leaving is a glass transition, not a fade.** The HIG prescribes no motion for toolbar
items; the developer guidance for custom glass does ("Applying Liquid Glass to custom views",
`GlassEffectTransition`): shapes within a container's spacing use `matchedGeometry` (they morph out of
their neighbour); shapes farther apart use `materialize`, which fades the content and animates the
glass material in, without matching geometry. Apple asks for these two "across your apps" and says the
system "applies more than opacity changes" — so a plain opacity fade is the thing *not* to do.

→ Our capsules **materialize in place**. `matchedGeometry` would animate a capsule's shape and size,
which is exactly what R3 forbids; `materialize` doesn't touch geometry, so it is the HIG's own answer
that the rule already permits.

**Glass that belongs together lives in one container.** `GlassEffectContainer` groups shapes so they
render and transition together; glass cannot sample other glass, and nearby glass in separate
containers behaves inconsistently. Toolbar items that belong together share one piece of glass.

→ The trailing chrome (page, tile, controls) is one hosting view and becomes one container. The pill
and the tab bar are separate hosting views and cannot share it — acceptable, since they are far enough
apart never to touch.

**Hide the whole item, not what's in it.** Hiding only the view leaves an empty glass item.

→ Conditional capsules are removed whole. Never an empty capsule, never a capsule of hidden views.

**Titles avoid glass.** From the AppKit session: "Non-interactive items like custom titles… should
avoid the glass material." The legibility of floating text is the scroll edge effect's job, and on
macOS 27 the automatic style resolves to a hard edge when a free-floating title is present.

→ The pill loses its glass, in both views, and the board gets a **soft** scroll edge effect along its
top: what passes under the band blurs and fades before it reaches the controls. Set explicitly —
macOS 27's automatic style resolves to *hard* when a free-floating title is present, which the pill
is. Soft rather than hard because a hard edge is a line that is always there, while a soft one only
shows when something is under it, so it can be on in both views and never switch. See Q1 and Q6.

A side effect worth having: the pill is now identical in every state. It never changes padding,
position or backing, which is what the first complaint about this header was.

**At most three groups.** "Minimize the number of groups… aim for a maximum of three."

→ Canvas with a web card engaged: tabs, page, controls — three glass groups, plus the pill, which is
a title rather than a group. A web tile focused in a workspace adds the tile capsule: four. §7, Q3.

**Search sits at the trailing edge and expands when you use it.** macOS: "Put a search field at the
trailing side of the toolbar." WWDC26: search collapses into a button when space is short and "expands
to a width optimized for text input" when activated.

→ The magnifier-becomes-field design matches. The *expanding* is a width animation, which R3 forbids.
§7, Q2.

**Inactive windows are subdued, and custom chrome has to do that itself.** Windows: inactive windows
don't use materials and look "visually farther away"; "if you use custom implementations, you need to
do this work yourself." Designing for macOS: people expect "smooth transitions between active and
inactive states". The HIG does not say what Liquid Glass itself does in a non-key window.

→ §3, L1 and L3, and a prototype check (P3).

**Hover belongs to the system where it can.** Toolbars: "the system defines hover and selection state
appearances automatically." `.interactive()` gives custom glass the system's reactions; macOS 27 glass
"subtly bounces when clicked".

→ One hover response, per control. §3, L4.

**Reduce Motion means fades, not slides or morphs.** Replace x/y/z transitions with fades, tighten
springs, don't animate into or out of blurs; Liquid Glass's morphing is among what the setting removes.

→ R6.

## 3. The model

### Inputs

Everything the header responds to. Nothing else may change what it draws.

| Input | Values |
|---|---|
| View | canvas · workspace |
| Window | key · not key |
| Page | none · a web card is engaged (canvas: stepped in; workspace: its tile is focused) |
| Tile | none · one tile focused in a workspace of two or more |
| Find | closed · open |
| Mode | view · connect |
| Room | full (≥ 900) · tight · minimal (< 680) |
| Tabs | count, selection, one being renamed |
| Pointer | over a control · not |

### Layers

The header is four layers. Each has one job and one way of changing.

**L1 — Surface (the board's edge).** A soft scroll edge effect along the board's top, behind the whole
band: a card panned up under the header blurs and fades into it before it reaches the controls, so
the glass always sits on something calm. It is a property of the board, not of any control, and it
never changes — on the canvas it has cards to act on, over a workspace it has nothing (tiles start
below the band) and is effectively invisible. Nothing to animate, so nothing to time.

**Glass is not a layer that changes.** Every control group wears `.regular` glass in every state —
canvas or workspace, key or not (P3 decides what the system does to it in a background window). The
pill never does. So a control looks the same wherever you meet it, and glass means one thing: *these
controls belong together, and you can press them*.

**Grouping is one capsule per group.** The tabs — the canvas chip and every workspace — are one
capsule. The page, the tile and the board's controls are one capsule each. Between capsules,
`HeaderMetrics.capsuleGap` (10pt); inside one, `gap` (2pt). The trailing `GlassEffectContainer`'s
spacing stays below the capsule gap, so the three never blend into one blob at rest.

**L2 — Islands (which capsules exist).**

| Island | Present when | Glass |
|---|---|---|
| Pill | always | never — the edge behind it does the work (Q1) |
| Tab bar | more than one tab | always |
| Page capsule | Page ≠ none | always |
| Tile capsule | Tile ≠ none | always (it only exists in a workspace) |
| Control capsule | always | always |

Layout **snaps** to the new set in one frame. An arriving capsule **materializes** where it lands; a
leaving one materializes out. Glyphs and labels in it fade with the glass, per `materialize`.

**L3 — Contents (what's inside an island).** Changes that stay inside a box whose width doesn't change
may animate; everything else is instant.

| Change | Motion |
|---|---|
| Reload ↔ Stop, maximize ↔ restore | symbol replace |
| Current tab moves | backing slides between chips, 0.3s — the board's clock (Q5) |
| Chip added / removed | row snaps; the chip fades in or out where it stands (Q4) |
| Tab label being renamed | instant, one character at a time |
| Magnifier ↔ find field | magnifier leaves as a whole item; the field materializes at its final width; row snaps |
| "Connecting" label, Home / Pin | instant |
| Window key ↔ not key | labels and glyphs to the system's inactive treatment; smooth |

**L4 — Pointer.** One response: a soft capsule behind the control under the pointer, 0.12s
(`HeaderHoverHighlight`). No island-level hover state: `HeaderChrome.engaged` is gone. The system's
own hover was tried and isn't available to custom glass (P2).

## 4. Transitions

What each act does, layer by layer. "—" means that layer does nothing.

| Act | L1 surface | L2 islands | L3 contents |
|---|---|---|---|
| Canvas → workspace | — | tile capsule materializes if 2+ tiles (focus lands on the first) | backing slides to the chip |
| Workspace → canvas | — | tile capsule, and page capsule if up, materialize out | backing slides |
| Workspace → workspace | — | tile capsule in/out by tile count | backing slides |
| Step into a web card / focus a web tile | — | page capsule materializes | — |
| Step out / focus a non-web tile | — | page capsule materializes out | — |
| Focus a different tile | — | — | tile verbs update in place |
| Maximize / restore a tile | — | — | symbol replace |
| ⌘F | — | — | field materializes, magnifier goes |
| Esc in find | — | — | field materializes out, magnifier returns |
| Open / close a tab | — | tab bar appears or goes at 1↔2 tabs (materialize) | Q4 |
| Rename a tab | — | — | label becomes field in place, same face and width |
| Window becomes / resigns key | system | — | system inactive treatment |
| Resize across a Room breakpoint | — | — | instant (resizing is continuous) |
| Connect mode on / off | — | — | label in / out, instant |

## 5. Rules

- **R1. One act, one clock.** Everything a single act changes starts together. Where the board moves,
  the header moves on the board's clock.
- **R2. Nothing under the pointer moves.** The trailing chrome grows leftward from a pinned trailing
  edge; the tab bar grows rightward from a pinned leading edge. A control you are reaching for is
  where it was.
- **R3. No header view animates its own width.** Auto Layout takes a hosting view's width from
  `intrinsicContentSize` in one step while SwiftUI interpolates the contents, so an animated width
  change throws the row sideways (measured at 174pt; `HeaderChromeMotionTests`). Materialize is
  allowed because it changes no geometry.
- **R4. Whole items.** A capsule is present or absent; never empty, never full of hidden views.
- **R5. Materials belong to elements.** A control group wears glass in every state and the pill never
  does. What separates the header from the board is the board's edge, never a control changing what
  it is made of.
- **R6. Reduce Motion.** Every transition becomes a fade or a cut: no slides, no morphs, no bounce.
  `Motion` already routes durations and animations through one switch; glass transitions go through it
  too.

## 6. What was built

All on 2026-09-10.

1. `HeaderChrome` is key / not key. Resting and engaged, and every capsule's `onHover` that fed them,
   are gone.
2. The glass never fades: `headerBacking(in:showing:)` and every `backed:` parameter are gone, and each
   control group is glassed unconditionally.
3. The trailing chrome is one `GlassEffectContainer`. The page and tile capsules, the find field and
   the tab bar itself come and go through `HeaderPresence`, which inserts with no animation and
   materializes a turn later — by hand rather than `.glassEffectTransition(.materialize)`, because
   that runs under the inserting transaction and would animate the row (P1).
4. The tab bar's width snaps (P4); chips fade in and out; the highlight rides the board's 0.3s (Q5).
5. Hover is ours, one highlight per control (P2).
6. Background windows keep their 85% dim — judged right as it is (P3).
7. The pill has no glass; `CanvasEdgeView` draws the soft edge along the board's top, always on, ending
   where tiles begin (P5, Q6). `WindowDragExcluder` moved to a file of its own so the header's parts
   compile into `PMViewTests`, which now measures the real ones.

### Prototypes, each measured before it is built

- **P1. Can a capsule materialize while the row snaps?** Insert under a transaction whose animation
  reaches the glass transition but not the layout. Measure with `HeaderChromeMotionTests`: the control
  capsule's glyphs must not move at all.
  **Passed, 2026-09-10.** `HeaderPresence` inserts with no animation and materializes a turn later;
  the neighbouring capsule held at the same point in every sample, arriving and leaving, and a leaving
  capsule fades where it stands before the row closes up.
- **P2. What does system toolbar hover look like on 27?** Put a real `NSToolbar` item next to ours and
  compare.
  **Settled, 2026-09-10: ours.** The header wore the system's response — `.regular.interactive()` glass
  on each control group — for one build, and hovering changed nothing, neither the capsules nor what
  was in them: on the Mac, interactive glass answers presses, not the pointer passing over. The HIG's
  "the system defines hover … automatically" is about real toolbar items, which these are not. So the
  highlight stays as the one hover response, and the trial's switch is gone.
- **P3. What does `glassEffect` draw in a non-key window on 27?** If it already renders the inactive
  appearance, we do nothing but dim content the system way.
  **Settled by eye, 2026-09-10:** the background window as it stands — content at 85%, glass as the
  system draws it, the edge's blur following the window's active state — looks right. Nothing to add.
- **P5. How does a custom header get a system scroll edge effect?** AppKit exposes the effect only
  through `NSTitlebarAccessoryViewController` and `NSSplitViewItemAccessoryViewController`
  (`preferredScrollEdgeEffectStyle`, macOS 26.1); our header is hosting views laid over the board, not
  an accessory. In order of preference: (a) the band becomes a titlebar accessory that the islands sit
  in — the system draws the edge, `softStyle` set explicitly (automatic would resolve to hard here);
  (b) an empty accessory the height of the band, just to summon the effect, with the islands still laid
  over it; (c) draw our own gradient mask — last resort, since it is exactly the lookalike that drifts
  from the system's. Check with a 2D-panned canvas, which is not the vertical scroll the effect was
  designed around. **And check it is strong enough** — the ask was "clear and strong", and a soft blur
  over a busy board may read weaker than a line. It has to read as "the board stops here". If it
  doesn't, try `hardStyle`; if that doesn't either, the classic answer — a band of window background
  with a hairline under it, drawn by us, at the band's height.

  **P5 result, 2026-09-10: (c), our own.** The window already has AppKit's edge view — an
  `NSScrollPocket` exactly the band's 66pt — but in this window it never switches on: its soft and hard
  layers stayed hidden at zero size with the titlebar drawn or transparent, with or without a
  soft-preferring accessory, and with or without toolbar items (`ScrollEdgeEffectTests`, which now fails
  if that changes). (a) and (b) are out besides: an accessory adds a strip *below* the titlebar and takes
  clicks, and a drawn titlebar takes the band's clicks away from the board. `CanvasEdgeView` draws the
  soft edge as the system describes it — a blur masked to fade, over a tint toward the board's ground —
  and ends at 46pt, exactly where a workspace's tiles begin (header clearance 40 + tile gap 6). Its
  strength is still the thing to look at.

## 7. Open questions

- **Q1. Does the pill keep its glass? — settled: no.** The HIG says titles avoid glass and floating
  text gets a scroll edge effect instead, and it makes glass mean one thing: *you can press this*. How
  the effect gets under a custom header is P5.
- **Q2. How does find open? — settled: materialize in place.** The field arrives at its final width
  and the magnifier leaves as a whole item (R4). A true expansion would need a trailing host that never
  resizes — fixed width, pass-through hit-testing — which is the arrangement R3's measurements were
  taken against, and more machinery than one occasional errand is worth.
- **Q3. Four groups — settled: live with it.** With glass on every control group there are three with a
  page up — tabs, page, controls — which is the HIG's number. Four only while a web tile is focused in a
  workspace, where the tile and the page are one card at two scales. Not worth merging for.
- **Q4. How does a chip arrive? — settled: B, after P4.** Today the row snaps wider and the current-tab backing slides onto the
  new chip. The alternatives:

  | | What you see | Cost |
  |---|---|---|
  | A. Snap + slide (today) | Row jumps wider; backing slides onto the new chip | Nothing |
  | B. Snap + fade | Row jumps wider; the new label fades in where it lands, backing slides | Small; same vocabulary as materialize |
  | C. Grow from the pinned edge | The bar's glass stretches rightward and the chip fades in as it opens | Prototype P4 |
  | D. Arrive from the act | The chip appears where the act that made it happened — ⌘Return's workspace grows out of the options menu | Crosses hosting views; no glass API spans them |

  **C is the interesting one, because R3 may not apply to this bar.** The 174pt throw came from a view
  whose *leading* edge moved: the trailing chrome is pinned on the right and grows left, so its origin
  jumps while its contents interpolate from the old one. The tab bar is pinned on the *left*, to the
  pill, which no longer changes width — so its origin never moves, and a growing capsule inside a host
  that has already snapped to the final width may simply look like growing. Two things to measure:
  that existing chips stay put to the point, and that a *shrinking* bar isn't clipped by a host that
  has already snapped narrower.

  **P4.** Animate the tab bar's width on add and remove, measured with `HeaderChromeMotionTests`. If
  both checks pass, C; otherwise B.

  **P4 result, 2026-09-10 (`TabBarGrowthTests`, the real bar):** the pinned edge never moved — 0pt, both
  ways — but the bar is at its final width by the first frame. The row measures itself and the bar's
  width follows a pass later with no animation to carry it, so there is no stretch to show. B: the new
  chip fades in where it lands, a deleted one fades out.
- **Q5. Does the current-tab backing ride the board's clock? — settled: yes, 0.3s.** L3 keeps its 0.2s slide, but when the
  slide is part of a canvas ↔ workspace switch, R1 says it should start with the flight and run its
  0.3s. It already starts together; the question is whether ending 0.1s early reads as a second clock.
- **Q6. Does the edge stay under a workspace? — settled: yes, and it's soft.** The question existed
  because the first proposal was a hard edge, which is a line that is always visible: keeping it under a
  workspace drew a divider over nothing, and removing it meant the band changed between views. A soft
  edge dissolves the choice. It only shows when something passes under it, so it is on in both views,
  does real work on the canvas, is invisible over a workspace, and never switches. Nothing in the
  header changes between the canvas and a workspace except the tile capsule.
