import AppKit
import SwiftUI
import PmLib

/// One card on the board.
///
/// The base draws the card — its surface, its border, the wash a colour puts behind it — and holds one
/// `content` subview that the kind-specific subclasses fill in. Selection is *not* drawn here: the
/// grips and the ring live in the overlay, above every card, so a selected card that overlaps another
/// still shows its whole ring.
///
/// **A card doesn't take clicks.** `hitTest` returns nil while the card isn't taking its own, so the
/// pointer falls through to the board, which is the one place a click is interpreted — otherwise every
/// card would need its own copy of "is this a drag, a selection, or a resize?". A card becomes engaged
/// when you step into it: a text card being edited needs the caret, and a web card you have stepped
/// into needs its own clicks and its own scrolling. Clicking outside, or Escape, steps back out.
///
/// **A tiled view hands that to every tile at once** — see `takesItsOwnClicks`.
///
/// **The wheel is the exception.** A card you haven't stepped into still scrolls when the pointer is
/// over it, because reading is not stepping in — the board hands the event down instead, since a card
/// that refuses to hit-test can never be sent one by AppKit. See `scrollsItsContent`.
///
/// An engaged card doesn't take *every* click, though. The band along its edge and its `boardHandle`
/// stay the board's, so a card you have stepped into is still a card — one you can move and resize
/// without stepping out of it first.
@MainActor
class CanvasNodeView: NSView {
    unowned let board: CanvasBoardView
    private(set) var node: CanvasNode
    /// The zoom the board is at. Cards draw themselves differently when it gets small enough that
    /// their content stops being readable — see `CanvasDetail.simplifiedBelow`.
    private(set) var scale: Double

    /// True when the board is zoomed out past reading, and this card should stand for itself rather
    /// than render itself.
    var isSimplified: Bool { scale < CanvasDetail.simplifiedBelow }

    /// True once you have stepped into this card, which is when it starts taking its own clicks.
    private(set) var isEngaged = false

    /// Whether ⌘+ and ⌘− mean this card's content while you are stepped into it, rather than the board.
    ///
    /// Off by default, so a kind of card that has no answer to "how large is your text" leaves the two
    /// keys doing what they have always done. See `CanvasCardZoom`.
    var zoomsItsContent: Bool { false }

    /// How large this card's content is set, from the document.
    var contentZoom: Double { CanvasCardZoom.of(node) }

    /// The zoom changed — re-render at it. Called for a change from anywhere, including an undo and
    /// another window on the same file.
    func contentZoomChanged() {}

    init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        self.node = node
        self.board = board
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // The card casts a shadow, so this layer must *not* mask — a masked layer clips its own
        // shadow away. The content is clipped by `clip` instead, which is why every card has that
        // one extra view in it.
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        refreshElevation()

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        // Inset by the hairline the card draws, so the content is clipped to the *inside* of the
        // border rather than over it — and so the clip's corner can be concentric with the card's
        // rather than a second curve of a different radius sitting on top of the first.
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor, constant: CanvasNodeView.hairline),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CanvasNodeView.hairline),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CanvasNodeView.hairline),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CanvasNodeView.hairline),
        ])
    }

    /// Holds the card's content and rounds it off. See the shadow note in `init`.
    ///
    /// **Every card's content goes in here** — see `setContent`. It is easy to think this view is
    /// optional for cards whose content doesn't reach their corners, and for a rendered note or a
    /// summary label it very nearly is. A web card is the case that proves it isn't: a page paints an
    /// opaque background out to its own square edges, and a square white rectangle laid over a rounded
    /// white card is invisible in light appearance and obvious in dark, which is exactly the kind of
    /// bug that survives a long time.
    private let clip = FlippedClipView()

    /// The clip, flipped like everything else in a card.
    ///
    /// **It has to agree with `CanvasNodeView` about which way is up**, and until it was masked it
    /// never had to: a `cornerRadius` is the same number at all four corners, so nothing in a card
    /// noticed that this one view disagreed with its parent. A path does notice. AppKit puts an
    /// unflipped view inside a flipped one by setting `isGeometryFlipped` on its backing layer, which
    /// takes the mask's geometry with it — so a shape written with `minY` as the top arrived with its
    /// top and bottom corners swapped, and the master tile wore its soft outer corner against the
    /// divider instead of at the frame.
    ///
    /// Flipping the view rather than mirroring the path, because one convention through the whole card
    /// is a thing you can hold; two, with a flip somewhere in the middle, is the bug waiting to be
    /// reintroduced by the next person to draw into this view. Its content is positioned by
    /// constraints — see `setContent` — which don't care either way.
    private final class FlippedClipView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The card's border, and so the width the clip is inset by.
    static let hairline: Double = 1

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Build the view for a card, by what the card is.
    static func make(node: CanvasNode, board: CanvasBoardView, scale: Double) -> CanvasNodeView {
        switch node.content {
        case .text: return CanvasTextNodeView(node: node, board: board, scale: scale)
        case .file: return CanvasFileNodeView(node: node, board: board, scale: scale)
        case .link: return CanvasLinkNodeView(node: node, board: board, scale: scale)
        // Frames are painted by the board, behind everything, and never become a view — so this is
        // unreachable in practice. A plain card rather than a trap: an unexpected frame here should
        // look wrong, not take the window down.
        case .group: return CanvasNodeView(node: node, board: board, scale: scale)
        }
    }

    /// Whether a plain click steps into this card.
    ///
    /// Off for most cards, and that is the right default: a click that put a caret in every text card
    /// you touched, or opened every file card, would make the board unusable for the thing a board is
    /// mostly for, which is moving cards around and looking at them. A web card is the exception —
    /// it is a *live* thing, and a click on a live thing should reach it.
    var engagesOnClick: Bool { false }

    /// Whether the pointer resting over this card scrolls its content, without stepping in first.
    ///
    /// Off by default, and on for the cards whose content can be longer than the card is tall. It is
    /// the same rule the Mac applies to windows — the wheel goes to what is under the pointer, not to
    /// what is focused — and on a board it matters more, because a board is a *set* of things you are
    /// reading side by side and stepping into one to read it is a mode you then have to leave.
    var scrollsItsContent: Bool { false }

    /// The view a wheel over this card should be handed to, or nil when the card has nothing to scroll
    /// and the wheel is the board's. See `CanvasBoardView.scrollWheel`.
    ///
    /// Never while the board is zoomed out past reading: a simplified card is showing its name rather
    /// than its content, and a name has no length to travel through.
    var contentScroller: NSView? {
        guard scrollsItsContent, !isSimplified else { return nil }
        return CanvasNodeView.scroller(in: self)
    }

    /// The first scroll view inside a card. For the cards built out of SwiftUI this is the real
    /// `NSScrollView` that backs their `ScrollView` — searched for rather than held, because the whole
    /// of a card's content is rebuilt whenever what it is showing changes, and a reference kept across
    /// that is a reference to the view that used to be there.
    static func scroller(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView { return scroller }
        for sub in view.subviews {
            if let found = scroller(in: sub) { return found }
        }
        return nil
    }

    /// Whether a click inside this card reaches what is in it, rather than falling through to the
    /// board.
    ///
    /// On a board you earn it by stepping in, and the cost of that is the point: a board is mostly
    /// panned across and rearranged, and cards that each took their own clicks would make every one of
    /// those gestures a gamble on what was under the pointer.
    ///
    /// **A tiled view has none of that.** There is nothing to pan to, nothing to drag a card into, and
    /// no question of which card a click was meant for — the tiles are laid out edge to edge with a gap
    /// between them, and a click inside one is a click on that one. What is left is a window showing
    /// several live things at once, which is the whole reason to tile: a page you can scroll, a task
    /// you can tick, a link you can follow, in whichever tile you happen to be looking at. Making that
    /// wait for a click that "focuses" the tile first is a click charged for nothing, and it means only
    /// ever one live tile among several — see `CanvasPageBudget.liveWhileTiled`, which is the same
    /// sentence about renderers rather than about clicks.
    ///
    /// The board keeps what it needs either way. `canvasBoardKeeps` reserves the band along each tile's
    /// edge, the boundaries lie in the gaps, and the handlebar sits outside the tile it belongs to — so
    /// selecting, swapping, reordering and resizing are all still the board's, and none of them was
    /// ever aimed at the middle of a tile.
    ///
    /// **Taking the click and having the keyboard are two things**, and this is only the first. A tile
    /// whose click reached it but whose typing still went to the board could open an editor and then
    /// drop every character into it — which is what a task row on a project tile did. The second half
    /// is `CanvasBoardView.tileClicked`, which listens for these clicks without taking them and
    /// engages the tile they landed in. One tile at a time, because the keyboard is one thing.
    var takesItsOwnClicks: Bool { isEngaged || board.isTiled }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard takesItsOwnClicks else { return nil }
        let local = convert(point, from: superview)
        guard !canvasBoardKeeps(local, in: bounds, scale: board.liveScale) else { return nil }
        return super.hitTest(point)
    }

    /// Escape steps back out.
    ///
    /// The last resort rather than the mechanism: a text card's editor takes Escape itself, and this is
    /// what catches the case where the thing you stepped into doesn't — a web page, which will happily
    /// ignore the key and let it walk up the responder chain to here.
    ///
    /// A card that isn't engaged passes the key on rather than calling `super`: `cancelOperation:` is
    /// only *declared* on the standard key-binding protocol, and `NSView` doesn't implement it, so a
    /// `super` call is an unrecognized selector that takes the app down. It reaches this branch for
    /// real — a page keeps first responder for the moment between the board disengaging the card and
    /// WebKit handing the key back.
    override func cancelOperation(_ sender: Any?) {
        guard isEngaged else {
            nextResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            return
        }
        engage(false)
        window?.makeFirstResponder(board)
    }

    // MARK: Chrome

    /// The card's corner, which grows a little with the card.
    ///
    /// One fixed radius does not read as one radius. At 8pt a 220pt card has a soft corner and a 900pt
    /// card is very nearly square, so a board of cards at the sizes real boards use looks like several
    /// different kinds of object rather than one kind at several sizes. Scaling it off the card's
    /// shorter side fixes that; clamping it at both ends is what keeps a small card from becoming a
    /// lozenge and a large one from becoming a stadium.
    var cornerRadius: Double { CanvasNodeView.cornerRadius(for: node.frame) }

    /// The same rule, asked of a frame rather than of a card — the overlay draws ghosts around cards
    /// it has only the geometry of, and a ghost traced at a different radius than the card under it is
    /// visibly not that card's outline.
    static func cornerRadius(for frame: CanvasRect) -> Double {
        min(14, max(8, min(frame.width, frame.height) * 0.025))
    }

    /// The corners this view is drawn with: one radius on a board, two in a tiled view.
    ///
    /// Asked of the board rather than stored, because the answer changes when the *arrangement* changes
    /// and not when this card does — a tile dragged from the end of a stack to the middle keeps
    /// everything about itself and loses two outer corners.
    var chromeRadii: CanvasTiling.Radii {
        let card = CanvasTiling.Radii.uniform(cornerRadius)
        guard let tile = tileRadii else { return card }
        return CanvasTiling.Radii.mix(card, tile, at: board.tiledness)
    }

    /// The corners a tile would have, or nil for a card that is not one and is not on its way back from
    /// being one.
    ///
    /// **Remembered, because the mode flips before the paint does.** `leaveTiling` clears the session in
    /// the frame you press the key — the board is a board again to every command in the app from that
    /// moment — and `tileCorners` has nothing to answer with a moment later, while the corners are still
    /// half way home. Held here rather than on the board because it is a per-card fact, and because the
    /// card that keeps it is exactly the card that needs it.
    private var tileRadii: CanvasTiling.Radii? {
        if let corners = board.tileCorners(node.id) {
            let radii = corners.radii(inner: CanvasTiling.innerRadius, outer: CanvasTiling.outerRadius)
            lastTileRadii = radii
            return radii
        }
        // Only while the crossing is still being drawn. A settled board has no tile corners and must
        // not go on carrying a set: the next tiling may give this card different ones.
        guard board.tiledness > 0.001 else {
            lastTileRadii = nil
            return nil
        }
        return lastTileRadii
    }

    private var lastTileRadii: CanvasTiling.Radii?

    /// The hairline this view wears. See `CanvasPalette.tileBorderKey` for why a tiled view says
    /// "this one" with its edge where a board says it with height.
    ///
    /// Mixed across the crossing like everything else here. The key/quiet choice is made at the tile
    /// end only — a card's hairline does not have that distinction to make, because on a board being
    /// picked is said with height.
    private var chromeBorder: NSColor {
        let tile = isKey ? CanvasPalette.tileBorderKey : CanvasPalette.tileBorder
        return CanvasPalette.hairline(card: CanvasPalette.cardBorder, tile: tile,
                                      at: borderCrossing)
    }

    /// Whether this is the tile the arrows and Return are about. Only ever asked at the tile end —
    /// see `chromeBorder`, and `CanvasPalette.tileBorderKey` for why the edge is what answers there.
    private var isKey: Bool { isEngaged || board.selection.contains(node.id) }

    /// How far *this card* is across, which is not the same as how far the board is.
    ///
    /// **A card the workspace does not show is not becoming a tile**, and it used to be drawn half as
    /// though it were. `chromeRadii` asks `tileRadii` first, so those cards keep a card's corners the
    /// whole way across; `chromeBorder` asked the board's `tiledness` outright and crossed their
    /// hairlines to a tile's. Two answers about one card, and the corners had the right one.
    ///
    /// They agree now, and the agreement is what makes a crossing cheap. A card that is merely fading
    /// stops depending on `tiledness` for anything it paints — same corners, same hairline, only the
    /// alpha moving — so there is nothing for it to redraw on any of the twenty frames, and
    /// `refreshChrome` can *see* that there isn't. See `CanvasBoardView.tilednessChanged`, which asks
    /// every card on the board to reconsider itself on every one of those frames.
    ///
    /// Worth saying plainly what the change looks like: the hairline being crossed goes from alpha
    /// 0.10 to 0.017, on a card that is itself on its way to alpha 0. What is given up is one of two
    /// indistinguishable pictures.
    private var borderCrossing: Double { tileRadii == nil ? 0 : board.tiledness }

    /// The board crossed a little further between its two modes. Everything drawn against `tiledness`
    /// is reconsidered; the shadow, which is a layer property rather than paint, is set rather than
    /// drawn. Nothing is written that has not moved — see below, and `refreshChrome`.
    ///
    /// `fading` is for the cards a workspace is not showing: they are still on the board, so they go out
    /// as the tiles come in rather than disappearing in the frame the key was pressed. See
    /// `CanvasBoardView.fadingCards`.
    func refreshTiledness(fading: Bool) {
        let wanted = CGFloat(fading ? 1 - board.tiledness : 1)
        let moved = abs(wanted - alphaValue) > 0.0005
        // **Nothing is written that has not moved.** This used to set all four outright, which on a
        // board of forty-three cards is forty-three full repaints and forty-three layout passes per
        // frame, in service of the six that are actually changing. Alpha is a layer property and
        // assigning it marks the layer for recompositing whether or not the number differs; a tile
        // sits at 1 for the whole crossing, and a card that has finished fading sits at 0.
        if moved { alphaValue = wanted }
        // A card that is invisible and staying invisible has nothing left to say. Barely worth it
        // during the crossing itself — a card is only hidden once its alpha has reached zero, which is
        // the last frame — but this is also the path `CanvasBoardView.layoutNodeViews` takes, and in a
        // settled workspace that runs for every card on the board on every frame of a divider drag,
        // with the thirty-seven the workspace is not showing hidden at zero the whole time.
        guard moved || !isHidden else { return }
        refreshElevation()
    }

    /// What this view's paint is a function of.
    ///
    /// All three move for a tile, and none of them move for a card the workspace is not showing — see
    /// `borderCrossing`, which is what makes that true. Held together so that one comparison can answer
    /// "is there anything to redraw", which is a question asked of every card on every frame.
    private struct Appearance: Equatable {
        var radii: CanvasTiling.Radii
        var key: Bool
        var crossing: Double
    }

    /// What this view was last told to wear, so an arrangement that reshaped one tile doesn't repaint
    /// the other five — and so a crossing repaints the tiles rather than the board.
    private var drawn: Appearance?

    /// The layout, the selection or the crossing changed and may have changed this view's paint with
    /// it. Called for every card on every pass of `CanvasBoardView.layoutNodeViews` and on every frame
    /// of a crossing, so the cheap answer has to be the common one.
    func refreshChrome() {
        let crossing = borderCrossing
        // Off a tile, `chromeBorder` resolves to `cardBorder` whatever this says — being picked is said
        // with height on a board, not with the edge — so it is held out of the comparison rather than
        // invalidating every card in the selection for a change it cannot show. See `refreshElevation`.
        let now = Appearance(radii: chromeRadii, key: crossing > 0 && isKey, crossing: crossing)
        guard now != drawn else { return }
        drawn = now
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        FrameMeter.span("cardDraw") { drawBody() }
    }

    private func drawBody() {
        let path = CanvasNodeView.path(in: bounds.insetBy(dx: 0.5, dy: 0.5),
                                       radii: chromeRadii.inset(by: 0.5))
        CanvasPalette.card.setFill()
        path.fill()
        chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A rounded rectangle whose four corners can differ.
    ///
    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` takes one radius, and `CALayer` takes one radius
    /// and a set of corners to apply it to, so neither can draw a tile that is tight against its
    /// neighbours and soft at the frame. Tangent arcs can: each one is "come in along this edge, turn
    /// towards the next corner with this radius", which is the corner as it is actually specified.
    ///
    /// **Clockwise from the top left, in a flipped view** — every caller here draws in one, so `minY`
    /// is the top and `Radii.topLeft` belongs to `(minX, minY)`.
    static func path(in rect: NSRect, radii: CanvasTiling.Radii) -> NSBezierPath {
        let path = NSBezierPath()
        let topLeft = NSPoint(x: rect.minX, y: rect.minY)
        let topRight = NSPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = NSPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = NSPoint(x: rect.minX, y: rect.maxY)
        // A radius larger than half the side it turns on would overshoot the corner after it; AppKit
        // clamps silently and the shape stops being symmetric. A tile squeezed to `minimumTile` is
        // 64pt and the largest radius here is 9, so this only ever bites on a degenerate frame.
        let limit = min(rect.width, rect.height) / 2
        func hold(_ radius: Double) -> CGFloat { CGFloat(max(0, min(radius, limit))) }

        path.move(to: NSPoint(x: rect.minX + hold(radii.topLeft), y: rect.minY))
        path.appendArc(from: topRight, to: bottomRight, radius: hold(radii.topRight))
        path.appendArc(from: bottomRight, to: bottomLeft, radius: hold(radii.bottomRight))
        path.appendArc(from: bottomLeft, to: topLeft, radius: hold(radii.bottomLeft))
        path.appendArc(from: topLeft, to: topRight, radius: hold(radii.topLeft))
        path.close()
        return path
    }

    /// The corner and the shadow both follow the card's size, so both are set where a size change is
    /// actually reported.
    ///
    /// In `layout` rather than `updateLayer`: a view that implements `draw(_:)` has `wantsUpdateLayer`
    /// false, so AppKit never calls `updateLayer` at all and everything that was in it was being set
    /// exactly never. The shadow came out right regardless — with no `shadowPath` the layer derives one
    /// from the alpha of what was drawn into it, which is the rounded card — but the corner radius on
    /// the clip did not, and it is the one that has to change now.
    override func layout() {
        FrameMeter.span("cardLayout") { layoutBody() }
    }

    private func layoutBody() {
        super.layout()
        let radii = chromeRadii
        // **Everything below is a function of these two**, and both of the paths it builds are four
        // tangent arcs turned into a `CGPath` — an allocation each. `layout` runs on every frame of a
        // divider drag, and `refreshTiledness` used to ask for one on every frame of a crossing for
        // every card on the board, almost all of which were neither resizing nor reshaping. A card
        // whose size and corners have not moved keeps the paths it already has.
        let shape = Shape(bounds: bounds, radii: radii)
        guard shape != shaped else { return }
        shaped = shape
        // Concentric: a curve inset from another curve keeps a constant gap only when its radius is
        // reduced by that inset. Equal radii would leave the border pinching shut at the corners.
        let inside = radii.inset(by: CanvasNodeView.hairline)

        if radii.isUniform {
            // A card, and the cheap path: the layer rounds itself, keeps `.continuous` — which a mask
            // cut from a path cannot have — and costs nothing to resize.
            clip.layer?.mask = nil
            clipMask = nil
            clip.layer?.cornerRadius = inside.topLeft
        } else {
            // A tile with a seam on one side and the frame on the other. `cornerRadius` is one number
            // and `maskedCorners` only turns that one number on and off, so the only way to hold two
            // radii at once is to cut the shape out of the clip.
            clip.layer?.cornerRadius = 0
            let mask = clipMask ?? CAShapeLayer()
            clipMask = mask
            mask.frame = clip.bounds
            mask.path = CanvasNodeView.path(in: clip.bounds, radii: inside).cgPath
            if clip.layer?.mask !== mask { clip.layer?.mask = mask }
        }

        // Inert while `masksToBounds` is false and `shadowPath` is explicit — both true here — but kept
        // in step so nothing that starts reading it later finds a stale number.
        layer?.cornerRadius = radii.topLeft
        // Given explicitly so the shadow follows the card's own corner rather than being inferred, and
        // so it is right on the frame the card is resized to rather than the frame it was drawn at.
        layer?.shadowPath = CanvasNodeView.path(in: bounds, radii: radii).cgPath
    }

    /// The shape cut out of `clip` when the four corners don't agree. Held so a resize can move one
    /// layer rather than build one — `layout` runs on every frame of a divider drag.
    private var clipMask: CAShapeLayer?

    /// The size and corners the paths in `layout` were built for. `clip` is pinned to this view by
    /// constraints with a constant inset, so its bounds are a function of these and need not be kept.
    private struct Shape: Equatable {
        var bounds: NSRect
        var radii: CanvasTiling.Radii
    }

    private var shaped: Shape?

    // MARK: Lifecycle the board drives

    /// The card, or the zoom, changed. Subclasses re-render whatever depends on either.
    ///
    /// Rebuilt only when something actually changed, and crossing the simplification threshold counts:
    /// it is the difference between a card holding a markdown layout and a card holding one label, and
    /// a scroll that crossed it without rebuilding would leave every visible card in the wrong form.
    func update(node: CanvasNode, scale: Double) {
        let wasSimplified = isSimplified
        let sameNode = node == self.node
        self.scale = scale
        let changed = node.content != self.node.content && !isOwnEdit(node.content)
        let rezoomed = CanvasCardZoom.of(node) != contentZoom
        self.node = node
        if changed {
            // A rebuild sets the zoom on the way through, so there is nothing further to do for it.
            contentChanged()
        } else if rezoomed {
            contentZoomChanged()
        } else if wasSimplified != isSimplified {
            simplificationChanged()
        } else if sameNode {
            // **Nothing about this card moved, so nothing about it is redrawn.** This used to fall
            // through to the two lines below whatever it had been handed, which is fine for the pass
            // that follows an edit and ruinous for the pass that follows a *zoom*: the board is rebuilt
            // on every frame of a flight (`CanvasScrollView.centre(on:)`), so entering a workspace ran
            // this for all forty-three cards a dozen times, and every one of those invalidated a card
            // that was drawing exactly what it had been drawing. Measured at a dozen full rebuilds
            // inside a 350ms crossing.
            //
            // The scale is still taken, above — `isSimplified` is read from it and a card that crosses
            // that threshold is caught by the branch before this one. Nothing else this view paints is
            // a function of the zoom.
            return
        }
        refreshAccessibility()
        needsDisplay = true
    }

    /// Whether content arriving from the document is this card's own edit coming back.
    ///
    /// The store tells its watchers inside `change`, so a card that writes what you type into the
    /// document is handed that text straight back — as a node whose content is genuinely different
    /// from the one this view was built with. For every card that didn't make the edit that is the
    /// truth and a rebuild is right. For the card you are typing in it is a rebuild of the view the
    /// keystroke was typed into, which is a very different thing. See `CanvasTextNodeView.isOwnEdit`.
    func isOwnEdit(_ content: CanvasContent) -> Bool { false }

    /// The board crossed `CanvasDetail.simplifiedBelow` in one direction or the other.
    ///
    /// Rebuild, for a card whose two forms are built by `contentChanged`. Separate from a content
    /// change because it isn't one, and because a card can have its own answer: a web card keeps its
    /// own threshold and must *not* rebuild here — tearing the page down and putting it back is a
    /// reload, and reloading a page you are reading because you nudged the zoom is not a redraw.
    func simplificationChanged() { contentChanged() }

    /// One line, drawn as large as the card can hold — what a card looks like when the board is too
    /// far out to read it.
    ///
    /// Sized against the zoom so it comes out at a constant size on screen, then clamped by the card's
    /// own height so a short card doesn't get a line of text taller than it is. Truncated rather than
    /// wrapped past two lines: the point is to be identifiable at a glance, and the third line of a
    /// summary is not what identifies it.
    func summaryView(_ text: String, symbol: String? = nil) -> NSView {
        let size = min(15 / scale, node.frame.height * 0.5)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: .medium)
        label.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true

        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.spacing = size * 0.35
        stack.alignment = .centerX

        if let symbol {
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            glyph.symbolConfiguration = .init(pointSize: size * 1.3, weight: .regular)
            glyph.contentTintColor = .secondaryLabelColor
            stack.insertArrangedSubview(glyph, at: 0)
        }

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor,
                                         constant: -size * 0.8),
        ])
        return container
    }

    /// The card's own content changed — reload it.
    func contentChanged() {}

    /// Say what this card is, to VoiceOver.
    ///
    /// A board is a field of unlabelled rectangles otherwise. The description a card already writes for
    /// the header is the same sentence VoiceOver wants — what the card is and anything unusual about it
    /// — so there is one answer rather than two that can disagree. Cards that have no description fall
    /// back to what they hold, which for a text card is its text and for a web card its host.
    ///
    /// Refreshed wherever the description is, because a page that has navigated is a card that has
    /// stopped being what it said it was.
    func refreshAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(cardDescription ?? accessibilityFallback)
        setAccessibilityElement(true)
    }

    /// What to say for a card with nothing to add — overridden where the content knows better.
    var accessibilityFallback: String { "Card" }

    /// What this card would say about itself if asked, or nil for a card that says everything it has to
    /// say by being looked at.
    ///
    /// Cards carry no chrome: no strip naming the file, no capsule over the page saying how old it is.
    /// **Nor a tooltip**, and once there was one. A tooltip that appears a second after the pointer
    /// stops is a caption on whatever your pointer happened to cross on the way somewhere else — on a
    /// board, where the pointer crosses several cards to reach one, that is a caption you did not ask
    /// for over the card you were not going to. The facts are still worth having, and the two places
    /// that ask are the header, which says them for the card you have actually stepped into, and
    /// VoiceOver, which is asking for exactly this sentence anyway. See `refreshAccessibility` and
    /// `CanvasHeaderModel`.
    var cardDescription: String? { nil }

    /// Step into this card: a text card takes the caret, a web card takes its own scrolling.
    func beginEditing() {
        engage(true)
    }

    /// Called when the board's selection changes and this card was in it, or now is.
    func selectionChanged() {
        if isEngaged && !board.selection.contains(node.id) { engage(false) }
        refreshElevation()
    }

    /// How far off the board this card is sitting.
    ///
    /// In view mode this is the *whole* of a card's answer to being picked: a key shadow, deeper again
    /// once you have stepped into it. Not a ring, because a ring is the vocabulary of a thing about to
    /// be edited — it exists to hold the grips — and on a board you are reading, selecting a card is a
    /// step towards using it. Height reads as "this one, in front" without claiming anything about
    /// what you are going to do to it, and it is the same signal a Mac uses for the window you are in.
    ///
    /// Edit mode keeps every card flat and lets the ring and grips do the talking, so that the two
    /// vocabularies never run at once.
    func refreshElevation() {
        let picked = board.selection.contains(node.id)
        let lift: (opacity: Float, radius: Double, drop: Double)
        // **A tiled view has no height at all**, and that is the mode's whole claim: a tile is a pane
        // let into the ground rather than paper on it, and paper is the only thing that casts a shadow.
        // It used to answer with height whatever the mode was, on the grounds that the ring and the
        // grips are gone in a tiling — a tile's size isn't yours to set — so height was all that was
        // left to say which tile the arrows and Return are about. The edge says it now, which is a
        // thing a pane can do; see `CanvasPalette.tileBorderKey`.
        //
        // Redrawn as well as re-lifted, because in a tiling the answer is *in* the drawing. Asked of
        // `refreshChrome` rather than set outright: a tiled board used to redraw every card here on
        // every frame of a crossing, and the edge this is about only changes when the key tile does.
        defer { refreshChrome() }
        switch (board.mode, picked, isEngaged) {
        case (.view, _, true): lift = (0.30, 17, 7)
        case (.view, true, _): lift = (0.22, 11, 4)
        default: lift = (0.13, 5, 1.5)
        }
        // **The height is spent as the board crosses**, rather than switched off with the mode. Nothing
        // else here is scaled by `tiledness`: the radius and the hairline are mixed between two values,
        // and this one has only the one value and no tile end to mix towards — a tile has no shadow at
        // all, which is the mode's whole claim.
        //
        // Written only when it moves, for the reason `refreshTiledness` guards its alpha: the opacity
        // genuinely travels on every frame of a crossing, and the radius and the offset never do.
        let wanted = Lift(opacity: lift.opacity * Float(1 - board.tiledness),
                          radius: lift.radius, drop: lift.drop)
        guard wanted != lifted else { return }
        lifted = wanted
        layer?.shadowOpacity = wanted.opacity
        layer?.shadowRadius = wanted.radius
        // **Positive is down here.** A card sits in a flipped superview — `CanvasBoardView.isFlipped` —
        // and AppKit places a layer inside one by flipping the backing layer's geometry, which takes
        // the shadow offset with it. So the negative height that means "down" on an ordinary layer cast
        // every card's shadow upwards, and a board of cards was lit from below.
        //
        // The superview's flippedness is what decides, not this view's own; `CanvasNoticeBar` is
        // flipped too and its shadow is spelled the other way round, correctly. See
        // `FlippedShadowTests`, which asserts all three cases against AppKit rather than against us.
        layer?.shadowOffset = CGSize(width: 0, height: wanted.drop)
    }

    /// The height this card was last set to. See `refreshElevation`, which is called for every card on
    /// the board on every frame of a crossing and on every change of selection.
    private struct Lift: Equatable {
        var opacity: Float
        var radius: Double
        var drop: Double
    }

    private var lifted: Lift?

    /// About to be thrown away because it scrolled out of view. A web card stops loading here.
    func prepareForRemoval() {}

    // MARK: The page budget

    /// Whether this card runs something the board's page budget governs. Only web cards do.
    var isPageCard: Bool { false }

    /// Whether the card is ready to run a page — see `CanvasPageBudget.Candidate.wantsPage`. A card
    /// only ever *asks*; the board decides, because the answer is a comparison between cards.
    var wantsPage: Bool { false }

    /// The board's answer. Live means run; not live means freeze, keeping a picture of the page.
    func setPageLive(_ live: Bool) {}

    /// When this card was last in the window, which is how the budget decides who gives up a slot
    /// first. Kept by the board — see `applyPageBudget`.
    var lastVisibleAt = Date.distantPast

    /// The board's heartbeat, while it has pages running. A card that says how old what it is showing
    /// is has to be told that time has passed; nothing else about it changed.
    func timePassed() {}

    func engage(_ engaged: Bool) {
        guard engaged != isEngaged else { return }
        isEngaged = engaged
        // The ring around an engaged card is drawn differently — see `drawGrips`. It lives in the
        // overlay, so the card can't redraw it by redrawing itself.
        board.overlay.needsDisplay = true
        refreshElevation()
        engagementChanged()
        board.pageStateChanged()
    }

    func engagementChanged() {}

    /// Put `view` in the card, filling it.
    ///
    /// Into `clip`, not into the card. This used to clear *all* of the card's subviews and add the
    /// content beside them, which threw the clip away on the first call and left every card's content
    /// unclipped for the rest of its life — invisible for content that stops short of the corners, and
    /// a set of square corners on a rounded card for content that doesn't.
    ///
    /// `insets` are still measured from the card's own edge, as the call sites read them; the hairline
    /// the clip is already inset by is taken off here.
    func setContent(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)) {
        clip.subviews.forEach { $0.removeFromSuperview() }
        let hairline = CanvasNodeView.hairline
        view.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: clip.topAnchor, constant: insets.top - hairline),
            view.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: insets.left - hairline),
            view.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -(insets.right - hairline)),
            view.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -(insets.bottom - hairline)),
        ])
    }
}

// MARK: - Text

/// A card of markdown, typed straight onto the board.
///
/// Read with `RenderedNote` and written with `MarkdownTextEditor` — the same two the project window
/// uses for a session note, deliberately and not as a convenience. It means `[[…]]` completion, the
/// token drawing, and pasting an image all work on a canvas without a second implementation, and it
/// means a `[[Project]]` written on a board navigates exactly as it does in a note.
@MainActor
final class CanvasTextNodeView: CanvasNodeView {
    private var hosting: NSView?

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        super.init(node: node, board: board, scale: scale)
        contentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var text: String {
        if case .text(let value) = node.content { return value }
        return ""
    }

    override var accessibilityFallback: String {
        text.isEmpty ? "Empty card" : canvasCardSummary(text)
    }

    override func contentChanged() {
        if isEngaged { return showEditor() }
        if isSimplified { return setContent(summaryView(canvasCardSummary(text))) }
        showRendered()
    }

    override var scrollsItsContent: Bool { true }

    /// A card of prose is set at one size whatever size the card is, so "make this bigger" has nowhere
    /// else to go — resizing the card rewraps the same 13pt text into a larger rectangle. See
    /// `CanvasCardZoom`.
    override var zoomsItsContent: Bool { true }

    /// Rebuilt rather than adjusted: the face is handed to SwiftUI when the view is made, and the whole
    /// card is one hosting view whose only input is the text and the font.
    override func contentZoomChanged() { contentChanged() }

    /// The editing session you are in, while you are in one — the rules of which are
    /// `CanvasCardEditing`, so that they can be asked without a board and a window to ask them in.
    private var editing: CanvasCardEditing?

    override func isOwnEdit(_ content: CanvasContent) -> Bool { editing?.echoes(content) ?? false }

    /// ⌘Z while you are typing in this card, which is the editor's own stack and not the board's.
    ///
    /// **A text view registers its undo where the responder chain says**, and the chain says the
    /// window, and this window says the canvas document — so every keystroke used to land on the
    /// stack that ⌘Z uses to take back a card you moved, twice over: once as the text view's own
    /// typing undo and once as a whole-document snapshot named "Edit Card". Undoing then replaced the
    /// document, which rebuilt the editor, which left every typing undo still on the stack pointing at
    /// a text view that no longer existed.
    ///
    /// One stack per editor rather than per session, because these registrations belong to the text
    /// view they were made in: an editor rebuilt underneath you — an outside edit, an undo of
    /// something else — is a new text view, and the old stack is so much dead weight.
    ///
    /// What the *document* gets is one step for the whole session, registered when you step out. See
    /// `CanvasDocumentStore.registerEdit`.
    private(set) var editingUndo: UndoManager?

    override func engagementChanged() {
        if isEngaged {
            editing = CanvasCardEditing(opening: text)
            contentChanged()
            window?.makeFirstResponder(hosting)
            return
        }

        // Stepping out ends the session: the editor's undo stack goes with the editor, and what the
        // session did is already one step the *document* can undo — registered by the first keystroke,
        // see `CanvasCardEditing.hasWritten`. All that is left is whether this was ever a card.
        let session = editing
        editing = nil
        editingUndo = nil

        if session?.stepOut(showing: text) == .discardTheCard {
            let id = node.id
            board.store.changeQuietly { doc in
                doc.nodes.removeAll { $0.id == id }
                doc.edges.removeAll { $0.fromNode == id || $0.toNode == id }
            }
            return
        }
        contentChanged()
    }

    private func showRendered() {
        let view = NSHostingView(rootView:
            ScrollView(.vertical) {
                RenderedNote(prose: text,
                             font: .systemFont(ofSize: 13 * contentZoom),
                             noteURL: board.store.url,
                             maxImageHeight: 400)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        view.setAccessibilityLabel(text.isEmpty ? "Empty card" : text)
        hosting = view
        setContent(view)
    }

    private func showEditor() {
        let id = node.id
        let undo = UndoManager()
        editingUndo = undo
        // What is about to be on screen came from the document, so this session has nothing
        // outstanding for the document to be echoing back. See `CanvasCardEditing.editorBuilt`.
        editing?.editorBuilt()
        let view = NSHostingView(rootView:
            CanvasTextEditing(text: text, zoom: contentZoom, undoManager: undo) { [weak self] edited in
                guard let self else { return }
                let write = { (doc: inout CanvasDocument) in
                    guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
                    doc.nodes[index].content = .text(edited)
                }
                // The first keystroke of a session is the document's one step; every one after it is
                // the editor's own, and goes in quietly. See `CanvasCardEditing.hasWritten`.
                let opensTheEdit = editing?.hasWritten == false
                // Told before the change, not after: the store notifies inside `change`, so the answer
                // to "is this mine?" has to be in place by the time it comes back to us.
                editing?.wrote(edited)
                if opensTheEdit {
                    board.store.change("Edit Card", write)
                } else {
                    board.store.changeQuietly(write)
                }
            } onDone: { [weak self] in
                self?.engage(false)
            } onOpenProject: { folder in
                WindowManager.shared.open(named: folder)
            })
        hosting = view
        setContent(view, insets: NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6))
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(view)
        }
    }
}

/// The SwiftUI shim that lets an AppKit card host the app's markdown editor.
///
/// `MarkdownTextEditor` takes a `Binding`, because every other place it is used is SwiftUI. Rather
/// than give it a second, AppKit-shaped initialiser, this holds the state and reports every change
/// outward — so the editor keeps exactly one interface and the card keeps the document as the single
/// source of truth.
private struct CanvasTextEditing: View {
    @State private var text: String
    let zoom: Double
    let undoManager: UndoManager
    let onChange: (String) -> Void
    let onDone: () -> Void
    let onOpenProject: (String) -> Void

    init(text: String,
         zoom: Double,
         undoManager: UndoManager,
         onChange: @escaping (String) -> Void,
         onDone: @escaping () -> Void,
         onOpenProject: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.zoom = zoom
        self.undoManager = undoManager
        self.onChange = onChange
        self.onDone = onDone
        self.onOpenProject = onOpenProject
    }

    var body: some View {
        var editor = MarkdownTextEditor(onOpenProject: onOpenProject,
                                        text: $text,
                                        onSubmit: onDone,
                                        onCancel: onDone)
        // The same zoom the rendered card is showing. A card whose prose grew when you zoomed it and
        // shrank back the moment you stepped in to edit it would be zooming the picture of the text
        // rather than the text.
        editor.baseFont = NSFont.monospacedSystemFont(ofSize: 13 * zoom, weight: .regular)
        // The card's stack, not the window's — see `CanvasTextNodeView.editingUndo`.
        editor.undoManager = undoManager
        return editor.onChange(of: text) { _, edited in onChange(edited) }
    }
}
