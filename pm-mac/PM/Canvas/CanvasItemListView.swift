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
    private let split = NSSplitView()
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
        case header(frame: String?, label: String)
        case item(CanvasItem)
        /// The add row at the foot of a section (D6). Carries the frame it would add into.
        case add(frame: String?)

        var item: CanvasItem? { if case .item(let item) = self { return item }; return nil }
        var isHeader: Bool { if case .header = self { return true }; return false }
        var frame: String? {
            switch self {
            case .header(let frame, _): return frame
            case .item(let item): return item.frame
            case .add(let frame): return frame
            }
        }
    }

    init(store: CanvasDocumentStore) {
        self.store = store
        super.init(frame: .zero)
        build()
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
    static let rowHeight: CGFloat = 32
    /// How far a wrapped title is allowed to go before it truncates after all. Past four lines a row
    /// stops being a row.
    static let titleLines = 4
    static let headerHeight: CGFloat = 26
    /// What the floating header chrome covers at the top of the pane — `CanvasPaneController`'s drop.
    static let headerBand: CGFloat = 56

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
            let head: [Line] = section.label.map { [.header(frame: section.frame, label: $0)] } ?? []
            return head + section.items.map(Line.item) + [.add(frame: section.frame)]
        }
        // A board with nothing on it still offers the one row that puts something on it.
        if lines.isEmpty { lines = [.add(frame: nil)] }
        heights = [:]
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
    fileprivate func beginAdding(in frame: String?) {
        guard let row = lines.firstIndex(of: .add(frame: frame)) else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CanvasItemAddCell else { return }
        window?.makeFirstResponder(cell.field)
    }

    fileprivate func added(_ text: String, in frame: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd(frame, text)
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
        let detail = item.detail.map {
            Self.measure($0, font: CanvasItemCell.detailFont, width: width, lines: 1)
        } ?? 0
        let height = max(Self.rowHeight, ceil(title + detail) + CanvasItemCell.padding * 2)
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
        case .header(_, let label):
            let cell = reuse(CanvasItemHeaderCell.self, in: tableView, as: "header")
            cell.label.stringValue = label
            return cell
        case .item(let item):
            let cell = reuse(CanvasItemCell.self, in: tableView, as: "item")
            cell.show(item, icon: icon(item.kind))
            return cell
        case .add(let frame):
            let cell = reuse(CanvasItemAddCell.self, in: tableView, as: "add")
            cell.onSubmit = { [weak self] text in self?.added(text, in: frame) }
            return cell
        }
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

/// A frame's name over its items (D3) — a section header, not a row you can act on.
private final class CanvasItemHeaderCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One item: what it is, what it is called, and — where it has one — the line under it.
///
/// The title wraps and the row grows to hold it — see `CanvasItemListView.rowHeight`, which measures
/// exactly what this lays out.
private final class CanvasItemCell: NSTableCellView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.systemFont(ofSize: 11)
    /// The room above and below the text.
    static let padding: CGFloat = 7
    /// Everything across the row that is not the text: the leading inset, the symbol, the gap after it
    /// and the trailing inset. What the measurement has to take off the column's width.
    static let textInset: CGFloat = 6 + 18 + 8 + 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
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
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [symbol, text])
        row.orientation = .horizontal
        // **Top, not centre**, now that a row can be three lines tall: an icon floating beside the
        // middle of a wrapped title reads as belonging to no line of it. A one-line row is the same
        // either way, which is most of them.
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 18),
            // The symbol sits on the title's first line rather than at the very top of the text block.
            symbol.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.padding),
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

    func show(_ item: CanvasItem, icon: NSImage?) {
        symbol.image = icon
        title.stringValue = item.title
        detail.stringValue = item.detail ?? ""
        detail.isHidden = item.detail == nil
        toolTip = [item.title, item.detail].compactMap { $0 }.joined(separator: "\n")
    }
}

/// The row that makes a new item (D6): a field at the foot of its section, the way the task column
/// adds a task. Type a name and get a card; paste a URL and get a web card.
final class CanvasItemAddCell: NSTableCellView, NSTextFieldDelegate {
    let field = NSTextField()
    var onSubmit: (String) -> Void = { _ in }

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
        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            plus.widthAnchor.constraint(equalToConstant: 14),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
