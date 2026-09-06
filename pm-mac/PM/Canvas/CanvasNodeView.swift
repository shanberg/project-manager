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
/// **A card doesn't take clicks.** `hitTest` returns nil while `isEngaged` is false, so the pointer
/// falls through to the board, which is the one place a click is interpreted — otherwise every card
/// would need its own copy of "is this a drag, a selection, or a resize?". A card becomes engaged when
/// you step into it: a text card being edited needs the caret, and a web card you have stepped into
/// needs its own clicks and its own scrolling. Clicking outside, or Escape, steps back out.
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
    private let clip = NSView()

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEngaged else { return nil }
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

    override func draw(_ dirty: NSRect) {
        let radius = cornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        CanvasPalette.card.setFill()
        path.fill()
        CanvasPalette.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
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
        super.layout()
        let radius = cornerRadius
        // Concentric: a curve inset from another curve keeps a constant gap only when its radius is
        // reduced by that inset. Equal radii would leave the border pinching shut at the corners.
        clip.layer?.cornerRadius = max(0, radius - CanvasNodeView.hairline)
        layer?.cornerRadius = radius
        // Given explicitly so the shadow follows the card's own corner rather than being inferred, and
        // so it is right on the frame the card is resized to rather than the frame it was drawn at.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                                   transform: nil)
    }

    // MARK: Lifecycle the board drives

    /// The card, or the zoom, changed. Subclasses re-render whatever depends on either.
    ///
    /// Rebuilt only when something actually changed, and crossing the simplification threshold counts:
    /// it is the difference between a card holding a markdown layout and a card holding one label, and
    /// a scroll that crossed it without rebuilding would leave every visible card in the wrong form.
    func update(node: CanvasNode, scale: Double) {
        let wasSimplified = isSimplified
        self.scale = scale
        let changed = node.content != self.node.content
        let rezoomed = CanvasCardZoom.of(node) != contentZoom
        self.node = node
        if changed {
            // A rebuild sets the zoom on the way through, so there is nothing further to do for it.
            contentChanged()
        } else if rezoomed {
            contentZoomChanged()
        } else if wasSimplified != isSimplified {
            simplificationChanged()
        }
        refreshAccessibility()
        needsDisplay = true
    }

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
    /// its tooltip is the same sentence VoiceOver wants — what the card is and anything unusual about it
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

    /// What this card says about itself when the pointer rests on it, or nil for a card that says
    /// everything it has to say by being looked at.
    ///
    /// Cards carry no chrome: no strip naming the file, no capsule over the page saying how old it is.
    /// The facts those carried are still worth having occasionally, and a tooltip is what macOS offers
    /// for exactly that shape of fact — free until asked for, and asked for by lingering rather than by
    /// clicking. Answered by the *board*, which is the view actually under the pointer: an unengaged
    /// card returns nil from `hitTest`, so it never sees the mouse and could not own a tooltip if it
    /// wanted one. See `CanvasBoardView.hovered`.
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
        // A tiled view answers with height whatever the mode is. The ring and the grips are gone there —
        // a tile's size isn't yours to set — so height is all that is left to say which tile the arrows
        // and Return are about, and a tiled board in connect mode would otherwise say nothing at all.
        switch (board.isTiled ? .view : board.mode, picked, isEngaged) {
        case (.view, _, true): lift = (0.30, 17, 7)
        case (.view, true, _): lift = (0.22, 11, 4)
        default: lift = (0.13, 5, 1.5)
        }
        layer?.shadowOpacity = lift.opacity
        layer?.shadowRadius = lift.radius
        layer?.shadowOffset = CGSize(width: 0, height: -lift.drop)
    }

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

    /// Whether the card had nothing in it when you opened it. See `engagementChanged`.
    private var openedEmpty = false

    override func engagementChanged() {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEngaged {
            openedEmpty = empty
            contentChanged()
            window?.makeFirstResponder(hosting)
            return
        }

        // A card you opened empty, typed nothing into, and clicked away from was never a card —
        // otherwise a board accumulates an empty rectangle every time a double-click lands somewhere
        // you didn't mean. Obsidian does the same.
        //
        // Only when it was *already* empty on the way in. A card whose text you deliberately cleared
        // is a card you emptied, and deleting it would take with it something ⌘Z can no longer bring
        // back — the edits that emptied it would restore the text into a card that no longer exists.
        if empty && openedEmpty {
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
        let view = NSHostingView(rootView:
            CanvasTextEditing(text: text, zoom: contentZoom) { [weak self] edited in
                self?.board.store.change("Edit Card") { doc in
                    guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
                    doc.nodes[index].content = .text(edited)
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
    let onChange: (String) -> Void
    let onDone: () -> Void
    let onOpenProject: (String) -> Void

    init(text: String,
         zoom: Double,
         onChange: @escaping (String) -> Void,
         onDone: @escaping () -> Void,
         onOpenProject: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.zoom = zoom
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
        return editor.onChange(of: text) { _, edited in onChange(edited) }
    }
}
