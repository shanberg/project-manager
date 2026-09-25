import AppKit
import PmLib

/// The board as a grid of faces (docs/items.md D8) — the visual index, where the list is the dense one.
///
/// **Faces, not renderers.** A grid of live cards would be a screenful of web views, which is the cost
/// `CanvasDetail` was written to avoid and the opposite of what a lens is for. So a tile draws what the
/// board draws when it is zoomed out past reading — the card's symbol and its one line — over the
/// picture the card already has: `CanvasPageSnapshots` keeps an untiled picture of every page card that
/// has ever been up, and that picture cost nothing to take. A card with no picture is its face alone,
/// which is exactly what the board shows you at that zoom.
///
/// The rows, the sections and the acts are the list's (`CanvasItemListView`): this is the same read,
/// laid out as cells. A collection view rather than a second table, because the one thing a grid has
/// that a list hasn't is reflowing to the width it is given.
@MainActor
final class CanvasItemGridView: NSView {
    private let store: CanvasDocumentStore
    private let collection = CanvasItemCollection()
    private let scroll = NSScrollView()

    var lookups: CanvasItemLookups = .plain { didSet { reload() } }
    var sort: CanvasItemSort = .reading { didSet { reload() } }
    var frame_: String? { didSet { reload() } }
    var icon: (CanvasItem.Kind) -> NSImage? = { _ in nil }
    var onOpen: (String) -> Void = { _ in }
    var onDelete: ([String]) -> Void = { _ in }
    var menuForSelection: ([String]) -> NSMenu? = { _ in nil }
    /// Somebody picked a different order from the lens's own menu (D4) — the list's `onSort`.
    var onSort: (CanvasItemSort) -> Void = { _ in }
    /// Something was dropped on a band — the list's `onDrop`, and the same rule behind it (D7).
    var onDrop: (String?, NSPasteboard) -> Bool = { _, _ in false }
    var selection: [String] { collection.selectionIndexPaths.sorted().compactMap { item(at: $0)?.id } }
    var onSelectionChanged: ([String]) -> Void = { _ in }
    var selectedFrame: String? {
        collection.selectionIndexPaths.sorted().first.flatMap { sections[$0.section].frame }
    }

    private var sections: [CanvasItemSection] = []

    init(store: CanvasDocumentStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        store.addWatcher(self, changed: { [weak self] in self?.reload() },
                         reloaded: { [weak self] in self?.reload() })
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Stop being told about writes. Called by whoever owns the lens when it is finished with, for
    /// the reason `CanvasPaneController.teardown` gives — and safe to call twice.
    func stopWatching() { store.removeWatcher(self) }

    /// A tile: wide enough for two lines of a title under a picture with a card's shape.
    static let cell = NSSize(width: 168, height: 152)
    static let headerHeight: CGFloat = 28
    /// What the floating header chrome covers — the list's, for the same reason.
    static let headerBand = CanvasItemListView.headerBand

    private func build() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.cell
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 4, left: 16, bottom: 20, right: 16)
        layout.headerReferenceSize = NSSize(width: 0, height: Self.headerHeight)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.owner = self
        collection.dataSource = self
        collection.delegate = self
        collection.register(CanvasItemTile.self,
                            forItemWithIdentifier: NSUserInterfaceItemIdentifier("tile"))
        collection.register(CanvasItemBand.self,
                            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: NSUserInterfaceItemIdentifier("band"))
        collection.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collection.registerForDraggedTypes([CanvasItemRows.pasteboardType, CanvasClipping.pasteboardType,
                                            .fileURL, .URL, .string] + NoteImagePasteboard.imageTypes)

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.headerBand, left: 0, bottom: 12, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: Self.headerBand, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload() {
        let kept = Set(selection)
        let document = store.document
        if let frame_ {
            sections = CanvasItems.sections(of: document, sort: sort, lookups: lookups)
                .filter { $0.frame == frame_ }
        } else {
            sections = CanvasItems.sections(of: document, sort: sort, lookups: lookups)
        }
        collection.reloadData()
        select(Array(kept))
    }

    /// Put the selection somewhere by id, as the list does and for the same reason.
    func select(_ ids: [String]) {
        let wanted = Set(ids)
        var paths: Set<IndexPath> = []
        for (section, group) in sections.enumerated() {
            for (item, card) in group.items.enumerated() where wanted.contains(card.id) {
                paths.insert(IndexPath(item: item, section: section))
            }
        }
        collection.selectionIndexPaths = paths
    }

    func takeFocus() { window?.makeFirstResponder(collection) }

    /// The menu for a press that isn't on a tile — the gaps, the bands, the space below. The list's,
    /// and for its reasons.
    fileprivate func sortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Sort Cards By"))
        for order in CanvasItemSort.allCases {
            let item = menu.addItem(withTitle: order.title, action: #selector(sortPicked(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = order
            item.state = order == sort ? .on : .off
        }
        return menu
    }

    @objc private func sortPicked(_ sender: Any?) {
        guard let order = (sender as? NSMenuItem)?.representedObject as? CanvasItemSort else { return }
        onSort(order)
    }

    fileprivate func openSelection() {
        guard let first = selection.first else { return NSSound.beep() }
        onOpen(first)
    }

    fileprivate func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return NSSound.beep() }
        onDelete(ids)
    }

    private func item(at path: IndexPath) -> CanvasItem? {
        guard sections.indices.contains(path.section),
              sections[path.section].items.indices.contains(path.item) else { return nil }
        return sections[path.section].items[path.item]
    }
}

extension CanvasItemGridView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("tile"),
                                           for: indexPath) as! CanvasItemTile
        if let card = item(at: indexPath) {
            tile.show(card, icon: icon(card.kind), picture: CanvasPageSnapshots.of(card.id, tiled: false))
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let band = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("band"), for: indexPath
        ) as! CanvasItemBand
        band.label.stringValue = sections[indexPath.section].label ?? ""
        return band
    }

    /// A double-click opens, as it does in the list and in the Finder.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged(selection)
        guard NSApp.currentEvent?.clickCount ?? 1 > 1, let first = indexPaths.first,
              let card = item(at: first) else { return }
        onOpen(card.id)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged(selection)
    }

    // MARK: Dragging

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath).flatMap { CanvasItemRows.item(for: $0.id, in: store) }
    }

    /// **A drop lands in a band**, which is the grid's way of saying what the list says by retargeting
    /// a drop onto a section (D7): the rows are sorted, so there is no place *between* two tiles to
    /// drop something into. So whichever gap the pointer is in, the drop is shown at the end of that
    /// band — the caret says which set of cards you are about to join.
    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !sections.isEmpty else { return [] }
        let section = min(max(proposedIndexPath.pointee.section, 0), sections.count - 1)
        proposedIndexPath.pointee = IndexPath(item: sections[section].items.count,
                                              section: section) as NSIndexPath
        dropOperation.pointee = .before
        let ours = !CanvasItemRows.read(info.draggingPasteboard).isEmpty
        return ours && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard sections.indices.contains(indexPath.section) else { return false }
        return onDrop(sections[indexPath.section].frame, info.draggingPasteboard)
    }

}

/// The grid's collection view, which is where the keys and the menu are read.
///
/// **On the collection rather than on the view around it**, for the reason the list's table is a
/// subclass too: the collection is the first responder and the view under the pointer, so anything
/// answered a level up is answered only when AppKit happens to walk that far. The commands are the
/// board's — Space and ⏎ show you one, ⌫ deletes — so both lenses keep the same keystrokes for the
/// same acts.
private final class CanvasItemCollection: NSCollectionView {
    weak var owner: CanvasItemGridView?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " " where !event.modifierFlags.contains(.command), "\r":
            owner?.openSelection()
        case String(UnicodeScalar(NSDeleteCharacter)!), String(UnicodeScalar(NSBackspaceCharacter)!):
            owner?.deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    /// The menu over the tile you pressed on, targeted the way every Mac grid targets: the selection
    /// when the tile is in it, that tile alone when it isn't.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return owner.sortMenu() }
        if !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        let targets = owner.selection
        return targets.isEmpty ? nil : owner.menuForSelection(targets)
    }
}

/// One item in the grid: its picture if it has one, its symbol if it hasn't, and its one line under it.
final class CanvasItemTile: NSCollectionViewItem {
    private let face = NSImageView()
    private let symbol = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let plate = NSView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        plate.layer?.cornerCurve = .continuous
        plate.layer?.borderWidth = 1
        plate.layer?.masksToBounds = true
        face.imageScaling = .scaleProportionallyUpOrDown
        // The top of the picture, as a card shows its own top — a page's masthead is what makes it
        // recognisable, and centring the crop would cut it off.
        face.imageAlignment = .alignTop
        symbol.symbolConfiguration = .init(pointSize: 24, weight: .regular)
        symbol.contentTintColor = .tertiaryLabelColor
        caption.font = .systemFont(ofSize: 12)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 2
        caption.cell?.wraps = true
        for child in [plate, caption] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        for child in [face, symbol] {
            child.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(child)
        }
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: view.topAnchor),
            plate.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            plate.heightAnchor.constraint(equalToConstant: 108),
            face.topAnchor.constraint(equalTo: plate.topAnchor),
            face.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            face.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            face.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            symbol.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            caption.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
        dress()
    }

    override var isSelected: Bool { didSet { dress() } }

    func show(_ item: CanvasItem, icon: NSImage?, picture: NSImage?) {
        face.image = picture
        symbol.image = picture == nil ? icon : nil
        caption.stringValue = item.title
        view.toolTip = item.title
        dress()
    }

    /// Selected is a ring around the picture and nothing else — a grid of faces should not have a slab
    /// of colour dropped over the one you picked, and the name goes on being the name.
    private func dress() {
        plate.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        plate.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        plate.layer?.borderWidth = isSelected ? 2 : 1
    }
}

/// A frame's name over its band of tiles — the grid's section header (D3).
final class CanvasItemBand: NSView, NSCollectionViewElement {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
