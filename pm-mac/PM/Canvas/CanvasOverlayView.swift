import AppKit
import PmLib

/// Everything drawn *over* the cards: the ghost a drag is being offered, selection grips, connection
/// dots, the sweep rectangle, and the line being dragged out of a card. (The ghost is drawn here but
/// clipped to read as lying beneath every card that isn't moving — see `tuckBeneathStandingCards`.)
///
/// Not the tile handlebars, which are the one piece of board chrome that belongs *under* the cards —
/// see `CanvasTileHandleView`.
///
/// A view of its own rather than more drawing in the board, because these have to sit above the cards
/// and the cards are real subviews — a board that drew its grips in `draw(_:)` would draw them
/// underneath every card it had just built.
///
/// It never takes a click. `hitTest` returns nil unconditionally, so the pointer reaches the board
/// beneath and the board keeps being the single place a click is interpreted. The grips are drawn
/// here and *hit* there, which sounds like a split until you notice it is the only arrangement where
/// hit-testing can be tested without a window.
@MainActor
final class CanvasOverlayView: NSView {
    weak var board: CanvasBoardView?
    /// The sweep in progress, in canvas coordinates.
    var marquee: CanvasRect?

    /// Where the cards being placed would land if the match on offer were taken, and which cards the
    /// offer is being made against. One rectangle per moving card — see `CanvasGhost`, which owns the
    /// argument for all of this.
    struct Ghost: Equatable {
        /// One outline per card being placed.
        var frames: [CanvasRect]
        /// The box those cards land in: what the matches were found for, and what the landing's own
        /// marks are drawn on. The same as the one frame when a single card is moving.
        var landing: CanvasRect
        var matches: [CanvasMatch]
        /// Whether the landing outline is drawn — see `CanvasGhost.isComplete`.
        var isComplete: Bool
        /// The cards standing still on screen, which the outline is drawn *beneath*. See `drawGhost`.
        var beneath: [CanvasRect]
        /// How tidy those cards are, which sets how far a mark on a distant card carries — see `fade`.
        var tidiness: Double

        init(_ ghost: CanvasGhost, frames: [CanvasRect], beneath: [CanvasRect]) {
            self.frames = frames
            landing = ghost.frame
            matches = ghost.matches
            isComplete = ghost.isComplete
            self.beneath = beneath
            tidiness = CanvasSnapping.tidiness(of: beneath)
        }
    }

    /// The offer in front of you, or nil for "nothing is on offer".
    ///
    /// Setting this fades the outline in or out rather than switching it — see `CanvasFade`. The last
    /// non-nil value is held in `drawnGhost` so that clearing this on mouse-up leaves something to fade
    /// *out*; an outline that vanished on the frame the button came up would be the flicker the fade
    /// exists to remove.
    var ghost: Ghost? {
        didSet {
            guard ghost != oldValue else { return }
            if let ghost {
                // An offer arriving out of nothing arrives with its outline or without it. Fading from
                // whatever the last drag left behind would draw a ring nobody has earned yet.
                if ghostFade.isVisible { ringFade.set(ghost.isComplete) }
                else { ringFade.hold(ghost.isComplete ? 1 : 0) }
                drawnGhost = ghost
            }
            ghostFade.set(ghost != nil)
            needsDisplay = true
        }
    }
    private var drawnGhost: Ghost?
    private lazy var ghostFade = CanvasFade(rise: 0.1, fall: 0.16, on: self) { [weak self] in
        self?.needsDisplay = true
    }
    /// The landing outline, which comes and goes *within* an offer as the second axis is caught or
    /// lost — a cross-fade with the marks that stand in for it, rather than a ring blinking on.
    private lazy var ringFade = CanvasFade(rise: 0.12, fall: 0.12, on: self) { [weak self] in
        self?.needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        let scale = board.liveScale

        // First, so everything else in here sits over it. The ghost is the only mark in this view that
        // is about a card's *future*, and a grip you are dragging should not be interrupted by it.
        drawGhost(board, scale)
        drawConnectionAnchors(board, scale)
        drawSelectionBounds(board, scale)
        drawGrips(board, scale)
        drawConnectionInFlight(board, scale)
        drawSwapInFlight(board, scale)
        drawMarquee(board, scale)
    }

    /// The outline of where the cards being placed would land, and the marks that say what it agrees
    /// with.
    ///
    /// **One thing governs how present it is: the fade.** There used to be a second, a `nearness` the
    /// alpha was multiplied by, so that the outline grew as the card approached its match. It read as
    /// an argument and drew as a smear — over most of the approach it put the mark at a fraction of an
    /// alpha chosen to be quiet at full strength, which is a mark that is not there. So the offer is
    /// either up or not, and the fade is what keeps that from being a blink: appearing and withdrawing
    /// are both dissolves, and crossing the radius is the only event either of them reports.
    ///
    /// Standing off the frame rather than drawn on it, at the same distance and radius rule the
    /// selection band uses, so the board's transient marks are visibly one family. The standoff earns
    /// its place twice over: at the moment the snap fires the outline is a ring *around* the card
    /// rather than a stroke merged into its border, so the landing is still visible — and when you are
    /// sizing a card *down*, the offered frame is inside the card's current bounds, where a mark on the
    /// border would have nothing to stand on at all.
    ///
    /// **The outline is only drawn once the landing is decided** — see `CanvasGhost.isComplete`. Until
    /// then the landing carries marks of its own on the sides that matched, and the two cross-fade as
    /// the second axis is caught or lost (`ringFade`).
    ///
    /// **The marks are pieces of the outline.** They used to be a glow round each card being agreed
    /// with, on the argument that a glow sits *on* a card and so reads as "this card is the reason"
    /// rather than "a card is going here". It did, and it said nothing about *what* on that card was
    /// the reason — and beside a crisp band a soft glow was a second material that nothing else on the
    /// board is made of. So a mark is now the same band, at the same standoff and strength, cut to the
    /// side or the centre or the gap that makes the match: see `drawMatches`. A bracket on a card whose
    /// edge you are matching stands exactly in line with the outline's side, which is the match drawn.
    ///
    /// **And never over the outline.** The marks are drawn on a layer of their own, the outline's band
    /// is cut out of that layer, and only then is it laid down — so a mark reaching the outline stops
    /// at its edge, whatever the two alphas are, rather than darkening where they cross.
    private func drawGhost(_ board: CanvasBoardView, _ scale: Double) {
        guard ghostFade.isVisible, let drawnGhost else { return }
        let presence = ghostFade.presence
        guard presence > 0.001, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        tuckBeneathStandingCards(drawnGhost, board, scale)

        let ring = ringFade.presence
        let outlines = drawnGhost.frames.map { outline(around: $0, board, scale) }
        if ring > 0.001 {
            CanvasPalette.guide(Self.ghostAlpha * presence * ring).setStroke()
            for outline in outlines { outline.stroke() }
        }

        guard !drawnGhost.matches.isEmpty else { return }
        let layer = context.cgContext
        layer.beginTransparencyLayer(auxiliaryInfo: nil)
        drawMatches(drawnGhost, board, scale, presence: presence, landing: 1 - ring)
        if ring > 0.001 {
            // Cut as deep as the outline is present, so a mark half-way through the cross-fade is
            // half-trimmed rather than suddenly short.
            context.saveGraphicsState()
            context.compositingOperation = .destinationOut
            NSColor(white: 0, alpha: ring).setStroke()
            for outline in outlines { outline.stroke() }
            context.restoreGraphicsState()
        }
        layer.endTransparencyLayer()
    }

    /// The band around one landing frame.
    ///
    /// Concentric with the card inside it: a curve offset from another curve keeps an even gap only
    /// when its radius grows by the offset. Left at the card's own radius the outline would pinch
    /// tight at the corners and bulge along the sides.
    private func outline(around slot: CanvasRect, _ board: CanvasBoardView,
                         _ scale: Double) -> NSBezierPath {
        let standoff = Self.ghostStandoff / scale
        let rect = board.viewRect(slot).insetBy(dx: -standoff, dy: -standoff)
        let radius = CanvasNodeView.cornerRadius(for: slot) + standoff
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.ghostWidth / scale
        return path
    }

    /// The marks on the cards the landing agrees with — and on the landing itself, where the outline
    /// isn't up to speak for it.
    ///
    /// - An **edge** is a bracket: the side of the card's own ring the edge is on and the two corners
    ///   either end of it, standing exactly in line with the landing's.
    /// - A **centre** is a notch: a short piece of band across the middle of the side facing the
    ///   landing.
    /// - A **gap** is a bridge from standoff to standoff across it — into the outline, on the landing's
    ///   side — once for every gap keeping the pitch.
    /// - A **length** brackets the side that measures it, on both cards: the bottom for a width, the
    ///   right for a height.
    /// - A card **level** with the landing is one bracket, on its side facing the landing — unless the
    ///   two are close enough that the outline is already touching it, which says the same thing.
    ///
    /// Each piece is its own open stroke with round ends. Never a stretch of a whole ring clipped to one
    /// side: a clip leaves the band with square, sheared ends, which is the one hard edge in the
    /// vocabulary and the first thing the eye finds.
    ///
    /// `own` is how strongly the landing's own pieces are drawn: fully while the outline is down, and
    /// not at all once it is up, since a second stroke over the outline's side only draws seams.
    private func drawMatches(_ ghost: Ghost, _ board: CanvasBoardView, _ scale: Double,
                             presence: Double, landing own: Double) {
        let standoff = Self.ghostStandoff / scale
        let landing = board.viewRect(ghost.landing)
        // `viewRect` is a translation, so a canvas coordinate is this plus the origin.
        let origin = board.viewPoint(CanvasPoint(x: 0, y: 0))
        let seen = board.visibleRect
        let diagonal = hypot(seen.width, seen.height)

        func fade(_ card: CanvasRect) -> Double {
            Self.fade(distance: Self.distance(board.viewRect(card), landing), across: diagonal,
                      tidiness: ghost.tidiness)
        }
        func stroke(_ path: NSBezierPath, _ strength: Double) {
            let alpha = Self.ghostAlpha * strength * presence
            guard alpha > 0.001 else { return }
            path.lineWidth = Self.ghostWidth / scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            CanvasPalette.guide(alpha).setStroke()
            path.stroke()
        }
        func bracket(_ card: CanvasRect, _ side: CanvasSide, _ strength: Double) {
            let rect = board.viewRect(card).insetBy(dx: -standoff, dy: -standoff)
            stroke(Self.bracket(rect, radius: CanvasNodeView.cornerRadius(for: card) + standoff,
                                side: side), strength)
        }
        func pill(_ from: NSPoint, _ to: NSPoint, _ strength: Double) {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            stroke(path, strength)
        }
        /// A centre's notch across `line`, standing off `edge` on the side `outward` points to.
        func notch(across line: CGFloat, off edge: CGFloat, outward: CGFloat, horizontal: Bool,
                   _ strength: Double) {
            let at = edge + outward * standoff, half = Self.notchLength / 2 / scale
            if horizontal {
                pill(NSPoint(x: line - half, y: at), NSPoint(x: line + half, y: at), strength)
            } else {
                pill(NSPoint(x: at, y: line - half), NSPoint(x: at, y: line + half), strength)
            }
        }

        // Edges and centres, gathered by the line they share, so the landing's own piece is drawn
        // once per line however many cards are on it.
        var lines: [(horizontal: Bool, at: Double, cards: [(card: CanvasRect, part: CanvasSpanPart)])] = []
        for case .edge(let card, horizontal: let horizontal, part: let part) in ghost.matches {
            let at = part.value(in: card, horizontal: horizontal)
            if let index = lines.firstIndex(where: { $0.horizontal == horizontal && abs($0.at - at) < 0.01 }) {
                lines[index].cards.append((card: card, part: part))
            } else {
                lines.append((horizontal: horizontal, at: at, cards: [(card: card, part: part)]))
            }
        }
        for line in lines {
            let horizontal = line.horizontal
            let at = horizontal ? origin.x + line.at : origin.y + line.at
            let across = horizontal ? landing.midY : landing.midX
            var before = false, after = false
            for (card, part) in line.cards {
                let rect = board.viewRect(card)
                let isBefore = (horizontal ? rect.midY : rect.midX) < across
                if isBefore { before = true } else { after = true }
                if part == .middle {
                    let facing = isBefore ? (horizontal ? rect.maxY : rect.maxX)
                                          : (horizontal ? rect.minY : rect.minX)
                    notch(across: at, off: facing, outward: isBefore ? 1 : -1, horizontal: horizontal,
                          fade(card))
                } else {
                    bracket(card, Self.side(part, horizontal: horizontal), fade(card))
                }
            }
            guard own > 0.001 else { continue }
            if abs(line.at - CanvasSpanPart.middle.value(in: ghost.landing, horizontal: horizontal)) < 0.01 {
                if before {
                    notch(across: at, off: horizontal ? landing.minY : landing.minX, outward: -1,
                          horizontal: horizontal, own)
                }
                if after {
                    notch(across: at, off: horizontal ? landing.maxY : landing.maxX, outward: 1,
                          horizontal: horizontal, own)
                }
            } else {
                let lead = CanvasSpanPart.lead.value(in: ghost.landing, horizontal: horizontal)
                bracket(ghost.landing,
                        Self.side(abs(line.at - lead) < 0.01 ? .lead : .trail, horizontal: horizontal), own)
            }
        }

        for case .gap(let gap) in ghost.matches {
            let from = gap.lead + standoff, to = gap.trail - standoff
            guard to - from >= 1 / scale else { continue }
            let middle = (gap.crossLead + gap.crossTrail) / 2
            if gap.horizontal {
                pill(NSPoint(x: origin.x + from, y: origin.y + middle),
                     NSPoint(x: origin.x + to, y: origin.y + middle), fade(gap.far))
            } else {
                pill(NSPoint(x: origin.x + middle, y: origin.y + from),
                     NSPoint(x: origin.x + middle, y: origin.y + to), fade(gap.far))
            }
        }

        var measured: [Bool] = []
        for case .length(let card, horizontal: let horizontal) in ghost.matches {
            let side: CanvasSide = horizontal ? .bottom : .right
            if own > 0.001, !measured.contains(horizontal) {
                measured.append(horizontal)
                bracket(ghost.landing, side, own)
            }
            bracket(card, side, fade(card))
        }

        for case .level(let card, horizontal: let horizontal) in ghost.matches {
            let rect = board.viewRect(card)
            let side: CanvasSide = horizontal ? (rect.midY < landing.midY ? .bottom : .top)
                                              : (rect.midX < landing.midX ? .right : .left)
            if Self.clearance(rect, side, landing) > 2 * standoff + 1 / scale {
                bracket(card, side, fade(card))
            }
            if own > 0.001 { bracket(ghost.landing, side.opposite, own) }
        }
    }

    /// How present a mark on a card is, by how far that card is from the landing: full beside it,
    /// easing down across the window to a floor.
    ///
    /// **Governed by how tidy the board on screen is** — see `CanvasSnapping.tidiness(of:)`. On a tidy
    /// board a landing agrees with half the cards in view, and marking all of them at one strength is
    /// a board lit up for a placement that is only about the few beside it; so the fade reaches a
    /// quarter of the window and falls to nothing. On an untidy one a match is news wherever it is, so
    /// the fade reaches most of the window and never goes below a trace.
    ///
    /// In proportion to the window rather than in points, so zooming out does not dim the marks on a
    /// board that has not changed.
    private static func fade(distance: Double, across diagonal: Double, tidiness: Double) -> Double {
        let reach = (0.75 - 0.5 * tidiness) * diagonal
        let floor = 0.15 * (1 - tidiness)
        let t = reach > 0 ? min(1, distance / reach) : 1
        return 1 - (1 - floor) * t * t * (3 - 2 * t)
    }

    /// The gap between two rectangles — zero if they touch or overlap.
    private static func distance(_ a: NSRect, _ b: NSRect) -> Double {
        hypot(max(0, a.minX - b.maxX, b.minX - a.maxX), max(0, a.minY - b.maxY, b.minY - a.maxY))
    }

    /// How much room there is between a card's `side` and the landing it faces.
    private static func clearance(_ card: NSRect, _ side: CanvasSide, _ landing: NSRect) -> Double {
        switch side {
        case .right: landing.minX - card.maxX
        case .left: card.minX - landing.maxX
        case .bottom: landing.minY - card.maxY
        case .top: card.minY - landing.maxY
        }
    }

    private static func side(_ part: CanvasSpanPart, horizontal: Bool) -> CanvasSide {
        horizontal ? (part == .lead ? .left : .right) : (part == .lead ? .top : .bottom)
    }

    /// One side of a ring and the corner at either end of it, as an open path — the ring `rect` with
    /// corner `radius` would have, for `side` only.
    private static func bracket(_ rect: NSRect, radius: Double, side: CanvasSide) -> NSBezierPath {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        // The same clamp `NSBezierPath(roundedRect:)` makes, so the piece is exactly the ring's.
        let r = CGFloat(min(radius, Double(w) / 2, Double(h) / 2))
        let path = NSBezierPath()
        switch side {
        case .left:
            path.move(to: NSPoint(x: x + r, y: y))
            path.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x, y: y + r), radius: r)
            path.line(to: NSPoint(x: x, y: y + h - r))
            path.appendArc(from: NSPoint(x: x, y: y + h), to: NSPoint(x: x + r, y: y + h), radius: r)
        case .right:
            path.move(to: NSPoint(x: x + w - r, y: y))
            path.appendArc(from: NSPoint(x: x + w, y: y), to: NSPoint(x: x + w, y: y + r), radius: r)
            path.line(to: NSPoint(x: x + w, y: y + h - r))
            path.appendArc(from: NSPoint(x: x + w, y: y + h), to: NSPoint(x: x + w - r, y: y + h),
                           radius: r)
        case .top:
            path.move(to: NSPoint(x: x, y: y + r))
            path.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + r, y: y), radius: r)
            path.line(to: NSPoint(x: x + w - r, y: y))
            path.appendArc(from: NSPoint(x: x + w, y: y), to: NSPoint(x: x + w, y: y + r), radius: r)
        case .bottom:
            path.move(to: NSPoint(x: x, y: y + h - r))
            path.appendArc(from: NSPoint(x: x, y: y + h), to: NSPoint(x: x + r, y: y + h), radius: r)
            path.line(to: NSPoint(x: x + w - r, y: y + h))
            path.appendArc(from: NSPoint(x: x + w, y: y + h), to: NSPoint(x: x + w, y: y + h - r),
                           radius: r)
        }
        return path
    }

    /// Clip every card that isn't moving out of what follows, so the ghost reads as drawn on the ground
    /// beneath them.
    ///
    /// **Beneath the cards standing still, above the ones being placed.** The outline stands off the
    /// frame it offers, so a card landing flush against another puts that ring across the neighbour's
    /// face — which reads as a mark *on* the neighbour and is plainly wrong. Under the cards is where
    /// it belongs. But not under the card in your hand: during an approach the ghost is at most a
    /// `showReach` away from it and mostly covered by it, and sizing a card down puts the offer wholly
    /// inside it. A real view below the cards would hide the offer exactly when you are steering by it.
    ///
    /// So the overlay keeps drawing it and cuts out the standing cards' shapes — the same corners the
    /// cards are drawn with. The frames (groups) are not cut out: they are ground, painted by the board
    /// under everything, and a ghost vanishing into one would hide in the one place a card can go.
    /// Only cards the marks can reach are clipped, which on a busy board is a handful rather than all.
    private func tuckBeneathStandingCards(_ ghost: Ghost, _ board: CanvasBoardView, _ scale: Double) {
        let marks = (ghost.frames + [ghost.landing] + ghost.matches.map(\.card)).map { board.viewRect($0) }
        guard var reach = marks.first else { return }
        for mark in marks.dropFirst() { reach = reach.union(mark) }
        let margin = (Self.ghostStandoff + Self.ghostWidth + Self.notchLength) / scale
        reach = reach.insetBy(dx: -margin, dy: -margin)

        for card in ghost.beneath {
            let rect = board.viewRect(card)
            guard rect.intersects(reach) else { continue }
            let corner = CanvasNodeView.cornerRadius(for: card)
            let cutout = NSBezierPath(rect: bounds.union(rect))
            cutout.append(NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner))
            cutout.windingRule = .evenOdd
            cutout.addClip()
        }
    }

    /// How far the outline stands off the frame it is offering, and how thick it is — both in **view
    /// points over the zoom**, so it is the same weight and the same distance to the eye at 30% as at
    /// 200%. Measured in canvas units it would be a smear when zoomed in and invisible when zoomed out,
    /// which is exactly backwards for something whose whole job is to be noticed without being looked
    /// at.
    private static let ghostStandoff: Double = 5
    private static let ghostWidth: Double = 5

    /// The band's strength — the outline's and every mark's, which are one material.
    private static let ghostAlpha: Double = 0.30

    /// How long a centre's notch is along the line it marks, in view points over the zoom: long enough
    /// to read as a piece of band and not a dot, short enough not to read as an edge.
    private static let notchLength: Double = 24

    /// The two tiles a drop would exchange, while a tiled view is being rearranged.
    ///
    /// Both of them, and that is the point: a swap is symmetric, and highlighting only the tile under
    /// the pointer would say "this one is the target" when what is about to happen is that these two
    /// change places. Drawn as a filled wash rather than a ring, because at tile size a ring reads as a
    /// selection and this is a preview of an action.
    private func drawSwapInFlight(_ board: CanvasBoardView, _ scale: Double) {
        guard case .swap(let from, let over)? = board.gesture, let over,
              let a = board.layout.frames[from], let b = board.layout.frames[over] else { return }
        for (id, rect) in [(from, a), (over, b)] {
            let standoff = 2 / scale
            // The tile's own corners plus the standoff, which is what keeps an offset curve parallel to
            // the one it is offset from. See `drawSelectionBounds`, which owns the argument.
            //
            // The *tile's*, not the card's: this is the one ring drawn while a tiling is up, and traced
            // at a card's single radius it would be visibly rounder than the two tiles underneath it.
            let corners = board.tileCorners(id)?.radii(inner: CanvasTiling.innerRadius,
                                                       outer: CanvasTiling.outerRadius)
                ?? .uniform(CanvasNodeView.cornerRadius(for: rect))
            let path = CanvasNodeView.path(in: board.viewRect(rect).insetBy(dx: -standoff,
                                                                           dy: -standoff),
                                           radii: corners.grown(by: standoff))
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 2 / scale
            path.stroke()
        }
    }

    /// The four dots a line is dragged from. Only in connect mode — that is the whole point of the mode:
    /// a board you are reading is cards and lines and nothing else.
    private func drawConnectionAnchors(_ board: CanvasBoardView, _ scale: Double) {
        // Nothing to wire together in a tiled view: the lines are hidden, and a dot that started a line
        // you could not see land would be an offer the mode cannot keep.
        guard board.mode.showsConnectionAnchors, !board.isTiled else { return }
        var ids = board.selection
        if let hovered = board.hovered { ids.insert(hovered) }

        let tester = board.hitTester
        for id in ids {
            guard let node = board.document.node(id: id), !node.isGroup else { continue }
            for side in CanvasSide.allCases {
                let centre = board.viewPoint(tester.anchorPoint(board.layout.frame(of: node), side))
                let radius = 4.5 / scale
                let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                                     width: radius * 2, height: radius * 2))
                NSColor.controlAccentColor.setFill()
                dot.fill()
                NSColor.windowBackgroundColor.setStroke()
                dot.lineWidth = 1.5 / scale
                dot.stroke()
            }
        }
    }

    /// The eight grips on a selected card. Groups get none: a frame is resized by its own edges, and
    /// eight squares around a 1700pt frame would be eight squares in the middle of nowhere.
    ///
    /// **Quiet.** These used to be drawn at the weight of a thing you are about to act on — a 2.5pt
    /// accent ring and eight filled squares in a 1.5pt accent stroke — which is the weight they have in
    /// a drawing tool, where shaping is the job. Here it isn't: a card is resized by its edge in either
    /// mode now, and the grips only say which card the arrow keys and the eight points belong to. So
    /// the ring is a hairline at half strength and the squares are smaller and thinner. They are still
    /// the loudest thing on a board that has them, which is why they are still a mode.
    private func drawGrips(_ board: CanvasBoardView, _ scale: Double) {
        // A tile's size is the arrangement's to decide, not yours — you resize the split instead. So no
        // grips, and no ring either: in a tiled view the tiles *are* what you are looking at, and a
        // selection ring around one of six is noise.
        guard !board.isTiled else { return }
        // In view mode a selected card answers with a shadow and nothing else — see `CanvasMode` and
        // `CanvasNodeView.refreshElevation`. It is still resizable there; a Mac window has no grips
        // either. Drawing a ring here as well would be the second answer to a question that only
        // wanted one.
        guard board.mode.showsResizeGrips else { return }
        // Nil unless several things are selected, in which case it is what the grips sit on. Asked of
        // the hit tester rather than measured here, so what is drawn and what is clickable are one
        // number.
        let box = board.hitTester.selectionBox
        for id in board.selection {
            guard let node = board.document.node(id: id), board.layout.shows(id) else { continue }
            let rect = board.viewRect(board.layout.frame(of: node))

            // A card you have stepped into gets a halo as well as a ring. The distinction it draws is
            // one you need before you click, not after: on a selected card the next click belongs to
            // the board, and on an engaged one it belongs to whatever is inside the card. A focus
            // glow is the Mac's own way of saying "this is what your input is going to".
            // The halo keeps its weight. It isn't about shaping — it says where your typing is going,
            // which is the one thing on this board worth being emphatic about.
            //
            // **Both marks take the card's own corner, and neither divides it by the zoom.** They used
            // to be fixed 11 and 9 around a card whose radius grows with it (`CanvasNodeView`
            // `cornerRadius(for:)`), so a ring was rounder than a small card and squarer than a large
            // one — two curves meant to read as one line and its outline. Dividing by the zoom is right
            // for a hairline, which should hold its weight as you zoom, and wrong for a corner, which
            // is part of the shape and has to zoom with it.
            let corner = CanvasNodeView.cornerRadius(for: board.layout.frame(of: node))
            if board.nodeViews[id]?.isEngaged == true {
                let standoff = 3.5 / scale
                let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -standoff, dy: -standoff),
                                        xRadius: corner + standoff, yRadius: corner + standoff)
                halo.lineWidth = 5 / scale
                NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                halo.stroke()
            }

            let standoff = 1 / scale
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -standoff, dy: -standoff),
                                    xRadius: corner + standoff, yRadius: corner + standoff)
            ring.lineWidth = 1.25 / scale
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            ring.stroke()

            // With several selected the grips move out to the box around them — see below — so a card
            // keeps only its ring, which is now saying "and this one" rather than "grab me here".
            guard !node.isGroup, box == nil else { continue }
            drawHandles(on: board.layout.frame(of: node), board: board, scale: scale)
        }

        // On the box itself, not on the band drawn outside it — the hit tester answers for the box,
        // and grips drawn 5 points out from where they are caught is exactly the kind of near miss
        // that makes a corner feel unreliable.
        if let box { drawHandles(on: box, board: board, scale: scale) }
    }

    /// The box several selected cards are resized by.
    ///
    /// **Out of `drawGrips`, which is why it is here at all.** It used to be drawn inside that pass,
    /// which returns early in view mode — so in view mode a multiple selection had no bounds drawn
    /// around it whatsoever, while still being resizable by exactly those bounds. You could grab an
    /// edge that was never shown to you.
    ///
    /// **The ghost's treatment, at half the weight.** A band standing off the thing it describes, in
    /// the neutral, rather than an accent hairline — the same argument as `drawGhost`, and the same
    /// standoff, so the two marks are visibly the same family. Thinner because they are not doing the
    /// same job: the ghost is transient and has one instant to be noticed, and this is persistent for
    /// as long as the selection is, which is the other end of the same trade.
    private func drawSelectionBounds(_ board: CanvasBoardView, _ scale: Double) {
        // Nothing in a tiled view: a tile's bounds are the arrangement's, not yours, and a bracket
        // around three of six tiles is a second grid drawn over the first.
        guard !board.isTiled, let box = board.hitTester.selectionBox else { return }
        let standoff = Self.boundsStandoff / scale
        let rect = board.viewRect(box).insetBy(dx: -standoff, dy: -standoff)
        // Concentric, by the same rule the ghost uses: a curve offset from another curve keeps an even
        // gap only when its radius grows by the offset. On the common case — a box hugging two cards —
        // this lands the band exactly parallel to the corner card's own curve.
        let radius = CanvasNodeView.cornerRadius(for: box) + standoff
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.boundsWidth / scale
        CanvasPalette.guide(0.28).setStroke()
        path.stroke()
    }

    /// How far the band stands off the selection, and how thick it is — in view points over the zoom,
    /// so it is the same weight to the eye at 30% as at 200%. The standoff matches the ghost's exactly
    /// and the width is half of it; see `drawSelectionBounds`.
    private static let boundsStandoff: Double = 5
    private static let boundsWidth: Double = 2.5

    /// The eight squares, wherever they belong — on a card, or on the box around a selection.
    private func drawHandles(on frame: CanvasRect, board: CanvasBoardView, scale: Double) {
        let size = 5.5 / scale
        for handle in CanvasHandle.allCases {
            let at = board.viewPoint(handle.point(in: frame))
            let box = NSRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size)
            let path = NSBezierPath(ovalIn: box)
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1 / scale
            path.stroke()
        }
    }

    /// The line being dragged out of a card, before it has anywhere to land.
    ///
    /// Dashed, and routed by the same function that routes a real one, so what you are dragging looks
    /// like what you will get. The target is a zero-sized rectangle at the pointer — a degenerate card
    /// — which lets `canvasRoute` do the work rather than this having a second, nearly-identical curve
    /// of its own.
    private func drawConnectionInFlight(_ board: CanvasBoardView, _ scale: Double) {
        guard case .connect(let id, let side, let to)? = board.gesture,
              let from = board.document.node(id: id) else { return }
        let curve = canvasRoute(from: from.frame, fromSide: side,
                                to: CanvasRect(x: to.x, y: to.y, width: 0, height: 0), toSide: nil)
        board.drawCurve(curve, color: NSColor.controlAccentColor, width: 2.2 / scale,
                        startEnd: .none, endEnd: .arrow, label: nil, dashed: true)
    }

    private func drawMarquee(_ board: CanvasBoardView, _ scale: Double) {
        guard let marquee else { return }
        let rect = board.viewRect(marquee)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1 / scale
        path.stroke()
    }
}
