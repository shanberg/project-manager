import XCTest
import PmLib
@testable import PMViewTests

/// The list lens (docs/items.md D3, D5, D7), driven as a real table in a real window over a real store.
///
/// What is worth pinning is everything a list of rows can get quietly wrong and still look right: a
/// header or an add row that can be selected and so becomes a command's silent target, a selection
/// that jumps to a neighbour when the document changes underneath it, a key that reaches the board's
/// command with the wrong card, and an add row that reports the wrong section.
@MainActor
final class CanvasItemListTests: XCTestCase {

    private var url: URL!
    private var store: CanvasDocumentStore!
    private var list: CanvasItemListView!
    /// The right-hand half, standing in for the real one (docs/items.md D11). The real half is a board
    /// tiled to the selection, and a board is not compiled into this bundle — see
    /// `CanvasItemDetailPane`, which is the whole of what the rows say to it.
    private var detail: DetailPane!
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // One loose card, and a frame with two in it — the smallest board that has both kinds of
        // section in it and an order worth being wrong about.
        let document = CanvasDocument(nodes: [
            CanvasNode(id: "loose", content: .text("A loose note"),
                       frame: CanvasRect(x: 0, y: 0, width: 200, height: 150)),
            CanvasNode(id: "frame", content: .group(label: "Reference", background: nil, backgroundStyle: nil),
                       frame: CanvasRect(x: 0, y: 500, width: 900, height: 400)),
            CanvasNode(id: "first", content: .text("Spec"),
                       frame: CanvasRect(x: 40, y: 560, width: 200, height: 150)),
            CanvasNode(id: "second", content: .link(url: "https://example.com/roadmap"),
                       frame: CanvasRect(x: 300, y: 560, width: 200, height: 150)),
        ])
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-item-list-\(UUID().uuidString).canvas")
        try document.write(to: url)
        store = try CanvasDocumentStore(url: url)
        // The divider's width is remembered per app (`autosaveName`), and a test bundle is an app —
        // so without this a run inherits whatever width the last one left, and the widths below are
        // whatever happened yesterday.
        UserDefaults.standard.removeObject(forKey: CanvasItemListView.dividerMemoryKey)
        list = CanvasItemListView(store: store)
        detail = DetailPane()
        list.detail = detail
        // A harness window: never key unless a test asks, and the ordinary window ground rather than a
        // bright white one — see the rule the other view tests keep.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        list.frame = window.contentView!.bounds
        list.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(list)
        window.layoutIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        list = nil
        detail = nil
        window = nil
        store = nil
        try? FileManager.default.removeItem(at: url)
        try super.tearDownWithError()
    }

    /// The table inside the lens, found the way anything finds a view it did not build.
    private var table: NSTableView {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(list)!
    }

    private func row(of id: String) -> Int {
        for row in 0..<table.numberOfRows where list.idOfRow(row) == id { return row }
        return -1
    }

    private func key(_ characters: String) {
        window.makeFirstResponder(table)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: 0)!
        table.keyDown(with: event)
    }

    // MARK: What it draws

    /// Loose cards under no header, then a section per frame — and an add row at the foot of each, so
    /// the board's own items and the frame's each have somewhere to be added to.
    func testTheBoardIsDrawnAsSectionsWithAnAddRowUnderEach() {
        XCTAssertEqual(table.numberOfRows, 6, "loose, add, header, two items, add")
        XCTAssertEqual(row(of: "loose"), 0)
        XCTAssertGreaterThan(row(of: "first"), row(of: "loose"))
        XCTAssertEqual(row(of: "second"), row(of: "first") + 1, "reading order inside the frame")
    }

    /// A header and an add row are not things a command can act on, and a list that let them be picked
    /// would hand Delete a row with no card behind it.
    func testOnlyItemsCanBeSelected() {
        for row in 0..<table.numberOfRows {
            XCTAssertEqual(table.delegate?.tableView?(table, shouldSelectRow: row) ?? true,
                           list.idOfRow(row) != nil, "row \(row)")
        }
    }

    func testSortingChangesTheOrderWithinASectionOnly() {
        XCTAssertLessThan(row(of: "first"), row(of: "second"), "reading order: left to right")
        // By name the page leads, because a page with no remembered title is called by its host and
        // `example.com` sorts before `Spec`.
        list.sort = .name
        XCTAssertEqual(row(of: "second"), row(of: "first") - 1)
        XCTAssertEqual(row(of: "loose"), 0, "the loose section is still first, whatever the sort")
        list.sort = .kind
        XCTAssertLessThan(row(of: "first"), row(of: "second"), "the text card before the page")
    }

    // MARK: Selection

    func testSelectionIsByCardAndSurvivesTheDocumentChangingUnderneathIt() {
        list.select(["second"])
        XCTAssertEqual(list.selection, ["second"])
        // A card added above it: the row moves, the selection must not.
        store.change("Add") { document in
            document.nodes.insert(CanvasNode(id: "new", content: .text("Added"),
                                             frame: CanvasRect(x: 0, y: 200, width: 200, height: 150)),
                                  at: 0)
        }
        list.reload()
        XCTAssertEqual(list.selection, ["second"])
        XCTAssertEqual(table.selectedRow, row(of: "second"))
    }

    /// Which section a new item would join — what the `+` and ⌘N read (D6).
    func testTheSelectionSaysWhichSectionAnAddWouldJoin() {
        list.select(["second"])
        XCTAssertEqual(list.selectedFrame, "frame")
        list.select(["loose"])
        XCTAssertNil(list.selectedFrame, "a loose card is in no frame")
    }

    // MARK: The keys

    func testReturnOpensTheSelectedItem() {
        var opened: [String] = []
        list.onOpen = { opened.append($0) }
        list.select(["first"])
        key("\r")
        XCTAssertEqual(opened, ["first"])
    }

    /// Space means "show me this one" in both lenses — see the board's peek.
    func testSpaceOpensTooRatherThanTypingIntoTheList() {
        var opened: [String] = []
        list.onOpen = { opened.append($0) }
        list.select(["second"])
        key(" ")
        XCTAssertEqual(opened, ["second"])
    }

    func testDeleteReportsTheWholeSelection() {
        var deleted: [[String]] = []
        list.onDelete = { deleted.append($0) }
        list.select(["first", "second"])
        key(String(UnicodeScalar(NSDeleteCharacter)!))
        XCTAssertEqual(deleted, [["first", "second"]])
    }

    func testAKeyWithNothingSelectedAsksForNothing() {
        var opened: [String] = []
        list.onOpen = { opened.append($0) }
        table.deselectAll(nil)
        key("\r")
        XCTAssertEqual(opened, [])
    }

    // MARK: Adding

    /// The add row reports the section it is in, which is the whole of how "added under a frame joins
    /// that frame" works (D6).
    func testAnAddRowReportsItsOwnSection() throws {
        var added: [(frame: String?, text: String)] = []
        list.onAdd = { added.append((frame: $0, text: $1)) }

        let underTheFrame = table.numberOfRows - 1
        try submit("Design review", inRowAt: underTheFrame)
        XCTAssertEqual(added.last?.frame, "frame")
        XCTAssertEqual(added.last?.text, "Design review")

        try submit("A loose thought", inRowAt: 1)
        XCTAssertEqual(added.last?.frame, nil, "the board's own row adds to no frame")
    }

    /// Typing another line straight after is the point of an add row: the field empties and keeps the
    /// keyboard, so three items are three lines rather than three trips to a menu.
    func testTheFieldEmptiesSoTheNextItemCanBeTyped() throws {
        var added: [String] = []
        list.onAdd = { _, text in added.append(text) }
        let cell = try addCell(at: 1)
        cell.field.stringValue = "One"
        submit(cell)
        XCTAssertEqual(cell.field.stringValue, "")
        cell.field.stringValue = "Two"
        submit(cell)
        XCTAssertEqual(added, ["One", "Two"])
    }

    /// An empty line is not an item. Pressing Return on an untouched field is what leaving it looks
    /// like, and a blank card appearing on the board would be the surprise.
    func testAnEmptyLineAddsNothing() throws {
        var added = 0
        list.onAdd = { _, _ in added += 1 }
        let cell = try addCell(at: 1)
        cell.field.stringValue = "   "
        submit(cell)
        XCTAssertEqual(added, 0)
    }

    // MARK: The detail (D11)

    /// The rows are the navigation: what is picked is what the right-hand half is told to show.
    func testTheDetailFollowsTheSelection() {
        table.selectRowIndexes(IndexSet(integer: row(of: "first")), byExtendingSelection: false)
        XCTAssertEqual(detail.showing, ["first"])

        table.selectRowIndexes(IndexSet(integer: row(of: "second")), byExtendingSelection: false)
        XCTAssertEqual(detail.showing, ["second"])
    }

    /// And the arrow keys walk it, which is the whole of what "the list is the navigation" means.
    func testAnArrowKeyWalksTheDetail() {
        table.selectRowIndexes(IndexSet(integer: row(of: "first")), byExtendingSelection: false)
        key(String(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(detail.showing, ["second"], "the next row, and the detail with it")
    }

    /// **Several picked is several shown**, in the order the rows draw them — the half tiles them, the
    /// way ⌘↩ tiles a selection on the board. Showing the first of three would be answering a question
    /// nobody asked while the menu, ⌫ and a drag all act on the three.
    func testSeveralSelectedAreAllShown() {
        table.selectRowIndexes(IndexSet([row(of: "first"), row(of: "second")]), byExtendingSelection: false)
        XCTAssertEqual(detail.showing, ["first", "second"])
    }

    func testNothingSelectedShowsNothing() {
        table.selectRowIndexes(IndexSet(integer: row(of: "first")), byExtendingSelection: false)
        table.deselectAll(nil)
        XCTAssertEqual(detail.showing, [])
    }

    /// An edit made anywhere else — the board, another window, Obsidian — reaches the pane you are
    /// reading the card in. The rows do not change, so nothing about the *selection* says to look
    /// again: the half is told the document moved instead.
    func testTheDetailKeepsUpWithTheDocument() {
        table.selectRowIndexes(IndexSet(integer: row(of: "first")), byExtendingSelection: false)
        let refreshes = detail.refreshes
        store.change("Edit Card") { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == "first" }) else { return }
            document.nodes[index].content = .text("Spec, revised")
        }
        XCTAssertEqual(detail.showing, ["first"], "still the same card")
        XCTAssertGreaterThan(detail.refreshes, refreshes, "and told to look at it again")
    }

    /// A half supplied after the rows already have a selection is told what it is, rather than sitting
    /// empty until the next click.
    func testAFreshDetailIsToldWhatIsSelected() {
        table.selectRowIndexes(IndexSet(integer: row(of: "second")), byExtendingSelection: false)
        let replacement = DetailPane()
        list.detail = replacement
        XCTAssertEqual(replacement.showing, ["second"])
    }

    /// The lens being finished with is the half being finished with — a board left running behind a
    /// pane nobody holds is the cost the lens exists to save.
    func testTearingDownTheLensTearsDownTheDetail() {
        list.stopWatching()
        XCTAssertEqual(detail.teardowns, 1)
    }

    /// Stands in for `CanvasItemDetailView`, which is a board.
    private final class DetailPane: NSView, CanvasItemDetailPane {
        private(set) var showing: [String] = []
        private(set) var refreshes = 0
        private(set) var teardowns = 0

        func show(_ ids: [String]) { showing = ids }
        func refresh(_ ids: [String]) { showing = ids; refreshes += 1 }
        func teardown() { teardowns += 1 }
    }

    // MARK: How tall a row is

    /// **A row is as tall as what is in it.** A card's title is the first line of whatever is written
    /// on it, so the long ones are the notes — and a list that cut every one of them off at the same
    /// place would be refusing to show the difference between two cards that begin alike.
    func testALongTitleGetsATallerRow() throws {
        store.change("Add") { document in
            document.nodes.append(CanvasNode(
                id: "essay",
                content: .text("A title long enough that it cannot possibly fit on one line of a "
                               + "three-hundred-point column, and so has to wrap onto the next"),
                frame: CanvasRect(x: 0, y: 1200, width: 200, height: 150)))
        }
        list.layoutSubtreeIfNeeded()
        let short = table.rect(ofRow: row(of: "loose")).height
        let long = table.rect(ofRow: row(of: "essay")).height
        XCTAssertEqual(short, CanvasItemListView.rowHeight, "a one-line title is the ordinary row")
        XCTAssertGreaterThan(long, short, "and a wrapped one is taller")
    }

    /// And no taller than a row can be and still be a row.
    func testAVeryLongTitleStopsGrowing() throws {
        store.change("Add") { document in
            document.nodes.append(CanvasNode(
                id: "essay",
                content: .text(String(repeating: "every word of this is going to wrap ", count: 40)),
                frame: CanvasRect(x: 0, y: 1200, width: 200, height: 150)))
        }
        list.layoutSubtreeIfNeeded()
        let height = table.rect(ofRow: row(of: "essay")).height
        XCTAssertLessThan(height, CanvasItemListView.rowHeight * CGFloat(CanvasItemListView.titleLines),
                          "capped at \(CanvasItemListView.titleLines) lines")
    }

    /// The measurement is against a width somebody can drag, so narrowing the list makes its rows
    /// taller rather than making its titles shorter.
    func testNarrowingTheListMakesARowTaller() throws {
        store.change("Add") { document in
            document.nodes.append(CanvasNode(
                id: "essay",
                content: .text("A title that fits wide but wraps when narrow"),
                frame: CanvasRect(x: 0, y: 1200, width: 200, height: 150)))
        }
        // A lens of its own, in a window wide enough to give the list its full width — the shared one
        // is in a 400-point window, where the list is already at its floor and cannot be narrowed.
        UserDefaults.standard.removeObject(forKey: CanvasItemListView.dividerMemoryKey)
        let lens = CanvasItemListView(store: store)
        defer { lens.stopWatching() }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: true)
        host.backgroundColor = .windowBackgroundColor
        host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        lens.frame = host.contentView!.bounds
        host.contentView!.addSubview(lens)
        host.layoutIfNeeded()
        lens.layoutSubtreeIfNeeded()

        let rows = try XCTUnwrap(table(in: lens))
        let essay = (0..<rows.numberOfRows).first { lens.idOfRow($0) == "essay" } ?? -1
        XCTAssertEqual(rows.bounds.width, CanvasItemListView.listWidth, accuracy: 1,
                       "an untouched divider starts at the default")
        let wide = rows.rect(ofRow: essay).height

        // Down to where the list is at its own floor, which is as narrow as this half ever gets.
        lens.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        lens.layoutSubtreeIfNeeded()
        XCTAssertLessThan(rows.bounds.width, CanvasItemListView.listWidth, "the list gave way")
        XCTAssertGreaterThan(rows.rect(ofRow: essay).height, wide)
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = table(in: child) { return found } }
        return nil
    }

    // MARK: The order (D4)

    /// The rows are in the order the lens was told to read in, and the sections are not: a frame is
    /// where a card *is*, so sorting reorders inside a section and never across one.
    func testTheOrderIsTheOneTheLensWasGiven() {
        XCTAssertEqual(itemRows, ["loose", "first", "second"], "reading order, down the board")
        list.sort = .name
        XCTAssertEqual(itemRows, ["loose", "second", "first"],
                       "example.com before Spec, and the loose card still first because it is loose")
    }

    /// A press where the rows are, but not on one, offers the only thing a list has to offer about
    /// itself — and says which order is on.
    func testTheMenuOffTheRowsOffersTheOrder() throws {
        var chosen: [CanvasItemSort] = []
        list.onSort = { chosen.append($0) }
        let header = try XCTUnwrap(headerRow)
        let menu = try XCTUnwrap(table.menu(for: press(atRow: header)))
        XCTAssertEqual(menu.items.map(\.title),
                       ["Sort Cards By"] + CanvasItemSort.allCases.map(\.title))
        XCTAssertEqual(menu.items.first(where: { $0.state == .on })?.title, "Reading Order")

        let byName = try XCTUnwrap(menu.items.first { $0.title == "Name" })
        _ = byName.target?.perform(byName.action, with: byName)
        XCTAssertEqual(chosen, [.name], "the list reports it; the board's pane is what keeps it")
    }

    /// A press on an item is the card's menu, not the list's — the one it had before the order was
    /// offered anywhere.
    func testTheMenuOnARowIsStillTheCardsOwn() throws {
        var asked: [[String]] = []
        list.menuForSelection = { asked.append($0); return NSMenu() }
        _ = table.menu(for: press(atRow: row(of: "first")))
        XCTAssertEqual(asked, [["first"]])
    }

    private var itemRows: [String] {
        (0..<table.numberOfRows).compactMap { list.idOfRow($0) }
    }

    /// A right-click in the middle of `row`, in window coordinates.
    private func press(atRow row: Int) -> NSEvent {
        let rect = table.convert(table.rect(ofRow: row), to: nil)
        return NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY),
                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: Dropping (D7)

    /// A drop is a section's, wherever in it the pointer was: over a row, over the gap under the last
    /// one, over the add row. The rows are sorted, so "between these two" is not a place.
    func testADropAnywhereInASectionLandsOnThatSection() throws {
        let inTheFrame = try XCTUnwrap(list.dropTarget(near: row(of: "second")))
        XCTAssertEqual(inTheFrame.frame, "frame")
        XCTAssertTrue(try XCTUnwrap(headerRow) == inTheFrame.row, "shown on the frame's own header")

        let loose = try XCTUnwrap(list.dropTarget(near: row(of: "loose")))
        XCTAssertNil(loose.frame, "the board's loose items are no frame — which means the Inbox")
        XCTAssertEqual(loose.row, 1, "and are shown on their add row, the section having no header")
    }

    /// Past the last row is the last section, not nothing: AppKit proposes one past the end for a
    /// pointer below everything, and a drop there should land rather than be refused.
    func testADropPastTheEndLandsInTheLastSection() throws {
        let target = try XCTUnwrap(list.dropTarget(near: table.numberOfRows))
        XCTAssertEqual(target.frame, "frame")
    }

    /// The arrow on the drag is the only thing that says which of the two things a drop will do, so
    /// rows of this list read as a move and everything else as a copy.
    func testRowsMoveAndOutsidersCopy() throws {
        let source = try XCTUnwrap(table.dataSource)
        let ours = ItemDrop(carrying: .rows(["second"]), in: window)
        XCTAssertEqual(source.tableView?(table, validateDrop: ours, proposedRow: 3,
                                         proposedDropOperation: .above), .move)
        let theirs = ItemDrop(carrying: .link, in: window)
        XCTAssertEqual(source.tableView?(table, validateDrop: theirs, proposedRow: 3,
                                         proposedDropOperation: .above), .copy)
    }

    /// What the list reports when you let go: the section, and the pasteboard untouched — reading it
    /// is the board's business, because what a drop *makes* is the board's business.
    func testAcceptReportsTheSectionAndHandsOverThePasteboard() throws {
        var dropped: [(frame: String?, ids: [String])] = []
        list.onDrop = { frame, pasteboard in
            dropped.append((frame, CanvasItemRows.read(pasteboard)))
            return true
        }
        let source = try XCTUnwrap(table.dataSource)
        let drag = ItemDrop(carrying: .rows(["loose"]), in: window)
        let header = try XCTUnwrap(headerRow)
        XCTAssertEqual(source.tableView?(table, acceptDrop: drag, row: header, dropOperation: .on), true)
        XCTAssertEqual(dropped.last?.frame, "frame")
        XCTAssertEqual(dropped.last?.ids, ["loose"])
    }

    /// A dragged row is two things at once: the card, for this board, and the link it is worth to
    /// everything else. Losing either one breaks a different drag.
    func testADraggedRowCarriesItsIdAndWhatItIsWorthOutside() throws {
        let source = try XCTUnwrap(table.dataSource)
        let written = source.tableView?(table, pasteboardWriterForRow: row(of: "second"))
        let item = try XCTUnwrap(written as? NSPasteboardItem)
        XCTAssertEqual(item.string(forType: CanvasItemRows.pasteboardType), "second")
        XCTAssertEqual(item.string(forType: .URL), "https://example.com/roadmap")
    }

    /// A header is not a card and has nothing to hand over; beginning a drag of one would put an empty
    /// item on the pasteboard.
    func testAHeaderCannotBeDragged() throws {
        let source = try XCTUnwrap(table.dataSource)
        let header = try XCTUnwrap(headerRow)
        XCTAssertNil(source.tableView?(table, pasteboardWriterForRow: header) ?? nil)
    }

    private var headerRow: Int? {
        (0..<table.numberOfRows).first { table.delegate?.tableView?(table, isGroupRow: $0) == true }
    }

    private func addCell(at row: Int) throws -> CanvasItemAddCell {
        let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        return try XCTUnwrap(view as? CanvasItemAddCell, "row \(row) is not an add row")
    }

    private func submit(_ cell: CanvasItemAddCell) {
        let editor = NSTextView()
        _ = cell.control(cell.field, textView: editor,
                         doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func submit(_ text: String, inRowAt row: Int) throws {
        let cell = try addCell(at: row)
        cell.field.stringValue = text
        submit(cell)
    }
}

/// A drag delivered straight to the list's delegate — AppKit only makes a real `NSDraggingInfo` for a
/// real mouse, and what is being asserted is what the list does with one, not that AppKit can make it.
@MainActor
private final class ItemDrop: NSObject, NSDraggingInfo {
    enum Carrying {
        /// Rows of this very list, as `CanvasItemRows` writes them.
        case rows([String])
        /// A link from somewhere else — a browser, another project's board.
        case link
    }

    var draggingLocation: NSPoint = .zero
    let window: NSWindow
    let draggingPasteboard: NSPasteboard

    init(carrying: Carrying, in window: NSWindow) {
        self.window = window
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        switch carrying {
        case .rows(let ids):
            draggingPasteboard.writeObjects(ids.map { id in
                let item = NSPasteboardItem()
                CanvasItemRows.write(id, to: item)
                item.setString("whatever it is worth outside", forType: .string)
                return item
            })
        case .link:
            let item = NSPasteboardItem()
            item.setString("https://x.dev/a", forType: .URL)
            item.setString("https://x.dev/a", forType: .string)
            draggingPasteboard.writeObjects([item])
        }
    }

    deinit { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 7 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
