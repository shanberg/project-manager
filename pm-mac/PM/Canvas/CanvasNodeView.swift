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
        clip.layer?.cornerRadius = 8
        clip.layer?.cornerCurve = .continuous
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Holds the card's content and rounds it off. See the shadow note in `init`.
    private let clip = NSView()

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

    /// A part of an engaged card that still belongs to the board — a web card's caption, which stays a
    /// drag handle after the page underneath has started taking clicks.
    var boardHandle: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEngaged else { return nil }
        let local = convert(point, from: superview)
        let handle = boardHandle?.superview == nil ? nil
            : boardHandle.map { $0.convert($0.bounds, to: self) }
        guard !canvasBoardKeeps(local, in: bounds, handle: handle, scale: board.liveScale)
        else { return nil }
        return super.hitTest(point)
    }

    /// Escape steps back out.
    ///
    /// The last resort rather than the mechanism: a text card's editor takes Escape itself, and this is
    /// what catches the case where the thing you stepped into doesn't — a web page, which will happily
    /// ignore the key and let it walk up the responder chain to here.
    override func cancelOperation(_ sender: Any?) {
        guard isEngaged else { return super.cancelOperation(sender) }
        engage(false)
        window?.makeFirstResponder(board)
    }

    // MARK: Chrome

    override func draw(_ dirty: NSRect) {
        let radius = 8.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        CanvasPalette.card.setFill()
        path.fill()
        if CanvasPalette.color(node.color) != nil {
            CanvasPalette.wash(node.color).setFill()
            path.fill()
        }
        CanvasPalette.border(node.color).setStroke()
        path.lineWidth = CanvasPalette.color(node.color) != nil ? 1.6 : 1
        path.stroke()
    }

    override func updateLayer() {
        layer?.cornerRadius = 8
        // Redrawn each time so the shadow follows the card's own corner rather than its square frame,
        // which is what a shadow on a masksToBounds-off layer would otherwise use.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
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
        let changed = node.content != self.node.content || node.color != self.node.color
        self.node = node
        if changed {
            contentChanged()
        } else if wasSimplified != isSimplified {
            simplificationChanged()
        }
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
        switch (board.mode, picked, isEngaged) {
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
    func setContent(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)) {
        subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
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

    override func contentChanged() {
        if isEngaged { return showEditor() }
        if isSimplified { return setContent(summaryView(canvasCardSummary(text))) }
        showRendered()
    }

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
                             font: .systemFont(ofSize: 13),
                             noteURL: board.store.url,
                             maxImageHeight: 400)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(true)
        )
        view.setAccessibilityLabel(text.isEmpty ? "Empty card" : text)
        hosting = view
        setContent(view)
    }

    private func showEditor() {
        let id = node.id
        let view = NSHostingView(rootView:
            CanvasTextEditing(text: text) { [weak self] edited in
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
    let onChange: (String) -> Void
    let onDone: () -> Void
    let onOpenProject: (String) -> Void

    init(text: String,
         onChange: @escaping (String) -> Void,
         onDone: @escaping () -> Void,
         onOpenProject: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.onChange = onChange
        self.onDone = onDone
        self.onOpenProject = onOpenProject
    }

    var body: some View {
        MarkdownTextEditor(onOpenProject: onOpenProject,
                           text: $text,
                           onSubmit: onDone,
                           onCancel: onDone)
            .onChange(of: text) { _, edited in onChange(edited) }
    }
}
