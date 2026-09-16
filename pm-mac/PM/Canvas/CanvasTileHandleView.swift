import AppKit
import PmLib

/// The tab strips, and what has to sit under the cards to draw them.
///
/// Its own view rather than more drawing in the overlay, and the reason is the z-order. The overlay is
/// above the cards, which is right for grips and dots and a sweep rectangle: those are things you are
/// about to grab, and a card lying over one would be a control you cannot reach. A strip is the opposite
/// kind of thing. It belongs to a tile, it is drawn in the tile's own band, and while a tile is being
/// dragged across it the tile should cover it. So this goes at the bottom of the board's subviews: above
/// the board's own drawing — the ground, the grid, the frames and the lines — and below every card.
///
/// **The tile grips used to be drawn here too**, when they sat in the gaps between tiles. They moved onto
/// the tiles (backlog 20) and so up above the cards, into `CanvasTileGripView`.
///
/// **The alignment guides used to live here too, and the same argument put them here** — a mark about
/// where a card is *going*, drawn between cards, that a card sliding over should cover. What replaced
/// them is a target rather than an explanation, and a target is a thing the card lands on *top* of:
/// below the cards it would be hidden at the very moment it is confirming the match, and it has to be
/// legible across a card's own face when you are sizing one down. So it went up into the overlay. See
/// `CanvasGhost` and `CanvasOverlayView.drawGhost`.
///
/// Like the overlay, it never takes a click.
@MainActor
final class CanvasTileHandleView: NSView {
    weak var board: CanvasBoardView?

    // MARK: Motion

    /// One per tab sliding aside for a tab being dragged past it: how far over it is, 0 to 1 of a step.
    private var slideFades: [String: CanvasFade] = [:]
    /// One per tab the pointer has been over: its hover fill and close button, fading rather than
    /// switching as the pointer runs along the strip.
    private var hoverFades: [String: CanvasFade] = [:]
    /// The showing tab's chip on its way from the tab that was showing, per strip: where it set off from
    /// and how far it has come. See `chipRect`.
    private var chipTravels: [String: (from: NSRect, fade: CanvasFade)] = [:]
    /// Where each strip's chip was last drawn, and for which card — what a change of tab travels from.
    private var lastChips: [String: (card: String, rect: NSRect)] = [:]
    /// Where each tab was last drawn, and where the tabs of a drag that has just ended were let go, so
    /// they ease into their places rather than jumping there.
    private var drawnX: [String: CGFloat] = [:]
    private var settleFrom: [String: CGFloat] = [:]
    private lazy var settleFade = CanvasFade(rise: 0.18, fall: 0.18, on: self) { [weak self] in
        self?.needsDisplay = true
    }

    /// A tab drag moved on, started or ended: set each neighbour sliding towards where it should be.
    ///
    /// While the drag runs, the dragged tab is wherever the pointer is and only its neighbours animate.
    /// When it ends — let go, or pulled off the strip — every tab eases from where it was drawn into the
    /// place the new order gives it, so the one you let go of settles into its slot.
    func tabSlideChanged(from old: CanvasTabSlide?) {
        defer { needsDisplay = true }
        guard let slide = board?.tabSlide, let strip = board?.tiling?.tabStrips
            .first(where: { $0.cards.contains(slide.card) }) else {
            if old != nil {
                settleFrom = drawnX
                settleFade.hold(1)
                settleFade.set(false)
            }
            for fade in slideFades.values { fade.hold(0) }
            slideFades = [:]
            return
        }
        for (index, card) in strip.cards.enumerated() where card != slide.card {
            let shifted = slide.from < slide.to ? (index > slide.from && index <= slide.to)
                                                : (index < slide.from && index >= slide.to)
            slideFade(card).set(shifted)
        }
    }

    /// The tab under the pointer changed: fade the old one's hover out and the new one's in.
    func hoverChanged(from old: String?, to new: String?) {
        guard old != new else { return needsDisplay = true }
        if let old { hoverFade(old).set(false) }
        if let new { hoverFade(new).set(true) }
    }

    private func slideFade(_ card: String) -> CanvasFade {
        if let existing = slideFades[card] { return existing }
        let fade = CanvasFade(rise: 0.16, fall: 0.16, on: self) { [weak self] in self?.needsDisplay = true }
        slideFades[card] = fade
        return fade
    }

    private func hoverFade(_ card: String) -> CanvasFade {
        if let existing = hoverFades[card] { return existing }
        let fade = CanvasFade(rise: 0.1, fall: 0.16, on: self) { [weak self] in self?.needsDisplay = true }
        hoverFades[card] = fade
        return fade
    }

    /// Where the showing tab's chip is drawn: on the tab showing, or on its way there from the tab that
    /// was — a click on another tab slides the chip across, 0.2s, the way the header's current-tab
    /// backing does, rather than cutting.
    private func chipRect(for key: String, card: String, at target: NSRect) -> NSRect {
        if let last = lastChips[key], last.card != card {
            let fade = CanvasFade(rise: 0.2, fall: 0.2, on: self) { [weak self] in self?.needsDisplay = true }
            chipTravels[key] = (last.rect, fade)
            fade.set(true)
        }
        var rect = target
        if let travel = chipTravels[key] {
            if travel.fade.isMoving || travel.fade.presence < 1 {
                let t = Self.easeOut(travel.fade.presence)
                rect = NSRect(x: travel.from.minX + (target.minX - travel.from.minX) * t,
                              y: target.minY,
                              width: travel.from.width + (target.width - travel.from.width) * t,
                              height: target.height)
            } else {
                chipTravels[key] = nil
            }
        }
        lastChips[key] = (card, rect)
        return rect
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 3) }
    private static func smooth(_ t: Double) -> Double { let t = min(1, max(0, t)); return t * t * (3 - 2 * t) }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: The strips, carved out of the window drag (canvas-backlog.md 22)

    /// One invisible view over each tab strip, and they exist for a single property.
    ///
    /// The project window runs the board under a transparent titlebar, and an empty unified toolbar
    /// makes that band **66pt** deep (measured, `WindowDragBandTests`). Tiles begin at 46 —
    /// `headerClearance` plus `CanvasTiling.edgeGap` — so 20 of a strip's 32 points lie inside the
    /// band, and a press on almost all of a top-row tab is AppKit's to interpret before it is
    /// anybody's to handle.
    ///
    /// It interprets one by building a region out of the view tree **in z-order**: a view answering
    /// `mouseDownCanMoveWindow` with no carves its frame out of the window drag, and any view in front
    /// of it answering yes puts that frame straight back. Not by hit-testing, which is the reading that
    /// looks right and says the header's own excluders could never work either. The board answers yes
    /// by saying nothing — `NSView`'s default is true — so without these, dragging a tab moved the
    /// window.
    ///
    /// **Only the strips, and that is the decision rather than the cheap way out.** One line on
    /// `CanvasBoardView` would have carved out the entire board, and taken the whole band with it: the
    /// empty top of a board is somewhere to grab the window, which is worth keeping in a window whose
    /// titlebar is otherwise invisible. These carve out the part of that band that is a control.
    ///
    /// **They only reach as far as the board does.** `CanvasEdgeView` is a sibling in front of the
    /// whole scroll view and answers the drag with true, so nothing in here can carve out anything
    /// above it. It ends at 46 and the tiles start at 46 — the same line, which is why this works; a
    /// strip that ever sat higher would need the answer to move out to the pane.
    ///
    /// They take no clicks, like everything else in this view. A press on a tab still reaches the
    /// board's own `mouseDown` and `tabChip(at:)`; all these change is what AppKit does with a press
    /// *before* anyone's `mouseDown` is called.
    private var stripExcluders: [Excluder] = []

    final class Excluder: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Put one over each strip. Driven from `layoutNodeViews`, because where a strip is is a fact about
    /// the layout — not about the pointer, which is what the handlebars follow.
    ///
    /// The views are moved rather than rebuilt: this runs on every layout pass, including every frame
    /// of a tile being dragged, and a strip that has not moved should cost a frame comparison.
    func refreshStripExcluders() {
        // The same two conditions `drawTabStrips` draws under: no tiling and no strips, and while the
        // board is picking there are none on screen to carve out.
        var bands: [NSRect] = []
        if let board, !board.isPicking, let session = board.tiling {
            bands = session.tabStrips.map { board.viewRect($0.band) }
        }
        while stripExcluders.count < bands.count {
            let view = Excluder(frame: .zero)
            addSubview(view)
            stripExcluders.append(view)
        }
        while stripExcluders.count > bands.count {
            stripExcluders.removeLast().removeFromSuperview()
        }
        for (view, band) in zip(stripExcluders, bands) where view.frame != band { view.frame = band }
    }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        drawTabStrips(board, board.liveScale)
    }

    /// The tabs across the top of a tile holding more than one card (docs/canvas-workspaces.md §7k).
    ///
    /// **Here, under the cards**, for the reason given above: the band is the tile's own — the room the
    /// layout leaves above the card that is showing — and the only thing that should ever pass over it
    /// is a tile being carried across. Drawn a little way down under the card as well, so the card's own
    /// top corners round off into the strip rather than onto the ground behind it.
    private func drawTabStrips(_ board: CanvasBoardView, _ scale: Double) {
        guard let session = board.tiling, !board.isPicking else { return }
        let space = CanvasTiling.space(of: session.area)
        for strip in session.tabStrips {
            let outer = CanvasTiling.corners(of: strip.band, in: space)
            var radii = CanvasTiling.Corners(topLeft: outer.topLeft, topRight: outer.topRight,
                                             bottomRight: false, bottomLeft: false)
                .radii(inner: CanvasTiling.innerRadius, outer: CanvasTiling.outerRadius)
            radii.bottomLeft = 0
            radii.bottomRight = 0
            var band = board.viewRect(strip.band)
            band.size.height += CanvasTiling.outerRadius
            CanvasPalette.card.setFill()
            CanvasNodeView.path(in: band, radii: radii).fill()

            let chips = CanvasTiling.tabs(in: strip.band, count: strip.cards.count)
            let slide = board.tabSlide.flatMap { strip.cards.contains($0.card) ? $0 : nil }
            let settling = settleFade.isVisible ? Self.easeOut(1 - settleFade.presence) : 1
            var rects: [NSRect] = []
            for (index, (card, chip)) in zip(strip.cards, chips).enumerated() {
                var rect = board.viewRect(chip)
                if let slide {
                    if card == slide.card {
                        rect.origin.x += slide.dx * scale
                    } else {
                        // A step is one tab and the gap after it, and a tab only ever moves towards the
                        // place the dragged one left.
                        let step = rect.width + CanvasTiling.gap * scale
                        let presence = Self.smooth(slideFades[card]?.presence ?? 0)
                        rect.origin.x += (index > slide.from ? -step : step) * presence
                    }
                } else if settling < 1, let from = settleFrom[card] {
                    rect.origin.x += (from - rect.minX) * (1 - settling)
                }
                drawnX[card] = rect.minX
                rects.append(rect)
            }

            let key = strip.cards.sorted().joined(separator: "\u{1}")
            let shown = strip.cards[strip.showing]
            drawChip(in: chipRect(for: key, card: shown, at: rects[strip.showing]), scale)

            let draggedIndex = slide.flatMap { strip.cards.firstIndex(of: $0.card) }
            for (index, card) in strip.cards.enumerated() where index != draggedIndex {
                drawTab(card, in: rects[index], showing: index == strip.showing, board, scale,
                        hoverable: slide == nil)
            }
            if let draggedIndex {
                drawTab(strip.cards[draggedIndex], in: rects[draggedIndex],
                        showing: draggedIndex == strip.showing, board, scale, hoverable: false)
            }
        }
    }

    /// The showing tab's chip: **a small piece of glass on the card** (backlog 21, tuned by eye
    /// 2026-09-16) — a round rect of the label colour at 8.5%, lit from the top by a gradient and a
    /// half-point line, ringed by a half-point rim, and lifted by a soft shadow. Drawn apart from the tab
    /// so it can travel between tabs.
    private func drawChip(in rect: NSRect, _ scale: Double) {
        let radius = Self.tabRadius / scale
        let chip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let dark = effectiveAppearance.isDark
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(Self.lift * 0.22)
        lift.shadowOffset = NSSize(width: 0, height: -1)
        lift.shadowBlurRadius = 2
        lift.set()
        NSColor.labelColor.withAlphaComponent(Self.fill).setFill()
        chip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        chip.addClip()
        // Top-lit: white fading out down the chip — much stronger in light appearance, where the chip is
        // grey on white and the light has to read as a sheen rather than as nothing.
        let sheen = dark ? Self.rim * 0.10 : Self.rim * 0.9
        NSGradient(colors: [.white.withAlphaComponent(sheen), .white.withAlphaComponent(0)],
                   atLocations: [0, dark ? 0.6 : 0.7], colorSpace: .sRGB)?
            .draw(in: rect, angle: 90)
        NSColor.white.withAlphaComponent(Self.rim * 0.35).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5 / scale).fill()
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25 / scale, dy: 0.25 / scale),
                                xRadius: radius, yRadius: radius)
        ring.lineWidth = 0.5 / scale
        NSColor.labelColor.withAlphaComponent(0.06 + Self.rim * 0.06).setStroke()
        ring.stroke()
    }

    /// One tab: the card's icon and name, as the zoomed-out board and Add Card from Canvas call it, so a
    /// card is recognisable by the same two things wherever it is listed.
    ///
    /// Bare until the pointer is over it, when it takes a paler fill — unless it is the one showing,
    /// which has the chip — and shows its close button, both fading. Regular weight throughout: which tab
    /// is showing is said by the chip and the colour, not by the name getting heavier.
    private func drawTab(_ card: String, in rect: NSRect, showing: Bool,
                         _ board: CanvasBoardView, _ scale: Double, hoverable: Bool) {
        let hover = hoverable ? (hoverFades[card]?.presence ?? 0) : 0
        let radius = Self.tabRadius / scale
        if !showing, hover > 0 {
            NSColor.labelColor.withAlphaComponent(Self.fill * 0.55 * hover).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        guard let described = board.document.node(id: card).flatMap(CanvasExistingCards.card) else { return }
        let side = 14 / scale
        var textLeft = rect.minX + 8 / scale
        if let icon = CanvasBoardView.menuIcon(for: described.kind) {
            icon.draw(in: NSRect(x: textLeft, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: showing ? 1 : 0.6,
                      respectFlipped: true, hints: nil)
            textLeft += side + 6 / scale
        }
        // The close button's room is kept whether or not it is showing, so a name doesn't re-truncate
        // under the pointer.
        let close = Self.closeRect(in: rect, scale: scale)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12 / scale, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: showing ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let height = font.boundingRectForFont.height
        let text = NSRect(x: textLeft, y: rect.midY - height / 2,
                          width: max(0, close.minX - 6 / scale - textLeft), height: height)
        (described.name as NSString).draw(with: text, options: [.usesLineFragmentOrigin,
                                                                 .truncatesLastVisibleLine],
                                          attributes: attributes)

        guard hover > 0 else { return }
        let onClose = hoverable && board.hoveredTab?.card == card && board.hoveredTab?.onClose == true
        if onClose {
            NSColor.labelColor.withAlphaComponent(0.1 * hover).setFill()
            NSBezierPath(roundedRect: close, xRadius: 4 / scale, yRadius: 4 / scale).fill()
        }
        let cross = NSBezierPath()
        let arm = 4 / scale
        cross.move(to: NSPoint(x: close.midX - arm, y: close.midY - arm))
        cross.line(to: NSPoint(x: close.midX + arm, y: close.midY + arm))
        cross.move(to: NSPoint(x: close.midX + arm, y: close.midY - arm))
        cross.line(to: NSPoint(x: close.midX - arm, y: close.midY + arm))
        cross.lineWidth = 1.3 / scale
        cross.lineCapStyle = .round
        (onClose ? NSColor.labelColor : NSColor.secondaryLabelColor).withAlphaComponent(hover).setStroke()
        cross.stroke()
    }

    /// A tab's close button, inside its trailing edge. In view coordinates, like the tab it is in; the
    /// board reads the same rectangle in canvas coordinates through `tabClose(at:)`.
    static func closeRect(in tab: NSRect, scale: Double) -> NSRect {
        let side = 16 / scale
        return NSRect(x: tab.maxX - 5 / scale - side, y: tab.midY - side / 2, width: side, height: side)
    }

    /// The strip's look, as tuned: radius, fill, and how strongly the showing tab is lit and lifted.
    static let tabRadius: Double = 6
    static let fill: Double = 0.085
    static let rim: Double = 0.25
    static let lift: Double = 0.65
}

/// A tab being dragged along its strip: which, where it started in the strip, how far it has been
/// carried in canvas points, and the place in the strip it would land in now.
struct CanvasTabSlide: Equatable {
    var card: String
    var from: Int
    var dx: Double
    var to: Int
}

/// The tile grips (backlog 20), and the one thing that lets a press on one reach the board.
///
/// **Above the cards**, because a grip is on the tile it moves, and the board's own views are the
/// only thing between it and the page under it. It draws nothing but the grips and takes no clicks
/// itself; the grip that is showing gets a catcher, a view exactly its hit area that does — without
/// one, the press lands in the card, and over a web page that is the page's click.
@MainActor
final class CanvasTileGripView: NSView {
    weak var board: CanvasBoardView?

    /// Which tiles are showing their grip. Set by the board — see `refreshTileHandles`.
    ///
    /// Faded rather than switched, one fade per tile: moving from one tile's top to the next is a mark
    /// leaving where it was and arriving where you are, and two crossing fades say both.
    var shownTileHandles: Set<String> = [] {
        didSet {
            guard shownTileHandles != oldValue else { return }
            for id in shownTileHandles.union(oldValue) {
                handleFade(id).set(shownTileHandles.contains(id))
            }
            needsDisplay = true
        }
    }
    private var handleFades: [String: CanvasFade] = [:]
    private let catcher = Catcher()

    override init(frame: NSRect) {
        super.init(frame: frame)
        catcher.isHidden = true
        addSubview(catcher)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func handleFade(_ id: String) -> CanvasFade {
        if let existing = handleFades[id] { return existing }
        // Quicker in than out: appearing has to keep up with a pointer, and leaving is allowed to take
        // its time because nothing is waiting on it.
        let fade = CanvasFade(rise: 0.11, fall: 0.18, on: self) { [weak self] in
            self?.needsDisplay = true
        }
        handleFades[id] = fade
        return fade
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !catcher.isHidden else { return nil }
        let local = convert(point, from: superview)
        return catcher.frame.contains(local) ? catcher : nil
    }

    override func draw(_ dirty: NSRect) {
        guard let board, let tiling = board.tiling else { return placeCatcher(nil) }
        placeCatcher(board)
        let scale = board.liveScale
        for id in tiling.ids {
            guard let fade = handleFades[id], fade.isVisible, let handle = board.tileHandle(id) else { continue }
            let presence = fade.presence
            // Widens a little as it fades in — from 70% of its length — so it arrives as a mark coming
            // up under the pointer rather than a rectangle switching on.
            var rect = board.viewRect(handle.bar)
            let width = rect.width * (0.7 + 0.3 * (1 - pow(1 - presence, 3)))
            rect = NSRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
            let radius = min(rect.width, rect.height) / 2
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            // Over a page of any colour, so it carries its own contrast: a soft shadow under a mark of
            // the label colour. A pinned tile says so on its grip, which is its one mark about layout.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2 * presence)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 3
            shadow.set()
            if board.isTilePinned(id) {
                NSColor.controlAccentColor.withAlphaComponent(0.85 * presence).setFill()
            } else {
                NSColor.labelColor.withAlphaComponent(0.32 * presence).setFill()
            }
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Over the grip that is showing, or nowhere.
    private func placeCatcher(_ board: CanvasBoardView?) {
        // Never out from under a press it took: the rest of that drag is delivered to it.
        if board?.gesture != nil, !catcher.isHidden { return }
        guard let board, let id = board.gripTile, board.showsTileHandle(id), let handle = board.tileHandle(id) else {
            if !catcher.isHidden { catcher.isHidden = true; window?.invalidateCursorRects(for: catcher) }
            return
        }
        let rect = board.viewRect(handle.hit)
        if catcher.frame != rect || catcher.isHidden {
            catcher.frame = rect
            catcher.isHidden = false
            catcher.board = board
            window?.invalidateCursorRects(for: catcher)
        }
    }

    /// Takes a press on a grip for the board. Out of the window drag, since the top of a top-row tile is
    /// inside the transparent titlebar's band (see `CanvasTileHandleView.stripExcluders`).
    final class Catcher: NSView {
        weak var board: CanvasBoardView?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { board?.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { board?.mouseDragged(with: event) }
        override func mouseUp(with event: NSEvent) { board?.mouseUp(with: event) }
        override func rightMouseDown(with event: NSEvent) { board?.rightMouseDown(with: event) }
    }
}
