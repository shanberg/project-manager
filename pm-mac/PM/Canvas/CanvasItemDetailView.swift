import AppKit
import PmLib

/// The right-hand half of the list lens (docs/items.md D11): the item the rows are pointing at, as a
/// tile.
///
/// **A list of forty one-line rows answers "what is on this board" and nothing else.** Picking a row
/// used to mean either taking it on trust or leaving the list — maximizing the card, looking, and
/// flying back. So the list became a list *and* a detail: the rows are the navigation, the arrow keys
/// walk them, and this shows what you are standing on.
///
/// **It is the card, not a picture of one.** This began as a face — a snapshot, or the markdown laid
/// out again beside it — on the argument that a renderer per keystroke is what the lens exists to
/// avoid. What that actually bought was a second way of drawing every kind of card, one that agreed
/// with the board on the easy ones and drifted on the rest: a stale snapshot for a page, a file read
/// twice by two different rules, nothing at all for a view card. A card already knows how to draw
/// itself. So this is a board — the same `CanvasBoardView`, on the same store — tiled to whatever the
/// rows have selected, which makes the detail literally the thing `⌥⌘↩` would fill the window with.
///
/// **Tiled rather than scrolled to**, which is what keeps that cheap and what keeps it safe. A tiling
/// of one card builds one card: the other thirty-nine are never made, so walking the list costs one
/// card's renderer at a time rather than a board's worth. And a tiled card has the tiled grammar —
/// there is no free space to drag into and nothing to resize — so a detail pane you can read and step
/// into is not also a second, smaller place to accidentally rearrange the board from.
///
/// **Several rows are several tiles**, because the machinery makes that free and because it is the
/// true answer: picking three cards and being shown a count would be the pane declining to do the one
/// thing it is for.
@MainActor
final class CanvasItemDetailView: NSView, CanvasItemDetailPane {
    private let store: CanvasDocumentStore
    private let scroll: CanvasScrollView
    /// The board this half is: a second board on the same document, which never shows a document
    /// layout — it is tiled or it is hidden.
    var board: CanvasBoardView { scroll.board }

    /// What the pane is showing, by id — what a test asks, and what tells `show` whether there is
    /// anything to do at all.
    private(set) var showing: [String] = []

    /// The ids that have been asked for but not yet laid out, because the pane has no size to lay them
    /// out into. See `lay`.
    private var pending: [String] = []

    private let nothing = PlaceholderView()

    init(store: CanvasDocumentStore) {
        self.store = store
        scroll = CanvasScrollView(store: store)
        super.init(frame: .zero)
        build()
        show([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How far the floating header chrome reaches down over this pane — the list's band, because the
    /// two halves are under the one header.
    static let headerBand = CanvasItemListView.headerBand

    private func build() {
        // **No ground of its own.** A `CanvasScrollView` doesn't paint one; its host puts `groundView`
        // behind it, and this half's host is the pane, whose ground and colour wash are already under
        // the whole lens (`CanvasPaneController.mount`). Adding a second would cover the wash with
        // plain grey along the seam and nowhere else, which is the kind of difference you see without
        // being able to say what it is.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The board runs to the edges, and its tiling keeps clear of the header itself — the lens's
        // band, not a board's own. See `CanvasBoardView.topClearance`.
        scroll.board.topClearance = Double(Self.headerBand)
        // Nothing here adds cards, and a drop on this half means the section the rows are showing,
        // which the list already answers. A board that took drops itself would be a third answer.
        scroll.board.unregisterDraggedTypes()
        addSubview(scroll)
        nothing.translatesAutoresizingMaskIntoConstraints = false
        nothing.set("Select an item", symbol: NSImage(systemSymbolName: "square.dashed",
                                                     accessibilityDescription: nil))
        addSubview(nothing)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            nothing.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerBand),
            nothing.leadingAnchor.constraint(equalTo: leadingAnchor),
            nothing.trailingAnchor.constraint(equalTo: trailingAnchor),
            nothing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: What it shows

    /// Show these items, by id — the lens's selection, in the order the list draws them.
    ///
    /// Re-tiled only when the selection changed, because this runs on every reload — including the one
    /// a keystroke in another window causes — and re-laying a card you are reading is work nobody
    /// asked for. `refresh` is how the document's own changes get through.
    func show(_ ids: [String]) {
        guard ids != showing else { return }
        showing = ids
        rebuild()
    }

    /// The document underneath changed, so the cards have to hear about it — an edit made on the
    /// board, in another window, or in Obsidian, reaching the pane you are reading it in. The tiling
    /// stands; only its contents are stale.
    func refresh(_ ids: [String]) {
        guard ids == showing else { return show(ids) }
        board.documentChanged()
    }

    private func rebuild() {
        let ids = showing.filter { store.document.node(id: $0).map { !$0.isGroup } ?? false }
        nothing.isHidden = !ids.isEmpty
        scroll.isHidden = ids.isEmpty
        pending = ids
        lay()
        // A hidden board is the page budget's own answer to nobody looking, but being hidden is
        // neither a scroll nor a resize, so it has to be told. The same note as
        // `CanvasPaneController.applyPresentation`, for the same reason.
        if ids.isEmpty { board.applyPageBudget() }
    }

    /// Lay the pending selection out, once there is somewhere to lay it out into.
    ///
    /// **A tiling is measured against the window it fills**, so one made before this half has a size
    /// is a tiling of an 80-point square — the floor `tileableRect` falls back to. Held until `layout`
    /// says otherwise, which is the first pass after the split has divided the pane.
    private func lay() {
        guard !pending.isEmpty, scroll.bounds.width > 1, scroll.bounds.height > 1 else { return }
        let ids = pending
        pending = []
        // **Never animated.** Every arrow key down the list comes through here, and a card flying
        // across the pane on each one is a journey nobody is following — see `CanvasBoardView.tile`.
        board.tile(Set(ids), animated: false)
    }

    override func layout() {
        super.layout()
        lay()
    }

    // MARK: Standing down

    /// The lens was hidden — the other lens, or the board itself, is up. The cards stay built, as the
    /// pane's own board's do while a lens is over it, but nothing hidden runs a page.
    override func viewDidHide() {
        super.viewDidHide()
        board.applyPageBudget()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        board.applyPageBudget()
    }

    /// The lens is finished with. Called by the list, which is called by the pane — see
    /// `CanvasPaneController.teardown`, which says why this is explicit rather than a `deinit`.
    func teardown() {
        board.pauseAllPages()
        board.releaseCards()
    }

    /// A symbol over a line of text, for an empty pane. The one thing this half draws itself.
    final class PlaceholderView: NSView {
        private let symbol = NSImageView()
        private let words = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            symbol.symbolConfiguration = .init(pointSize: 40, weight: .light)
            symbol.contentTintColor = .tertiaryLabelColor
            words.font = .systemFont(ofSize: 13)
            words.textColor = .secondaryLabelColor
            words.alignment = .center
            words.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [symbol, words])
            stack.orientation = .vertical
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func set(_ text: String, symbol image: NSImage?) {
            words.stringValue = text
            symbol.image = image
            symbol.isHidden = image == nil
        }
    }
}
