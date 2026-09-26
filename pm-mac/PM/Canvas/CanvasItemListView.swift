import AppKit
import PmLib

/// The board as a list of items (docs/items.md D3, D5, D7) — a row per card, grouped by frame.
///
/// **A table, not a drawing of one.** Multi-select, ⇧ and ⌘ clicking, arrow keys, type-select, a
/// contextual menu over the selection, dragging rows out: every one of those is what `NSTableView`
/// *is*, and a list that reimplemented them would get a handful subtly wrong on the first day and the
/// rest never. It is also what makes this surface testable headlessly, which a SwiftUI list in a
/// bundle that is never the active app is not (`PMViewTests`).
///
/// **Nothing is rendered to draw it.** Rows come from `CanvasItems`, which names a card the way the
/// board does when it is zoomed out past reading — no page woken up, no markdown laid out, no picture
/// taken. A board of forty cards is forty renderers; this is forty rows of text, which is the whole
/// reason the lens is lighter than the thing it is a lens on.
///
/// What a row *does* is not here. The list reports — open this, peek at that, delete these — and the
/// pane, which has the board, does it.
/// The right-hand half of the list lens (docs/items.md D11) — what the rows are navigating.
///
/// **A seam, and only because of what is on either side of it.** The half itself is a board tiled to
/// the selection (`CanvasItemDetailView`), and a board pulls in most of the app; the list is a table
/// and is driven headlessly in `PMViewTests`, which compiles the files under test and nothing else.
/// Three calls is the whole of what the rows have to say to the thing beside them, so the list says
/// them to a protocol and the pane — which has a board already — supplies the half that answers.
@MainActor
protocol CanvasItemDetailPane: NSView {
    /// The selection changed: show these, in the order the rows draw them.
    func show(_ ids: [String])
    /// The document changed underneath, and the selection didn't.
    func refresh(_ ids: [String])
    /// The lens is finished with — see `CanvasPaneController.teardown`.
    func teardown()
}

@MainActor
final class CanvasItemListView: NSView {
    private let store: CanvasDocumentStore
    private let table = CanvasItemTable()
    private let scroll = NSScrollView()
    private let split = CanvasItemSplitView()
    /// The right-hand half of the split, which the detail is mounted into. A view of its own so the
    /// split has both its halves from the start, whether or not anybody has supplied a detail.
    private let detailHost = NSView()
    /// What the rows are navigating (docs/items.md D11). Supplied by whoever built the lens.
    var detail: (any CanvasItemDetailPane)? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let detail else { return }
            detail.translatesAutoresizingMaskIntoConstraints = false
            detailHost.addSubview(detail)
            NSLayoutConstraint.activate([
                detail.topAnchor.constraint(equalTo: detailHost.topAnchor),
                detail.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
                detail.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor),
            ])
            detail.show(selection)
        }
    }

    /// What the app knows that the document doesn't — see `CanvasExistingCards.lookups`.
    var lookups: CanvasItemLookups = .plain { didSet { reload() } }
    /// Which sort orders the rows (D4).
    var sort: CanvasItemSort = .reading { didSet { reload() } }
    /// One frame's items rather than the whole board, for a frame tab. Nil is the board.
    var frame_: String? { didSet { reload() } }
    /// The icon beside a row: the site's own for a page when the app has it, else the card's symbol.
    var icon: (CanvasItem.Kind) -> NSImage? = { kind in
        switch kind {
        case .page: return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case .file(let symbol), .view(let symbol):
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        case .text: return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }
    } {
        didSet { table.reloadData() }
    }

    /// ⏎ or a double-click: open this item — the board tiled to it, filling the whole pane rather than
    /// the detail half.
    var onOpen: (String) -> Void = { _ in }
    /// ⌫ on a selection.
    var onDelete: ([String]) -> Void = { _ in }
    /// The contextual menu over a selection — the card's own, built by whoever has the board.
    var menuForSelection: ([String]) -> NSMenu? = { _ in nil }
    /// Somebody wants a new item in this section — nil for the board's loose items (D6).
    var onAdd: (String?, String) -> Void = { _, _ in }
    /// Somebody picked a different order from the lens's own menu (D4). The pane keeps it, because it
    /// is remembered per board and shared with the other lens.
    var onSort: (CanvasItemSort) -> Void = { _ in }
    /// Something was dropped on a section (D7): which frame — nil for the board's loose items, which
    /// means the Inbox, exactly as that section's add row does — and what was dropped. True if it was
    /// taken, which is what tells AppKit whether to slide the drag back.
    var onDrop: (String?, NSPasteboard) -> Bool = { _, _ in false }
    /// Which items are selected, in the order the list draws them.
    var selection: [String] { rows(at: table.selectedRowIndexes).compactMap(\.item?.id) }
    var onSelectionChanged: ([String]) -> Void = { _ in }

    /// The frame the selection is in, which is the section a new item joins when nothing says
    /// otherwise (docs/items.md D6). Nil for a selection that is loose on the board, and for none.
    var selectedFrame: String? {
        table.selectedRowIndexes.first.flatMap { lines.indices.contains($0) ? lines[$0].frame : nil }
    }

    /// The card a row is, or nil for a section header and for an add row. What anything holding a row
    /// number rather than an id has to ask.
    func idOfRow(_ row: Int) -> String? { lines.indices.contains(row) ? lines[row].item?.id : nil }

    /// Give the list the keyboard — what the pane does on switching to it.
    func takeFocus() { window?.makeFirstResponder(table) }

    private var sections: [CanvasItemSection] = []
    /// The frames whose sections are folded to their header, remembered per board on this Mac.
    private var folded: Set<String> = []
    /// The section a `+` opened an add row in, while it is open. The outer optional is "adding at
    /// all", the inner one the frame — nil being the board's loose items.
    private var adding: String?? = nil
    private var foldedKey: String { "CanvasItemListFolded " + store.url.standardizedFileURL.path }
    private var lines: [Line] = []
    /// How tall each item's row came out, by id — see `rowHeight`. Thrown away whenever the answer
    /// could have changed: the rows were re-read, or the column they are laid out in got another width.
    private var heights: [String: CGFloat] = [:]
    /// The width the cached heights were measured at, which is the list half's own — told by the
    /// split rather than read off the table, because the table learns its new width a layout pass
    /// after the divider decides it.
    private var measuredAt: CGFloat = 0

    /// One line of the table: a frame's header, an item, or the row that makes a new one.
    private enum Line: Equatable {
        case header(frame: String?, label: String, count: Int)
        case item(CanvasItem)
        /// The add row at the foot of a section (D6). Carries the frame it would add into.
        case add(frame: String?)

        var item: CanvasItem? { if case .item(let item) = self { return item }; return nil }
        var isHeader: Bool { if case .header = self { return true }; return false }
        var frame: String? {
            switch self {
            case .header(let frame, _, _): return frame
            case .item(let item): return item.frame
            case .add(let frame): return frame
            }
        }
    }

    init(store: CanvasDocumentStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        folded = Set(UserDefaults.standard.stringArray(forKey: foldedKey) ?? [])
        store.addWatcher(self, changed: { [weak self] in self?.reload() }, reloaded: { [weak self] in self?.reload() })
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Stop being told about writes. Called by whoever owns the lens when it is finished with, for
    /// the reason `CanvasPaneController.teardown` gives — and safe to call twice.
    func stopWatching() {
        store.removeWatcher(self)
        detail?.teardown()
    }

    // MARK: Building

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        // The section headers stay put as their items scroll under them, which is what makes a long
        // board readable: you never lose which frame you are in.
        table.floatsGroupRows = true
        // A sliver of ground between rows, so the one card that is lifted (`CanvasItemRowView`) stands
        // clear of its neighbours.
        table.intercellSpacing = NSSize(width: 0, height: Self.rowGap)
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.owner = self
        table.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        // `.move` inside the app, because a row dragged to another section *is* the card moving there
        // (D7). Outside it a row is a link or a file, and moving one of those means something else.
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        // What the board takes, plus the board's own clipping and the rows' own flavour: a list should
        // accept everything the board it is a lens on would have accepted.
        table.registerForDraggedTypes([CanvasItemRows.pasteboardType, CanvasClipping.pasteboardType,
                                       .fileURL, .URL, .string] + NoteImagePasteboard.imageTypes)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The header band floats over the top of the pane, as it does over the board. Rows start below
        // it and scroll up under it, the way a Mac window's content does.
        scroll.contentInsets = NSEdgeInsets(top: Self.headerBand, left: 0, bottom: 12, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: Self.headerBand, left: 0, bottom: 0, right: 0)

        // **The rows and what they are pointing at, side by side** (D11). A split view rather than two
        // panes laid out by hand, because the width of the list is a thing people move and expect to
        // stay moved: `autosaveName` is what remembers it, and it is per app rather than per board
        // because it is a shape of the window, not a fact about a canvas.
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "CanvasItemLens"
        split.delegate = self
        // **Both halves are frame-based, which is deliberate.** Hand a split view subviews that lay
        // themselves out by constraints and it stops sizing them itself: `setPosition` is then
        // discarded on the next solve, and a width constraint is what decides the division. That is a
        // workable arrangement and not this one — the divider is dragged, and what it is dragged to
        // has to stick without a constraint to fight. So the split sizes its halves, and `layout`
        // below tells it where to start.
        scroll.translatesAutoresizingMaskIntoConstraints = true
        detailHost.translatesAutoresizingMaskIntoConstraints = true
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailHost)

        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// How wide the list starts, before anybody has dragged the divider — wide enough for a title and
    /// its detail line, narrow enough that the item you picked is the larger half.
    static let listWidth: CGFloat = 320
    static let narrowestList: CGFloat = 220
    static let narrowestDetail: CGFloat = 260

    /// Give the divider its first position — once, and only if nobody has ever moved it.
    ///
    /// `autosaveName` is AppKit's own memory of a dragged divider, and it writes the key below. An
    /// even split is what it falls back to with nothing remembered, which is the wrong shape for this
    /// pane: the list needs a title's width and the item needs the rest. So the default is set here,
    /// and only while that key is absent, or every window would undo the drag of the last one.
    /// Where AppKit keeps a split view's dragged position, given its `autosaveName`.
    static let dividerMemoryKey = "NSSplitView Subview Frames CanvasItemLens"

    /// **A row is as tall as what is in it.** The shortest it gets is `rowHeight`, which is what a
    /// title and its detail line need; a title too long for the pane wraps and the row grows to hold
    /// it, up to `titleLines`.
    ///
    /// This was a fixed 32 on the argument that a list of forty items should not measure forty strings
    /// to know how tall it is. The measuring is real and the argument was still wrong: a card's title
    /// is the first line of whatever is written on it, so the long ones are the notes rather than the
    /// links, and truncating every one of them at the same place is the list refusing to show the
    /// difference between two cards that begin alike. Measured strings are cached per width
    /// (`heights`), so forty rows are measured once and then only when the divider moves.
    static let rowHeight: CGFloat = 40
    /// The ground between two rows.
    static let rowGap: CGFloat = 2
    /// How far a wrapped title is allowed to go before it truncates after all. Past four lines a row
    /// stops being a row.
    static let titleLines = 2
    static let headerHeight: CGFloat = 30
    /// Where the lens's content starts under the floating header: the line a workspace's tiles start
    /// on (`CanvasBoardView.headerClearance` plus the tiling's own edge gap), so the rows, the detail's
    /// tile and a workspace on the board all begin at the same height.
    /// A number rather than that sum, because `PMViewTests` compiles the list without the board.
    static let headerBand: CGFloat = 46

    // MARK: Reading the document

    /// Re-read the document and redraw, keeping whatever is still there selected.
    ///
    /// **Selection is kept by id**, not by row: a card added above the one you had picked must not move
    /// the selection to its neighbour, and a card deleted elsewhere must not clear it.
    func reload() {
        let kept = Set(selection)
        let document = store.document
        if let frame_, let node = document.node(id: frame_) {
            let inside = CanvasItems.sections(of: document, sort: sort, lookups: lookups)
                .first { $0.frame == frame_ }
            sections = [inside ?? CanvasItemSection(frame: frame_, label: canvasFrameLabel(node), items: [])]
        } else {
            sections = CanvasItems.sections(of: document, sort: sort, lookups: lookups)
        }
        lines = sections.flatMap { section -> [Line] in
            // The board's loose items have no header to carry a `+`, so their add row stays.
            guard let label = section.label else { return section.items.map(Line.item) + [.add(frame: section.frame)] }
            let head = Line.header(frame: section.frame, label: label, count: section.items.count)
            if let frame = section.frame, folded.contains(frame) { return [head] }
            let add: [Line] = adding == .some(section.frame) ? [.add(frame: section.frame)] : []
            return [head] + section.items.map(Line.item) + add
        }
        // A board with nothing on it still offers the one row that puts something on it.
        if lines.isEmpty { lines = [.add(frame: nil)] }
        heights = [:]
        excerpts = [:]
        table.reloadData()
        let restored = IndexSet(lines.indices.filter { kept.contains(lines[$0].item?.id ?? "") })
        table.selectRowIndexes(restored, byExtendingSelection: false)
        // **After the selection is back, and unconditionally.** The rows are the same rows, so
        // `tableViewSelectionDidChange` may not fire at all — and this reload happened *because* the
        // document changed, which is exactly when what the detail is showing has gone stale.
        detail?.refresh(selection)
    }

    /// Put the selection somewhere by id — what a lens is told after the board has acted.
    func select(_ ids: [String]) {
        let wanted = Set(ids)
        let rows = IndexSet(lines.indices.filter { wanted.contains(lines[$0].item?.id ?? "") })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    private func rows(at indexes: IndexSet) -> [Line] { indexes.compactMap { lines.indices.contains($0) ? lines[$0] : nil } }

    /// The item a command means: the row that was right-clicked when it isn't in the selection, else
    /// everything selected. The rule every Mac contextual menu keeps.
    fileprivate func targets(for row: Int) -> [String] {
        guard lines.indices.contains(row), let item = lines[row].item else { return [] }
        if table.selectedRowIndexes.contains(row) { return selection }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return [item.id]
    }

    // MARK: What a row does

    @objc private func openClicked() {
        guard lines.indices.contains(table.clickedRow) else { return }
        switch lines[table.clickedRow] {
        case .item(let item): onOpen(item.id)
        case .add(let frame): beginAdding(in: frame)
        case .header: break
        }
    }

    /// The menu for a press that isn't on an item — a header, the add row, the space under the last
    /// section. **The order, which is the only thing a list has that is about the list.** In the View
    /// menu too, and here because a right-click where the rows are is where somebody looking for it
    /// would press, and because this menu would otherwise be nothing at all.
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

    /// Start typing a new item into a section (D6). The field is the row, in place, so adding is one
    /// gesture from the list rather than a dialog over it.
    func beginAdding(in frame: String?) {
        if lines.firstIndex(of: .add(frame: frame)) == nil {
            adding = .some(frame)
            if let frame { folded.remove(frame) }
            reload()
        }
        guard let row = lines.firstIndex(of: .add(frame: frame)) else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CanvasItemAddCell else { return }
        window?.makeFirstResponder(cell.field)
    }

    /// The add row a `+` opened goes when its field is given up, typed in or not. Later rather than
    /// now: this is called from inside the field ending its edit, and a reload takes the field away.
    fileprivate func endedAdding(in frame: String?) {
        guard adding == .some(frame) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.adding == .some(frame) else { return }
            self.adding = nil
            self.reload()
        }
    }

    /// Fold a frame's section to its header, or open it again.
    func toggleFold(_ frame: String) {
        if folded.remove(frame) == nil { folded.insert(frame) }
        UserDefaults.standard.set(Array(folded).sorted(), forKey: foldedKey)
        reload()
    }

    fileprivate func added(_ text: String, in frame: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd(frame, text)
    }

    // MARK: What a row says under its title

    /// The line under a row's title, as the list shows it: for a file, **the folder it's in by name**,
    /// not its path — and nothing for one in this board's own `docs`, where every doc card lives
    /// (`CanvasDocCards`). A vault path repeats the project on every row, and a `docs` or `resources`
    /// says less than the folder that holds it, so the name shown is the last one that isn't those.
    /// A page's line is its host, as the item has it.
    func shownDetail(of item: CanvasItem) -> String? {
        guard case .file = item.kind else { return item.detail }
        guard let parent = item.detail else { return nil }
        let own = CanvasDocCards.folder(forCanvasAt: store.url)
        if parent == own.path || parent == store.resolver.storablePath(for: own) { return nil }
        let generic: Set<String> = ["docs", "resources"]
        return parent.split(separator: "/").map(String.init).last { !generic.contains($0.lowercased()) }
    }

    /// **What the item says**, one line of it, under the title: the first line of a document or a
    /// text card that isn't its title. Nothing for a page, a folder, or a file that isn't prose.
    /// A document is read from disk once per change to it (`excerpts`).
    func excerpt(of item: CanvasItem) -> String? {
        guard let node = store.document.node(id: item.id) else { return nil }
        switch node.content {
        case .text(let text):
            return Self.firstLine(of: text, besides: item.title)
        case .file(let path, nil):
            guard let url = store.resolver.resolve(path).url else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let known = excerpts[url.path], known.modified == modified { return known.line }
            let line = CanvasSearch.prose(at: path, resolver: store.resolver)
                .flatMap { Self.firstLine(of: $0, besides: item.title) }
            excerpts[url.path] = (modified, line)
            return line
        default:
            return nil
        }
    }

    private var excerpts: [String: (modified: Date?, line: String?)] = [:]

    /// The first line with words on it that isn't `title`, without the markdown that marks it up.
    /// Front matter is skipped.
    static func firstLine(of text: String, besides title: String) -> String? {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        // A long title is clipped with an ellipsis, so a line that *starts* with the title is the title.
        let wanted = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "…")))
            .lowercased()
        for line in lines {
            var clean = line
            if let marker = clean.range(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|>\s*|\d+[.)]\s+)"#,
                                        options: .regularExpression) {
                clean.removeSubrange(marker)
            }
            clean = clean.replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let lower = clean.lowercased()
            if clean.isEmpty || lower.hasPrefix(wanted) || wanted.hasPrefix(lower) { continue }
            return clean
        }
        return nil
    }

    // MARK: How tall a row is

    /// The height this item's row needs, measured once per width. See `rowHeight`.
    private func height(of item: CanvasItem) -> CGFloat {
        if let known = heights[item.id] { return known }
        let width = max(0, measuredAt - CanvasItemCell.textInset)
        let title = Self.measure(item.title, font: CanvasItemCell.titleFont,
                                 width: width, lines: Self.titleLines)
        // The detail line stays one line: it is a URL or a path, and the front of one is the part
        // worth the room. It truncates in the middle, which a wrapped line cannot do.
        let detail = shownDetail(of: item).map {
            Self.measure($0, font: CanvasItemCell.detailFont, width: width, lines: 1) + CanvasItemCell.lineGap
        } ?? 0
        let said = excerpt(of: item).map {
            Self.measure($0, font: CanvasItemCell.excerptFont, width: width, lines: 1) + CanvasItemCell.lineGap
        } ?? 0
        let height = max(Self.rowHeight, ceil(title + detail + said) + CanvasItemCell.padding * 2)
        heights[item.id] = height
        return height
    }

    /// How tall this text lays out in that width, in at most that many lines.
    private static func measure(_ text: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let line = ceil(font.ascender - font.descender + font.leading)
        guard !text.isEmpty else { return 0 }
        guard width > 1 else { return line }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let box = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style])
        return min(max(line, ceil(box.height)), line * CGFloat(lines))
    }

    /// **The rows are measured against a width that somebody can drag.** Dragging the divider narrows
    /// the column, which is exactly when a title that fitted stops fitting — so the cache is thrown
    /// away and the table asked to measure again. Guarded on the width actually having changed,
    /// because the split lays its halves out on every pass and `noteHeightOfRows` causes one.
    fileprivate func remeasure(at width: CGFloat) {
        guard width != measuredAt else { return }
        measuredAt = width
        heights = [:]
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
    }
}

// MARK: - The table's own manners

extension CanvasItemListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { lines[row].isHeader }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let item = lines[row].item else {
            return lines[row].isHeader ? Self.headerHeight : Self.rowHeight
        }
        return height(of: item)
    }

    /// A header and the add row are not things you can select: selecting them would put a command's
    /// target somewhere it cannot act.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { lines[row].item != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let frame, let label, let count):
            let cell = reuse(CanvasItemHeaderCell.self, in: tableView, as: "header")
            cell.show(label, count: count, folded: frame.map(folded.contains) ?? false)
            cell.onToggle = { [weak self] in if let frame { self?.toggleFold(frame) } }
            cell.onAdd = { [weak self] in self?.beginAdding(in: frame) }
            return cell
        case .item(let item):
            let cell = reuse(CanvasItemCell.self, in: tableView, as: "item")
            cell.show(item, icon: icon(item.kind), detail: shownDetail(of: item), says: excerpt(of: item))
            return cell
        case .add(let frame):
            let cell = reuse(CanvasItemAddCell.self, in: tableView, as: "add")
            cell.onSubmit = { [weak self] text in self?.added(text, in: frame) }
            cell.onEnd = { [weak self] in self?.endedAdding(in: frame) }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        reuse(CanvasItemRowView.self, in: tableView, as: "row")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        detail?.show(selection)
        onSelectionChanged(selection)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        lines[row].item.flatMap { CanvasItemRows.item(for: $0.id, in: store) }
    }

    /// **A drop lands in a section, never between two rows** (docs/items.md D7).
    ///
    /// AppKit offers a row and an operation — `.above` for the line between two rows, `.on` for a row
    /// itself — and a list that took the first would be promising an order it does not have: the rows
    /// are *sorted* (D2), so there is no position between two of them for a card to be dropped into.
    /// So wherever the pointer is, the drop is retargeted to the section under it, shown on that
    /// section's own row. The header when it has one — which `floatsGroupRows` keeps on screen however
    /// far down the section you are — and the add row when it hasn't, which is the row that already
    /// means "something new joins here".
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let target = dropTarget(near: row) else { return [] }
        tableView.setDropRow(target.row, dropOperation: .on)
        // Rows of this list are the cards themselves and move; anything from outside is copied in.
        // Said here because the arrow on the drag is the only thing that tells you which it will be.
        let ours = !CanvasItemRows.read(info.draggingPasteboard).isEmpty
        return ours && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard lines.indices.contains(row) else { return false }
        return onDrop(lines[row].frame, info.draggingPasteboard)
    }

    /// Where a drop over `row` would land: the section it joins, and the row to show it on. Nil only
    /// for a list with no lines at all, which cannot happen while the add row exists.
    ///
    /// Answered as a pair rather than left inside `validateDrop`, because these are two questions a
    /// drop has to get right and only one of them is visible — the frame decides where the card ends
    /// up, the row decides what you are told about it before you let go.
    func dropTarget(near row: Int) -> (row: Int, frame: String?)? {
        // `row` is an insertion index when AppKit proposes `.above`, so it can be one past the end.
        let inside = min(max(row, 0), lines.count - 1)
        guard lines.indices.contains(inside) else { return nil }
        let frame = lines[inside].frame
        guard let anchor = lines.firstIndex(where: { $0.isHeader && $0.frame == frame })
                ?? lines.firstIndex(of: .add(frame: frame)) else { return nil }
        return (anchor, frame)
    }

    private func reuse<Cell: NSView>(_ type: Cell.Type, in table: NSTableView, as name: String) -> Cell {
        let id = NSUserInterfaceItemIdentifier(name)
        if let cell = table.makeView(withIdentifier: id, owner: self) as? Cell { return cell }
        let cell = Cell()
        cell.identifier = id
        return cell
    }
}

// MARK: - The two halves

extension CanvasItemListView: NSSplitViewDelegate {
    /// **The list keeps its width and the detail takes the room.** Said here, by laying the two halves
    /// out, because none of the shorter ways work: a split view ignores a width constraint on a half,
    /// at any priority, and discards a `setPosition` made during the layout pass that precedes its own.
    /// Left to itself it divides the pane in two and then keeps the *proportion* through every window
    /// resize, so a wider window means a wider list of one-line rows and no more of the thing you are
    /// reading.
    ///
    /// The list's width is read back off the view each time, which is what makes the other two answers
    /// fall out for free: a divider somebody dragged is a width this reads next time, an
    /// `autosaveName` restore is the same, and the width before either of those have happened is
    /// zero — so the first pass takes the default.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let height = splitView.bounds.height
        let divider = splitView.dividerThickness
        let asked = scroll.frame.width < Self.narrowestList ? Self.listWidth : scroll.frame.width
        let room = max(Self.narrowestList, splitView.bounds.width - Self.narrowestDetail - divider)
        let width = min(asked, room)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        detailHost.frame = NSRect(x: width + divider, y: 0,
                                  width: max(0, splitView.bounds.width - width - divider), height: height)
        remeasure(at: width)
    }

    /// Neither half shrinks past being useful: a list too narrow to read a title in, or a detail too
    /// narrow to show anything the list wasn't already showing.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.narrowestList
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(Self.narrowestList, splitView.bounds.width - Self.narrowestDetail)
    }

    /// **Neither half collapses.** A collapsed detail is the list as it was, which is a state with no
    /// way back that looks like a bug; a collapsed list is a detail of nothing.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

// MARK: - The split

/// The split between the rows and the detail, with **no line drawn**: the rows end and the detail's
/// own edge begins, and a rule between them would be a third thing. Still there to be dragged.
private final class CanvasItemSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {}
}

// MARK: - The table

/// The list's table, which is where the keys are read.
///
/// The commands are the board's — Space peeks, ⏎ opens, ⌫ deletes — so the list keeps the same
/// keystrokes for the same acts rather than inventing a second grammar for the same cards.
private final class CanvasItemTable: NSTableView {
    weak var owner: CanvasItemListView?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        // Space, as it is on the board — "show me this one". On the board that is peek, which draws
        // over the cards; here there are no cards in front of you, so it is the open the board's peek
        // would have shown you, and Escape is the way back from both.
        case " " where !event.modifierFlags.contains(.command):
            owner?.openSelection()
        case "\r", "\u{3}":
            owner?.openSelection()
        case String(UnicodeScalar(NSDeleteCharacter)!), String(UnicodeScalar(NSBackspaceCharacter)!):
            owner?.deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    /// The menu over the row you pressed on, targeted the way every Mac list targets: the selection
    /// when the row is in it, that row alone when it isn't.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard let owner else { return super.menu(for: event) }
        let targets = row >= 0 ? owner.targets(for: row) : []
        guard !targets.isEmpty else { return owner.sortMenu() }
        return owner.menuForSelection(targets)
    }
}

// MARK: - The cells

/// A frame's name over its items (D3), how many there are, and the `+` that adds one. Clicking the
/// name folds the section to this header, or opens it again.
private final class CanvasItemHeaderCell: NSTableCellView {
    private let fold = NSButton()
    private let count = NSTextField(labelWithString: "")
    private let plus = NSButton()
    var onToggle: () -> Void = {}
    var onAdd: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        fold.isBordered = false
        fold.imagePosition = .imageLeading
        fold.imageHugsTitle = true
        fold.contentTintColor = .tertiaryLabelColor
        fold.target = self
        fold.action = #selector(toggle)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        plus.isBordered = false
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add an item")
        plus.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        plus.contentTintColor = .tertiaryLabelColor
        plus.target = self
        plus.action = #selector(add)
        plus.toolTip = "Add an item to this section"
        for view in [fold, count, plus] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            fold.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            fold.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            count.leadingAnchor.constraint(equalTo: fold.trailingAnchor, constant: 5),
            count.firstBaselineAnchor.constraint(equalTo: fold.firstBaselineAnchor),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plus.centerYAnchor.constraint(equalTo: fold.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 18),
            plus.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ label: String, count items: Int, folded: Bool) {
        fold.attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        fold.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down",
                             accessibilityDescription: folded ? "Folded" : "Open")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        fold.setAccessibilityLabel(folded ? "Open \(label)" : "Fold \(label)")
        count.stringValue = "\(items)"
    }

    @objc private func toggle() { onToggle() }
    @objc private func add() { onAdd() }
}

/// One item: what it is, what it is called, and — where it has one — the line under it.
///
/// The title wraps and the row grows to hold it — see `CanvasItemListView.rowHeight`, which measures
/// exactly what this lays out. A row that fits in the shortest height is centred in it; a taller one
/// runs from the top, with its icon on the title's first line.
private final class CanvasItemCell: NSTableCellView {
    private let plate = CanvasItemIconPlate()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let says = NSTextField(labelWithString: "")

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let detailFont = NSFont.systemFont(ofSize: 11)
    /// The room above and below the text.
    static let padding: CGFloat = 10
    static let excerptFont = NSFont.systemFont(ofSize: 12)
    /// The space between the title and each line under it.
    static let lineGap: CGFloat = 1
    /// Everything across the row that is not the text: the leading inset, the icon's plate, the gap
    /// after it and the trailing inset. What the measurement has to take off the column's width.
    static let textInset: CGFloat = 6 + CanvasItemIconPlate.side + 10 + 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Self.titleFont
        // Wrapping, and capped where the measurement caps it. `usesSingleLineMode` off is what makes
        // the cell's own layout agree with `CanvasItemListView.measure`; without it the field lays out
        // one line in a row sized for three.
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = CanvasItemListView.titleLines
        title.cell?.wraps = true
        title.cell?.usesSingleLineMode = false
        detail.font = Self.detailFont
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        // The title gives way to nothing; the detail gives way first when the pane is narrow.
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        says.font = Self.excerptFont
        says.textColor = .secondaryLabelColor
        says.lineBreakMode = .byTruncatingTail
        says.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail, says])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Self.lineGap
        text.translatesAutoresizingMaskIntoConstraints = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        addSubview(text)
        // Centred when it fits, from the top when it doesn't: the centring gives way first.
        let centred = text.centerYAnchor.constraint(equalTo: centerYAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            plate.widthAnchor.constraint(equalToConstant: CanvasItemIconPlate.side),
            plate.heightAnchor.constraint(equalToConstant: CanvasItemIconPlate.side),
            // On the title's first line.
            plate.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor,
                                           constant: -ceil(Self.titleFont.xHeight / 2)),
            text.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.padding),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.padding),
            centred,
        ])
        textField = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A wrapping label has no intrinsic height until it is told how wide it is, and a cell in a table
    /// column learns its width here.
    override func layout() {
        title.preferredMaxLayoutWidth = max(0, bounds.width - Self.textInset)
        super.layout()
    }

    func show(_ item: CanvasItem, icon: NSImage?, detail shown: String?, says said: String?) {
        plate.image = icon
        title.stringValue = item.title
        detail.stringValue = shown ?? ""
        detail.isHidden = shown == nil
        says.stringValue = said ?? ""
        says.isHidden = said == nil
        toolTip = [item.title, item.detail].compactMap { $0 }.joined(separator: "\n")
    }
}

/// The square an item's icon sits on: every row's icon the same size on the same ground, so a site's
/// own dark favicon still shows on a dark list and a symbol and a favicon line up.
final class CanvasItemIconPlate: NSView {
    static let side: CGFloat = 22
    private let imageView = NSImageView()

    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        imageView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
}

/// A row of the list. **Rows rest flat on the ground, and the selected one is backed** the way the
/// header backs its current tab (`CanvasItemSelectionCard`). No accent colour.
private final class CanvasItemRowView: NSTableRowView {
    private let card = CanvasItemSelectionCard()

    override var isSelected: Bool { didSet { placeCard() } }
    /// Never the emphasized (blue) selection, so the text in a selected row keeps its own colours.
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawSeparator(in dirtyRect: NSRect) {
        if isGroupRowStyle { return }
        super.drawSeparator(in: dirtyRect)
    }

    override func layout() {
        super.layout()
        placeCard()
    }

    /// Under the cell, the cell's size: the `.inset` table insets its cells, and the card is the row's
    /// visible extent rather than the row view's.
    private func placeCard() {
        card.isHidden = !isSelected || isGroupRowStyle
        guard !card.isHidden else { return }
        if card.superview !== self { addSubview(card, positioned: .below, relativeTo: nil) }
        let cell = subviews.first { $0 is NSTableCellView }?.frame ?? bounds
        card.frame = NSRect(x: cell.minX, y: bounds.minY, width: cell.width, height: bounds.height)
    }
}

/// The face of the selected row: **the header's current tab** — the text colour at 9%, no edge, no
/// shadow (`ProjectTabBar`'s backing) — so "the one you're on" is drawn one way in the header and in
/// the list. Chosen in the list-lens mock, 2026-09-25.
final class CanvasItemSelectionCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        var fill = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
        layer?.backgroundColor = fill
    }
}

/// The row that makes a new item (D6): a field at the foot of its section, the way the task column
/// adds a task. Type a name and get a card; paste a URL and get a web card.
final class CanvasItemAddCell: NSTableCellView, NSTextFieldDelegate {
    let field = NSTextField()
    var onSubmit: (String) -> Void = { _ in }
    /// The field was given up — see `CanvasItemListView.endedAdding`.
    var onEnd: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "New item"
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let plus = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                               ?? NSImage())
        plus.contentTintColor = .tertiaryLabelColor
        plus.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        plus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plus)
        addSubview(field)
        // In the icon's column and the title's, so the add row lines up with the items above it.
        NSLayoutConstraint.activate([
            plus.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6 + CanvasItemIconPlate.side / 2),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + CanvasItemIconPlate.side + 10 - 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidEndEditing(_ obj: Notification) { onEnd() }

    /// ⏎ makes the item and leaves the field empty and focused, so three things can be added in three
    /// lines without reaching for the mouse. Escape gives the field up.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            field.stringValue = ""
            onSubmit(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            window?.makeFirstResponder(superview)
            return true
        default:
            return false
        }
    }
}
