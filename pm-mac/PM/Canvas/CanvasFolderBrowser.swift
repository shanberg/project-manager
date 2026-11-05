import AppKit
import Combine
import Quartz
import SwiftUI

/// What a folder card's browser asks of the card it is on.
@MainActor
protocol CanvasFolderBrowserHost: AnyObject {
    /// Write these view settings to the card, as one undoable change.
    func folderBrowser(_ browser: CanvasFolderBrowser, commit options: CanvasFolderOptions, actionName: String)
    /// A click or a key went into the list: the card is the one you are working in.
    func folderBrowserTookFocus(_ browser: CanvasFolderBrowser)
    /// Escape: give the keyboard back to the board.
    func folderBrowserStepOut(_ browser: CanvasFolderBrowser)
    /// Put a card for each of these on the board beside this one.
    func folderBrowser(_ browser: CanvasFolderBrowser, addCardsFor urls: [URL])
}

/// One of the browser's two ways of drawing the folder — the list or the icons — said the same way, so
/// every command works in both. See `CanvasFolderActions`.
@MainActor
protocol CanvasFolderSurface: NSView {
    /// The selected items, in the order they are drawn.
    var selectedURLs: [URL] { get }
    /// Every item drawn, in order — what ⌘A selects and type-select searches.
    var shownURLs: [URL] { get }
    func select(_ urls: [URL], scrolling: Bool)
    func beginRename(_ url: URL)
    /// The item drawn at `point`, in this view's coordinates.
    func url(at point: NSPoint) -> URL?
    /// Where `url` is drawn, in this view's coordinates.
    func rect(of url: URL) -> NSRect?
    func reload()
    /// Light the folder files are being dragged into, or nothing.
    func showDropTarget(_ url: URL?)
}

/// A folder card's body: the Finder's window on a folder, drawn by AppKit.
///
/// **A table, not a drawing of one** — the same choice the list lens made (`CanvasItemListView`). Click
/// to select, ⌘ and ⇧ to add, a double-click to open, the arrow keys, type-select, Return to rename,
/// Space for Quick Look, a column header to sort and again to turn it round, a disclosure triangle to
/// look inside a folder without leaving this one, several items dragged out at once: every one of those
/// is what `NSOutlineView` and `NSCollectionView` *are*. They are also what makes the card testable
/// headlessly, which SwiftUI in a bundle that is never the active app is not.
///
/// **The list is the Finder's; the header is the board's.** A card refuses clicks until you step in,
/// so a board can be rearranged without guessing what was under the pointer. This card takes the
/// clicks that land on its list and its path bar straight away — there is nothing on a Finder window's
/// list that waits for a click to focus it — and leaves the header and the edge band to the board, so
/// the card is still picked up and moved by its title. See `CanvasNodeView.takesClick(at:)`.
///
/// Laid out top to bottom: the header (`CanvasFolderHeader`), the list or the icons, the path bar and
/// the status bar, each where View Options says.
@MainActor
final class CanvasFolderBrowser: NSView {
    let model: CanvasFolderModel
    weak var host: CanvasFolderBrowserHost?
    private(set) lazy var actions = CanvasFolderActions(browser: self)

    private let header: NSHostingView<AnyView>
    let listScroll = NSScrollView()
    let outline = CanvasFolderOutline()
    private(set) lazy var list = CanvasFolderList(browser: self, outline: outline)
    let iconScroll = NSScrollView()
    let icons = CanvasFolderIconGrid()
    private(set) lazy var grid = CanvasFolderGrid(browser: self, collection: icons)
    let pathBar = NSPathControl()
    /// The folder each of the path bar's items stands for, in order.
    private var pathURLs: [URL] = []
    let statusBar = NSTextField(labelWithString: "")
    private let dropRing = CanvasFolderDropRing()

    private var observation: AnyCancellable?
    private var reloadQueued = false
    private var shownOptions: CanvasFolderOptions

    static let headerHeight: CGFloat = 40
    static let barHeight: CGFloat = 22

    init(model: CanvasFolderModel, linkZones: CanvasLinkZones) {
        self.model = model
        shownOptions = model.options
        header = NSHostingView(rootView: AnyView(CanvasFolderHeader(folder: model).canvasLinkZones(linkZones)))
        super.init(frame: .zero)
        header.sizingOptions = []
        addSubview(header)

        for scroll in [listScroll, iconScroll] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            addSubview(scroll)
        }
        listScroll.documentView = outline
        iconScroll.documentView = icons
        _ = list
        _ = grid

        pathBar.pathStyle = .standard
        pathBar.controlSize = .small
        pathBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathBar.backgroundColor = .clear
        pathBar.focusRingType = .none
        pathBar.target = self
        pathBar.action = #selector(pathClicked(_:))
        addSubview(pathBar)

        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.alignment = .center
        statusBar.lineBreakMode = .byTruncatingMiddle
        addSubview(statusBar)

        addSubview(dropRing)

        observation = model.objectWillChange.sink { [weak self] _ in self?.queueReload() }
        reloadNow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Which of the two is showing.
    var surface: CanvasFolderSurface { model.options.view == .list ? outline : icons }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        var bottom = bounds.height
        header.frame = NSRect(x: 0, y: 0, width: width, height: Self.headerHeight)
        if model.options.statusBar {
            bottom -= Self.barHeight
            statusBar.frame = NSRect(x: 8, y: bottom + 4, width: width - 16, height: 14)
        }
        statusBar.isHidden = !model.options.statusBar
        if model.options.pathBar {
            bottom -= Self.barHeight
            pathBar.frame = NSRect(x: 6, y: bottom + 1, width: width - 12, height: Self.barHeight - 2)
        }
        pathBar.isHidden = !model.options.pathBar
        let content = NSRect(x: 0, y: Self.headerHeight + 1, width: width,
                             height: max(0, bottom - Self.headerHeight - 1))
        listScroll.frame = content
        iconScroll.frame = content
        listScroll.isHidden = model.options.view != .list
        iconScroll.isHidden = model.options.view != .icons
        dropRing.frame = bounds
        list.fitColumns(to: listScroll.contentSize.width)
        needsDisplay = true
    }

    /// The hairlines between the header, the list and the bars — the Finder's, as separators.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = 1 / max(1, window?.backingScaleFactor ?? 2)
        NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: line).fill()
        var y = bounds.height
        if model.options.statusBar {
            y -= Self.barHeight
            NSRect(x: 0, y: y, width: bounds.width, height: line).fill()
        }
        if model.options.pathBar {
            y -= Self.barHeight
            NSRect(x: 0, y: y, width: bounds.width, height: line).fill()
        }
    }

    // MARK: What the card asks

    /// Whether a click at `point`, in this view's coordinates, is the browser's own — the list, the
    /// icons and the path bar. The header is the board's, to pick the card up by.
    func takesClick(at point: NSPoint) -> Bool {
        let content = model.options.view == .list ? listScroll.frame : iconScroll.frame
        if content.contains(point) { return true }
        return model.options.pathBar && pathBar.frame.contains(point)
    }

    /// The folder row or icon under `point`, in this view's coordinates — where files dragged in from
    /// outside would go if let go there.
    func folderRow(at point: NSPoint) -> URL? {
        let view = surface
        guard let url = view.url(at: view.convert(point, from: self)),
              CanvasFolderListing.isFolder(url) else { return nil }
        return url
    }

    /// The node's settings changed — from View Options, a menu, an undo, another window.
    func apply(_ options: CanvasFolderOptions) {
        guard options != model.options else { return }
        model.options = options
    }

    /// Show these settings without writing them — View Options' icon size while its slider is held.
    func preview(_ options: CanvasFolderOptions) {
        model.options = options
    }

    func commit(_ options: CanvasFolderOptions, actionName: String) {
        model.options = options
        host?.folderBrowser(self, commit: options, actionName: actionName)
    }

    /// Change one setting and write it to the card.
    func change(_ actionName: String, _ edit: (inout CanvasFolderOptions) -> Void) {
        var options = model.options
        edit(&options)
        guard options != model.options else { return }
        commit(options, actionName: actionName)
    }

    /// The keyboard went into the list or the icons.
    func tookFocus() {
        host?.folderBrowserTookFocus(self)
        CanvasFolderViewOptions.shared.follow(self)
        updateStatus()
    }

    func stepOut() { host?.folderBrowserStepOut(self) }

    /// Make the list or the icons take the keyboard, as a click on them would.
    func focus() { window?.makeFirstResponder(surface) }

    /// Going away: let go of the panel and the folder.
    func teardown() {
        observation = nil
        CanvasFolderViewOptions.shared.forget(self)
        actions.endQuickLook()
    }

    // MARK: Reloading

    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        // `objectWillChange` fires before the change lands.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadQueued = false
            reloadNow()
        }
    }

    /// Draw what the model says now. Selections survive, by item.
    func reloadNow() {
        let options = model.options
        let layoutChanged = options.view != shownOptions.view || options.pathBar != shownOptions.pathBar
            || options.statusBar != shownOptions.statusBar || options.orderedColumns != shownOptions.orderedColumns
        let wasFocused = window?.firstResponder === (shownOptions.view == .list ? outline : icons)
        let kept = (shownOptions.view == .list ? outline as CanvasFolderSurface : icons).selectedURLs
        shownOptions = options
        list.reload()
        grid.reload()
        if layoutChanged {
            needsLayout = true
            surface.select(kept, scrolling: true)
            if wasFocused { focus() }
        }
        updatePath()
        updateStatus()
        surface.showDropTarget(model.dropTarget)
        dropRing.isLit = model.dropTarget.map { CanvasFolderModel.same($0, model.location) } ?? false
        CanvasFolderViewOptions.shared.refresh(self)
    }

    /// The status bar's sentence, the Finder's: how many items, how many of them selected, and how much
    /// room the disk has left.
    func updateStatus() {
        guard model.options.statusBar else { return }
        guard model.loaded else {
            statusBar.stringValue = "Loading…"
            return
        }
        if let filing = model.filing {
            let items = filing.count == 1 ? "1 item" : "\(filing.count) items"
            statusBar.stringValue = "\(filing.copying ? "Copying" : "Moving") \(items)…"
            return
        }
        statusBar.stringValue = Self.status(total: model.listing.total, selected: surface.selectedURLs.count,
                                            available: Self.available(at: model.location))
    }

    static func status(total: Int, selected: Int, available: Int64?) -> String {
        let items = selected > 0 ? "\(selected) of \(CanvasFolderListing.countLabel(total)) selected"
                                 : CanvasFolderListing.countLabel(total)
        guard let available else { return items }
        return "\(items), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available"
    }

    private static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Path bar

    /// The way to the folder showing, from where the Finder would start it: the cloud drive it is on,
    /// else the home folder, else the disk.
    static func pathChain(to location: URL) -> [URL] {
        let path = location.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var start = "/"
        let cloud = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloud) {
            let rest = path.dropFirst(cloud.count)
            start = cloud + (rest.split(separator: "/").first.map(String.init) ?? "")
        } else if path == home || path.hasPrefix(home + "/") {
            start = home
        }
        var chain: [URL] = []
        var url = URL(fileURLWithPath: path)
        while true {
            chain.insert(url, at: 0)
            if url.path == start || url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return chain
    }

    private func updatePath() {
        guard model.options.pathBar else { return }
        let chain = Self.pathChain(to: model.location)
        guard chain != pathURLs else { return }
        pathURLs = chain
        pathBar.pathItems = chain.map { url in
            let item = NSPathControlItem()
            item.title = FileManager.default.displayName(atPath: url.path)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 14, height: 14)
            item.image = icon
            return item
        }
    }

    /// A folder on the path: the card goes there if it is its own folder or one inside it; anywhere
    /// further up opens in the Finder, since the card is of its folder and not of the disk.
    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem, let index = sender.pathItems.firstIndex(of: item),
              pathURLs.indices.contains(index) else { return }
        let url = pathURLs[index]
        if !model.go(to: url) { NSWorkspace.shared.open(url) }
    }
}

/// The accent ring inside the card's edge that says files let go now would go into the folder showing,
/// as a Finder window's list says it.
private final class CanvasFolderDropRing: NSView {
    var isLit = false { didSet { if isLit != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard isLit else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: - The list

/// One row of the list: an item, or a group's heading when the card uses groups.
@MainActor
final class CanvasFolderRow: NSObject {
    var entry: CanvasFolderEntry?
    var title = ""
    var count = 0
    var children: [CanvasFolderRow] = []
    var isGroup: Bool { entry == nil }
    var url: URL? { entry?.url }
}

/// The list's table: an outline view, so a folder row has its triangle.
@MainActor
final class CanvasFolderOutline: NSOutlineView, CanvasFolderSurface {
    weak var controller: CanvasFolderList?

    var selectedURLs: [URL] { controller?.urls(at: selectedRowIndexes) ?? [] }
    var shownURLs: [URL] { controller?.urls(at: IndexSet(integersIn: 0..<numberOfRows)) ?? [] }
    func select(_ urls: [URL], scrolling: Bool) { controller?.select(urls, scrolling: scrolling) }
    func beginRename(_ url: URL) { controller?.beginRename(url) }
    func url(at point: NSPoint) -> URL? {
        let row = row(at: point)
        return row >= 0 ? (item(atRow: row) as? CanvasFolderRow)?.url : nil
    }
    func rect(of url: URL) -> NSRect? {
        guard let row = controller?.row(of: url) else { return nil }
        return rect(ofRow: row)
    }
    func reload() { controller?.reload() }
    func showDropTarget(_ url: URL?) { controller?.showDropTarget(url) }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { controller?.browser?.tookFocus() }
        return took
    }

    override func keyDown(with event: NSEvent) {
        guard let actions = controller?.browser?.actions else { return super.keyDown(with: event) }
        if actions.handleKey(event, in: self) { return }
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
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let item = item(atRow: row) as? CanvasFolderRow {
            guard !item.isGroup else { return nil }
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
            return actions.itemMenu(for: selectedURLs, in: self)
        }
        deselectAll(nil)
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

/// The list's data source and delegate.
@MainActor
final class CanvasFolderList: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    weak var browser: CanvasFolderBrowser?
    let outline: CanvasFolderOutline
    private(set) var top: [CanvasFolderRow] = []
    /// Rows by item, kept across reloads so the outline keeps their expansion and selection.
    private var rows: [URL: CanvasFolderRow] = [:]
    private var groupRows: [String: CanvasFolderRow] = [:]
    private var applyingSort = false
    private var renaming: URL?
    private var dropRow: CanvasFolderRow?

    static let nameID = NSUserInterfaceItemIdentifier("name")
    static let rowHeight: CGFloat = 22

    /// The width a column asks for. A date column gives way before any column is left off — to a
    /// date without its time, then to a short one — as the Finder's date columns do; `dateWidths` are
    /// those steps, widest first.
    static func width(of column: CanvasFolderColumn, dateWidth: CGFloat = dateWidths[0]) -> CGFloat {
        switch column {
        case .size: return 72
        case .kind: return 118
        default: return dateWidth
        }
    }
    static let dateWidths: [CGFloat] = [168, 96, 72]
    static let nameMinimum: CGFloat = 170
    /// Between columns, and the inset style's margin either side of the rows.
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 24

    init(browser: CanvasFolderBrowser, outline: CanvasFolderOutline) {
        self.browser = browser
        self.outline = outline
        super.init()
        outline.controller = self
        outline.dataSource = self
        outline.delegate = self
        outline.headerView = NSTableHeaderView()
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = Self.rowHeight
        outline.usesAlternatingRowBackgroundColors = true
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: Self.spacing, height: 0)
        outline.autoresizesOutlineColumn = false
        outline.draggingDestinationFeedbackStyle = .regular
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))

        let name = NSTableColumn(identifier: Self.nameID)
        name.title = "Name"
        name.minWidth = 60
        name.resizingMask = []
        name.sortDescriptorPrototype = NSSortDescriptor(key: CanvasFolderSort.name.rawValue, ascending: true)
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        for column in CanvasFolderColumn.allCases {
            let table = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            table.title = column.title
            table.width = Self.width(of: column)
            table.minWidth = 40
            table.resizingMask = []
            table.headerCell.alignment = column == .size ? .right : .left
            table.sortDescriptorPrototype = NSSortDescriptor(key: column.sort.rawValue,
                                                             ascending: column.sort.startsAscending)
            outline.addTableColumn(table)
        }
    }

    // MARK: Building

    func reload() {
        guard let model = browser?.model else { return }
        let options = model.options
        func row(for entry: CanvasFolderEntry) -> CanvasFolderRow {
            let row = rows[entry.key] ?? CanvasFolderRow()
            row.entry = entry
            row.children = entry.isFolder ? (model.children[entry.url]?.entries.map(row(for:)) ?? []) : []
            rows[entry.key] = row
            return row
        }
        let kept = outline.selectedURLs
        if options.group == .none {
            top = model.listing.entries.map(row(for:))
        } else {
            top = options.group.groups(of: model.listing.entries).map { group in
                let heading = groupRows[group.title] ?? CanvasFolderRow()
                heading.title = group.title
                heading.count = group.entries.count
                heading.children = group.entries.map(row(for:))
                groupRows[group.title] = heading
                return heading
            }
        }
        applySortIndicator(options)
        outline.reloadData()
        for heading in top where heading.isGroup { outline.expandItem(heading) }
        expandOpened(top, opened: model.expanded)
        select(kept, scrolling: false)
        if let dropTarget = model.dropTarget { showDropTarget(dropTarget) }
        fitColumns(to: browser?.listScroll.contentSize.width ?? outline.bounds.width)
    }

    private func expandOpened(_ rows: [CanvasFolderRow], opened: Set<URL>) {
        for row in rows {
            if let url = row.url, opened.contains(url), !outline.isItemExpanded(row) { outline.expandItem(row) }
            expandOpened(row.children, opened: opened)
        }
    }

    private func applySortIndicator(_ options: CanvasFolderOptions) {
        applyingSort = true
        outline.sortDescriptors = [NSSortDescriptor(key: options.sort.rawValue, ascending: options.ascending)]
        applyingSort = false
    }

    /// Show the columns the card asks for that fit its width, in the Finder's order: first at their own
    /// widths, then — if that would leave one off — with the dates written short, and only then without
    /// the ones that still don't fit, last first.
    func fitColumns(to width: CGFloat) {
        guard let options = browser?.model.options, width > 0 else { return }
        let shown = Self.columnsThatFit(options.orderedColumns, in: width)
        var used: CGFloat = 0
        for column in CanvasFolderColumn.allCases {
            guard let table = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            else { continue }
            let visible = shown.columns.contains(column)
            table.isHidden = !visible
            if visible {
                let wanted = Self.width(of: column, dateWidth: shown.dateWidth)
                if table.width != wanted { table.width = wanted }
                used += wanted + Self.spacing
            }
        }
        if let name = outline.tableColumn(withIdentifier: Self.nameID) {
            let wanted = max(name.minWidth, width - used - Self.inset - Self.spacing)
            if abs(name.width - wanted) > 0.5 { name.width = wanted }
        }
    }

    /// Which of `wanted` fit beside a Name column of at least `nameMinimum` in `width`, and how wide
    /// the dates are for them to: the widest date that fits them all, else whichever shows the most.
    static func columnsThatFit(_ wanted: [CanvasFolderColumn], in width: CGFloat)
        -> (columns: [CanvasFolderColumn], dateWidth: CGFloat) {
        func fitting(_ dateWidth: CGFloat) -> [CanvasFolderColumn] {
            var room = width - inset - nameMinimum
            var shown: [CanvasFolderColumn] = []
            for column in wanted {
                let needs = Self.width(of: column, dateWidth: dateWidth) + spacing
                guard room >= needs else { break }
                shown.append(column)
                room -= needs
            }
            return shown
        }
        var best: (columns: [CanvasFolderColumn], dateWidth: CGFloat) = ([], dateWidths[0])
        for dateWidth in dateWidths {
            let shown = fitting(dateWidth)
            if shown.count == wanted.count { return (shown, dateWidth) }
            if shown.count > best.columns.count { best = (shown, dateWidth) }
        }
        return best
    }

    // MARK: Selection

    func urls(at indexes: IndexSet) -> [URL] {
        indexes.compactMap { (outline.item(atRow: $0) as? CanvasFolderRow)?.url }
    }

    func row(of url: URL) -> Int? {
        guard let item = rows[CanvasFolderEntry.key(url)] else { return nil }
        let row = outline.row(forItem: item)
        return row >= 0 ? row : nil
    }

    func select(_ urls: [URL], scrolling: Bool) {
        let indexes = IndexSet(urls.compactMap(row(of:)))
        outline.selectRowIndexes(indexes, byExtendingSelection: false)
        if scrolling, let first = indexes.first { outline.scrollRowToVisible(first) }
    }

    func showDropTarget(_ url: URL?) {
        if let dropRow, let index = Optional(outline.row(forItem: dropRow)), index >= 0 {
            outline.rowView(atRow: index, makeIfNecessary: false)?.isTargetForDropOperation = false
        }
        dropRow = url.flatMap { rows[CanvasFolderEntry.key($0)] }
        if let dropRow, let index = Optional(outline.row(forItem: dropRow)), index >= 0 {
            outline.rowView(atRow: index, makeIfNecessary: false)?.isTargetForDropOperation = true
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        browser?.updateStatus()
        browser?.actions.selectionChanged()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let clicked = outline.clickedRow
        guard clicked >= 0, let item = outline.item(atRow: clicked) as? CanvasFolderRow, let url = item.url else { return }
        let selected = outline.selectedURLs
        browser?.actions.open(selected.contains(url) ? selected : [url])
    }

    // MARK: Renaming

    func beginRename(_ url: URL) {
        guard let row = row(of: url) else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        renaming = url
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CanvasFolderNameCell else { return }
        cell.isRenaming = true
        outline.editColumn(0, row: row, with: nil, select: true)
        if outline.window?.firstResponder !== cell.textField?.currentEditor() {
            outline.window?.makeFirstResponder(cell.textField)
        }
        cell.selectStem()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = outline.row(for: field)
        guard row >= 0, let item = outline.item(atRow: row) as? CanvasFolderRow, let entry = item.entry else { return }
        renaming = nil
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CanvasFolderNameCell)?.isRenaming = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.url.lastPathComponent, name != entry.name else {
            field.stringValue = entry.name
            return
        }
        if browser?.actions.rename(entry.url, to: name) == nil { field.stringValue = entry.name }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
            let row = outline.row(for: field)
            if row >= 0, let entry = (outline.item(atRow: row) as? CanvasFolderRow)?.entry { field.stringValue = entry.name }
            renaming = nil
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CanvasFolderNameCell)?.isRenaming = false
            outline.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? CanvasFolderRow else { return top.count }
        return row.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? CanvasFolderRow else { return top[index] }
        return row.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? CanvasFolderRow else { return false }
        return row.isGroup || row.entry?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? CanvasFolderRow)?.isGroup == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? CanvasFolderRow)?.isGroup != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? CanvasFolderRow)?.isGroup != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? CanvasFolderRow)?.isGroup != true
    }

    /// Opening a triangle reads the folder then and there, so its rows are ready when the outline asks.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let row = item as? CanvasFolderRow else { return false }
        if row.isGroup { return true }
        guard let model = browser?.model, let entry = row.entry, entry.isFolder else { return false }
        model.expand(entry.url)
        row.children = (model.children[entry.url]?.entries ?? []).map { child in
            let made = rows[child.key] ?? CanvasFolderRow()
            made.entry = child
            rows[child.key] = made
            return made
        }
        return true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let row = notification.userInfo?["NSObject"] as? CanvasFolderRow, let url = row.url else { return }
        browser?.model.collapse(url)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? CanvasFolderRow)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSort, let first = outlineView.sortDescriptors.first, let key = first.key,
              let sort = CanvasFolderSort(rawValue: key) else { return }
        browser?.change("Sort by \(sort.title)") { options in
            options.sort = sort
            options.reversed = first.ascending != sort.startsAscending
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier == Self.nameID else { return nil }
        return (item as? CanvasFolderRow)?.entry?.name
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        CanvasFolderRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? CanvasFolderRow, let options = browser?.model.options else { return nil }
        if row.isGroup {
            let cell = reuse(CanvasFolderGroupCell.self, as: "group")
            cell.show(row.title, count: row.count)
            return cell
        }
        guard let entry = row.entry, let id = tableColumn?.identifier else { return nil }
        if id == Self.nameID {
            let cell = reuse(CanvasFolderNameCell.self, as: "name")
            cell.show(entry, previews: options.iconPreviews)
            cell.textField?.delegate = self
            return cell
        }
        guard let column = CanvasFolderColumn(rawValue: id.rawValue) else { return nil }
        let cell = reuse(CanvasFolderDetailCell.self, as: "detail")
        cell.show(entry, column: column, relativeDates: options.relativeDates)
        return cell
    }

    private func reuse<Cell: NSView>(_ type: Cell.Type, as name: String) -> Cell {
        let id = NSUserInterfaceItemIdentifier(name)
        if let made = outline.makeView(withIdentifier: id, owner: nil) as? Cell { return made }
        let cell = Cell(frame: .zero)
        cell.identifier = id
        return cell
    }
}

/// A row that can say files would be filed into it.
private final class CanvasFolderRowView: NSTableRowView {
    override var isTargetForDropOperation: Bool {
        didSet { needsDisplay = true }
    }
}

/// A group's heading: its name, and how many it holds.
final class CanvasFolderGroupCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
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
}

/// The Name column: icon, name, tags, and where the file stands with its cloud drive.
final class CanvasFolderNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(string: "")
    private let tagDots = CanvasFolderTagDots()
    private let syncMark = NSImageView()
    private var shown: CanvasFolderEntry?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = false
        name.isSelectable = false
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        name.focusRingType = .none
        syncMark.imageScaling = .scaleProportionallyDown
        [icon, name, tagDots, syncMark].forEach(addSubview)
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            tagDots.emphasized = backgroundStyle == .emphasized
            tintSync()
        }
    }

    /// Editable only while a rename is under way, so a click on a name selects its row as a click
    /// anywhere else on it does — and a slip doesn't start retyping a file's name.
    var isRenaming = false {
        didSet {
            name.isEditable = isRenaming
            name.isSelectable = isRenaming
            name.drawsBackground = isRenaming
            name.isBordered = isRenaming
        }
    }

    func show(_ entry: CanvasFolderEntry, previews: Bool) {
        shown = entry
        if isRenaming { isRenaming = false }
        name.stringValue = entry.name
        name.toolTip = entry.name
        icon.image = CanvasFolderIcons.icon(for: entry, side: 16, previews: previews) { [weak self] picture in
            guard self?.shown?.url == entry.url else { return }
            self?.icon.image = picture
        }
        tagDots.tags = entry.tags
        tagDots.toolTip = entry.tags.map(\.name).joined(separator: ", ")
        syncMark.image = CanvasFolderIcons.syncSymbol(entry.sync)
        syncMark.toolTip = entry.sync.help
        tintSync()
        needsLayout = true
    }

    private func tintSync() {
        guard let entry = shown else { return }
        if backgroundStyle == .emphasized {
            syncMark.contentTintColor = .alternateSelectedControlTextColor
        } else if case .failed = entry.sync {
            syncMark.contentTintColor = .systemRed
        } else {
            syncMark.contentTintColor = .secondaryLabelColor
        }
    }

    /// Select the name without its extension, as the Finder's rename does.
    func selectStem() {
        guard let editor = name.currentEditor() else { return }
        let text = name.stringValue as NSString
        let ext = text.pathExtension
        let isFolder = shown?.isFolder == true
        let length = ext.isEmpty || isFolder ? text.length : text.length - ext.count - 1
        editor.selectedRange = NSRange(location: 0, length: max(0, length))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
        var right = bounds.width
        let hasSync = syncMark.image != nil
        syncMark.isHidden = !hasSync
        if hasSync {
            right -= 16
            syncMark.frame = NSRect(x: right, y: (h - 14) / 2, width: 14, height: 14)
            right -= 4
        }
        let dots = tagDots.intrinsicContentSize.width
        let textX: CGFloat = 21
        let natural = ceil(name.attributedStringValue.size().width) + 6
        let textWidth = max(20, min(natural, right - textX - (dots > 0 ? dots + 4 : 0)))
        name.frame = NSRect(x: textX, y: (h - 16) / 2, width: textWidth, height: 16)
        tagDots.isHidden = dots == 0
        tagDots.frame = NSRect(x: textX + textWidth + 2, y: (h - 10) / 2, width: dots, height: 10)
    }
}

/// A date, a size or a kind. A date is written as long as its column has room for — "Today at
/// 9:12 AM", then "Oct 23, 2026", then "10/23/26" — the way the Finder's date columns give way.
final class CanvasFolderDetailCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var date: Date?
    private var relative = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ entry: CanvasFolderEntry, column: CanvasFolderColumn, relativeDates: Bool) {
        label.alignment = column == .size ? .right : .left
        relative = relativeDates
        switch column {
        case .size:
            date = nil
            label.stringValue = entry.isFolder ? "--" : entry.size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "--"
        case .kind:
            date = nil
            label.stringValue = entry.kind
        case .modified: date = entry.modified
        case .created: date = entry.created
        case .opened: date = entry.opened
        case .added: date = entry.added
        }
        if column.isDate { fitDate() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 2, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 4), height: 15)
        if date != nil || label.stringValue.isEmpty { fitDate() }
    }

    private func fitDate() {
        guard let date else {
            if label.stringValue.isEmpty { label.stringValue = "--" }
            return
        }
        let room = max(0, bounds.width - 6)
        let font = label.font ?? .systemFont(ofSize: 11.5)
        let candidates = Self.dateStrings(date, relative: relative)
        label.stringValue = candidates.first {
            room == 0 || ($0 as NSString).size(withAttributes: [.font: font]).width <= room
        } ?? candidates.last ?? ""
    }

    /// A date written longest first: with the time, as a date, then short.
    static func dateStrings(_ date: Date, relative: Bool, now: Date = Date(),
                            calendar: Calendar = .current) -> [String] {
        let time = date.formatted(date: .omitted, time: .shortened)
        if relative {
            if calendar.isDate(date, inSameDayAs: now) { return ["Today at \(time)", "Today, \(time)", "Today"] }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(date, inSameDayAs: yesterday) {
                return ["Yesterday at \(time)", "Yesterday, \(time)", "Yesterday"]
            }
        }
        let long = date.formatted(date: .abbreviated, time: .omitted)
        let short = date.formatted(date: .numeric, time: .omitted)
        return ["\(long) at \(time)", long, short]
    }
}

/// A file's tags, as the Finder draws them: overlapping dots, ringed in the row's colour.
final class CanvasFolderTagDots: NSView {
    var tags: [CanvasFolderTag] = [] {
        didSet { if tags != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }
    static let side: CGFloat = 9
    private var colored: [CanvasFolderTag] { tags.filter { $0.color > 0 } }

    override var intrinsicContentSize: NSSize {
        let count = min(3, colored.count)
        return NSSize(width: count == 0 ? 0 : Self.side + CGFloat(count - 1) * 5, height: Self.side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = NSWorkspace.shared.fileLabelColors
        for (index, tag) in colored.prefix(3).enumerated().reversed() {
            let rect = NSRect(x: CGFloat(index) * 5, y: (bounds.height - Self.side) / 2,
                              width: Self.side, height: Self.side)
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            (colors.indices.contains(tag.color) ? colors[tag.color] : .systemGray).setFill()
            dot.fill()
            (emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.controlBackgroundColor).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }
}

/// The pictures a folder card draws: icons, Quick Look previews where the card wants them, and the
/// sync marks.
@MainActor
enum CanvasFolderIcons {
    /// The icon for `entry` now, and its preview later through `arrived` when Quick Look has one. An
    /// alias keeps its icon, which carries the arrow; a folder is its icon.
    static func icon(for entry: CanvasFolderEntry, side: CGFloat, previews: Bool,
                     arrived: @escaping (NSImage) -> Void) -> NSImage {
        // An online-only file's icon by its type: the file itself isn't on this Mac to be asked.
        let plain = entry.sync == .onlineOnly
            ? NSWorkspace.shared.icon(for: entry.type ?? .data)
            : NSWorkspace.shared.icon(forFile: entry.url.path)
        guard previews, !entry.isFolder, !entry.isAlias, entry.sync != .onlineOnly else { return plain }
        if let cached = CanvasFolderThumbnails.shared.cached(for: entry, side: side) { return cached }
        Task { @MainActor in
            if let picture = await CanvasFolderThumbnails.shared.image(for: entry, side: side) { arrived(picture) }
        }
        return plain
    }

    /// The status column's mark, or nil for a file that is simply here.
    static func syncSymbol(_ sync: CanvasFolderSync) -> NSImage? {
        let name: String
        switch sync {
        case .none: return nil
        case .onlineOnly: name = "icloud.and.arrow.down"
        case .uploading: name = "icloud.and.arrow.up"
        case .downloading: name = "arrow.down.circle"
        case .failed: name = "exclamationmark.icloud"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: sync.help)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }
}
