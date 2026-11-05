import AppKit
import Quartz

/// The icon view's grid: a collection view, so selecting, ⌘ and ⇧ clicking, the arrow keys, a drag
/// marquee and dragging several icons out are its own.
@MainActor
final class CanvasFolderIconGrid: NSCollectionView, CanvasFolderSurface {
    weak var controller: CanvasFolderGrid?

    var selectedURLs: [URL] { controller?.urls(at: selectionIndexPaths.sorted()) ?? [] }
    var shownURLs: [URL] { controller?.allURLs ?? [] }
    func select(_ urls: [URL], scrolling: Bool) { controller?.select(urls, scrolling: scrolling) }
    func beginRename(_ url: URL) { controller?.beginRename(url) }
    func url(at point: NSPoint) -> URL? {
        guard let path = indexPathForItem(at: point) else { return nil }
        return controller?.url(at: path)
    }
    func rect(of url: URL) -> NSRect? {
        guard let path = controller?.indexPath(of: url) else { return nil }
        return layoutAttributesForItem(at: path)?.frame
    }
    func reload() { controller?.reload() }
    func showDropTarget(_ url: URL?) { controller?.showDropTarget(url) }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took {
            controller?.refreshHighlight()
            controller?.browser?.tookFocus()
        }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { DispatchQueue.main.async { [weak self] in self?.controller?.refreshHighlight() } }
        return gave
    }

    private var typed = ""
    private var typedAt = Date.distantPast

    override func keyDown(with event: NSEvent) {
        guard let actions = controller?.browser?.actions else { return super.keyDown(with: event) }
        if actions.handleKey(event, in: self) { return }
        // Type-select, which the list gets from its table and the grid has to be given: the first item
        // whose name starts with what was typed in the last moment.
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let typedNow = event.characters, !typedNow.isEmpty,
           typedNow.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains($0) }),
           event.specialKey == nil {
            if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
            typed += typedNow.lowercased()
            typedAt = Date()
            let names = shownURLs.map { ($0, $0.lastPathComponent.lowercased()) }
            if let hit = names.first(where: { $0.1.hasPrefix(typed) }) ?? names.first(where: { $0.1 >= typed }) {
                select([hit.0], scrolling: true)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, controller?.browser?.actions.handleKeyEquivalent(event, in: self) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions = controller?.browser?.actions else { return nil }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(path) {
                selectionIndexPaths = [path]
                controller?.selectionChanged()
            }
            return actions.itemMenu(for: selectedURLs, in: self)
        }
        selectionIndexPaths = []
        controller?.selectionChanged()
        return actions.emptyMenu(in: self)
    }

    @objc func copy(_ sender: Any?) { controller?.browser?.actions.copy(selectedURLs) }
    @objc func paste(_ sender: Any?) { controller?.browser?.actions.paste() }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.browser?.actions.beginQuickLook(panel, from: self)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.browser?.actions.endQuickLook(panel)
    }
}

/// The grid's data source and delegate.
@MainActor
final class CanvasFolderGrid: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
                              NSTextFieldDelegate {
    weak var browser: CanvasFolderBrowser?
    let collection: CanvasFolderIconGrid
    private let layout = NSCollectionViewFlowLayout()
    private(set) var sections: [(title: String, entries: [CanvasFolderEntry])] = []
    private var dropTarget: URL?
    private var renaming: URL?

    static let itemID = NSUserInterfaceItemIdentifier("icon")
    static let headerID = NSUserInterfaceItemIdentifier("header")

    init(browser: CanvasFolderBrowser, collection: CanvasFolderIconGrid) {
        self.browser = browser
        self.collection = collection
        super.init()
        collection.controller = self
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(CanvasFolderIconItem.self, forItemWithIdentifier: Self.itemID)
        collection.register(CanvasFolderIconHeader.self,
                            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: Self.headerID)
        collection.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
    }

    var allURLs: [URL] { sections.flatMap { $0.entries.map(\.url) } }

    func reload() {
        guard let model = browser?.model else { return }
        let options = model.options
        let kept = collection.selectedURLs
        sections = options.group == .none ? [("", model.listing.entries)]
                                          : options.group.groups(of: model.listing.entries)
        let side = options.iconSize
        layout.itemSize = NSSize(width: max(side + 28, 84), height: side + 8 + 38)
        layout.headerReferenceSize = options.group == .none ? .zero : NSSize(width: 0, height: 24)
        collection.reloadData()
        select(kept, scrolling: false)
    }

    func url(at path: IndexPath) -> URL? {
        guard sections.indices.contains(path.section), sections[path.section].entries.indices.contains(path.item)
        else { return nil }
        return sections[path.section].entries[path.item].url
    }

    func urls(at paths: [IndexPath]) -> [URL] { paths.compactMap(url(at:)) }

    func indexPath(of url: URL) -> IndexPath? {
        let key = CanvasFolderEntry.key(url)
        for (section, group) in sections.enumerated() {
            if let item = group.entries.firstIndex(where: { $0.key == key }) {
                return IndexPath(item: item, section: section)
            }
        }
        return nil
    }

    func select(_ urls: [URL], scrolling: Bool) {
        let paths = Set(urls.compactMap(indexPath(of:)))
        collection.selectionIndexPaths = paths
        if scrolling, !paths.isEmpty { collection.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge) }
        selectionChanged()
    }

    func selectionChanged() {
        refreshHighlight()
        browser?.updateStatus()
        browser?.actions.selectionChanged()
    }

    /// Selected icons are drawn in the accent colour while the grid has the keyboard, and in grey
    /// otherwise — the Finder's two kinds of selected.
    func refreshHighlight() {
        let emphasized = collection.window?.firstResponder === collection
        for item in collection.visibleItems() {
            (item as? CanvasFolderIconItem)?.cell.emphasized = emphasized
        }
    }

    func showDropTarget(_ url: URL?) {
        dropTarget = url
        for item in collection.visibleItems() {
            guard let item = item as? CanvasFolderIconItem else { continue }
            item.cell.isDropTarget = url != nil && item.cell.shown?.key == url.map(CanvasFolderEntry.key)
        }
    }

    // MARK: Renaming

    func beginRename(_ url: URL) {
        guard let path = indexPath(of: url) else { return }
        select([url], scrolling: true)
        renaming = url
        collection.layoutSubtreeIfNeeded()
        guard let item = collection.item(at: path) as? CanvasFolderIconItem else { return }
        item.cell.beginRename(delegate: self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renaming,
              let entry = sections.flatMap(\.entries).first(where: { $0.key == CanvasFolderEntry.key(url) }) else { return }
        renaming = nil
        field.isEditable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { collection.window?.makeFirstResponder(collection) }
        guard !name.isEmpty, name != entry.url.lastPathComponent, name != entry.name else {
            field.stringValue = entry.name
            return
        }
        if browser?.actions.rename(url, to: name) == nil { field.stringValue = entry.name }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField,
              let url = renaming, let entry = sections.flatMap(\.entries).first(where: { $0.key == CanvasFolderEntry.key(url) }) else { return false }
        field.stringValue = entry.name
        renaming = nil
        field.isEditable = false
        collection.window?.makeFirstResponder(collection)
        return true
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
        if let icon = item as? CanvasFolderIconItem, let options = browser?.model.options {
            let entry = sections[indexPath.section].entries[indexPath.item]
            icon.cell.show(entry, side: options.iconSize, previews: options.iconPreviews)
            icon.cell.emphasized = collectionView.window?.firstResponder === collectionView
            icon.cell.isDropTarget = dropTarget.map(CanvasFolderEntry.key) == entry.key
            icon.onDoubleClick = { [weak self] in
                guard let self else { return }
                let selected = collection.selectedURLs
                self.browser?.actions.open(selected.contains(entry.url) ? selected : [entry.url])
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerID, for: indexPath)
        (view as? CanvasFolderIconHeader)?.show(sections[indexPath.section].title,
                                                count: sections[indexPath.section].entries.count)
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        url(at: indexPath) as NSURL?
    }
}

/// One icon: the item, whose view is a `CanvasFolderIconCell`.
@MainActor
final class CanvasFolderIconItem: NSCollectionViewItem {
    var onDoubleClick: () -> Void = {}
    var cell: CanvasFolderIconCell { view as! CanvasFolderIconCell }

    override func loadView() {
        let cell = CanvasFolderIconCell()
        cell.item = self
        view = cell
    }

    override var isSelected: Bool {
        didSet { cell.selected = isSelected }
    }
}

/// An icon over its name, with the Finder's two highlights: a grey plate behind the icon, and the name
/// on a pill in the accent colour — grey when the grid hasn't got the keyboard.
@MainActor
final class CanvasFolderIconCell: NSView {
    weak var item: CanvasFolderIconItem?
    private let icon = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let tagDots = CanvasFolderTagDots()
    private let syncMark = NSImageView()
    private(set) var shown: CanvasFolderEntry?
    private var side: CGFloat = 64

    var selected = false { didSet { refresh() } }
    var emphasized = false { didSet { refresh() } }
    var isDropTarget = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 11)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byWordWrapping
        name.cell?.truncatesLastVisibleLine = true
        name.drawsBackground = false
        name.isBordered = false
        name.focusRingType = .none
        syncMark.imageScaling = .scaleProportionallyDown
        [icon, name, tagDots, syncMark].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func show(_ entry: CanvasFolderEntry, side: CGFloat, previews: Bool) {
        shown = entry
        self.side = side
        name.stringValue = entry.name
        toolTip = entry.name
        icon.image = CanvasFolderIcons.icon(for: entry, side: side, previews: previews) { [weak self] picture in
            guard self?.shown?.url == entry.url else { return }
            self?.icon.image = picture
        }
        tagDots.tags = entry.tags
        syncMark.image = CanvasFolderIcons.syncSymbol(entry.sync)
        syncMark.toolTip = entry.sync.help
        refresh()
        needsLayout = true
    }

    private func refresh() {
        let light = selected && emphasized
        name.textColor = light ? .alternateSelectedControlTextColor : .labelColor
        tagDots.emphasized = light
        if light {
            syncMark.contentTintColor = .alternateSelectedControlTextColor
        } else if case .failed? = shown?.sync {
            syncMark.contentTintColor = .systemRed
        } else {
            syncMark.contentTintColor = .secondaryLabelColor
        }
        needsDisplay = true
    }

    func beginRename(delegate: NSTextFieldDelegate) {
        name.isEditable = true
        name.isSelectable = true
        name.delegate = delegate
        name.textColor = .labelColor
        window?.makeFirstResponder(name)
        if let editor = name.currentEditor() {
            let text = name.stringValue as NSString
            let ext = text.pathExtension
            let length = ext.isEmpty || shown?.isFolder == true ? text.length : text.length - ext.count - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, length))
        }
    }

    private var iconBox: NSRect {
        NSRect(x: (bounds.width - side - 8) / 2, y: 2, width: side + 8, height: side + 8)
    }

    private var nameBox: NSRect = .zero

    override func layout() {
        super.layout()
        let box = iconBox
        icon.frame = box.insetBy(dx: 4, dy: 4)
        let marks = (tagDots.intrinsicContentSize.width > 0 ? tagDots.intrinsicContentSize.width + 3 : 0)
            + (syncMark.image != nil ? 15 : 0)
        let room = bounds.width - 4 - marks
        let fitted = name.sizeThatFits(NSSize(width: room, height: 30))
        let width = min(room, ceil(fitted.width) + 2)
        let height = min(30, ceil(fitted.height))
        let x = (bounds.width - width - marks) / 2
        name.frame = NSRect(x: x + (tagDots.intrinsicContentSize.width > 0 ? tagDots.intrinsicContentSize.width + 3 : 0),
                            y: box.maxY + 3, width: width, height: height)
        nameBox = name.frame.insetBy(dx: -3, dy: -1)
        tagDots.isHidden = tagDots.intrinsicContentSize.width == 0
        tagDots.frame = NSRect(x: x, y: box.maxY + 6, width: tagDots.intrinsicContentSize.width, height: 9)
        syncMark.isHidden = syncMark.image == nil
        syncMark.frame = NSRect(x: name.frame.maxX + 2, y: box.maxY + 4, width: 13, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || isDropTarget {
            let plate = NSBezierPath(roundedRect: iconBox, xRadius: 6, yRadius: 6)
            (isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.3)
                          : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            plate.fill()
        }
        if selected {
            let pill = NSBezierPath(roundedRect: nameBox, xRadius: 4, yRadius: 4)
            (emphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            pill.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { item?.onDoubleClick() }
    }
}

/// A group's heading in the icon view.
@MainActor
final class CanvasFolderIconHeader: NSView, NSCollectionViewElement {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ title: String, count: Int) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        text.append(NSAttributedString(string: "  \(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        label.attributedStringValue = text
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.minY, width: bounds.width, height: 1).fill()
    }
}
