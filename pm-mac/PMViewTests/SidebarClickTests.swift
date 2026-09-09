import XCTest
import AppKit
import SwiftUI

/// **A project carded in Up Next appears twice in the list, under one tag.**
///
/// `ProjectSidebar` gives a card the *same* `.tag` as its project's row further down, deliberately, so
/// that selecting either highlights both and every command outside the file still resolves plain
/// project keys. That leaves the list with two rows answering to one selection value, and the list's
/// selection is what switches the window: `selectionChanged` runs off a *change* to the tag set, so
/// any click that lands on a value already in it is a click that does nothing.
///
/// This asks the list what it actually does with a duplicated tag — how many rows a single tag
/// highlights, and what the binding is told when the selection moves between two rows that share one.
///
/// A model rather than the sidebar itself: `ProjectSidebar` reaches for `PMStore` and won't compile
/// alone. What is modelled is the shape under suspicion — two sections, one tag appearing in both.
@MainActor
final class SidebarClickTests: XCTestCase {

    /// The selection, held outside the view so a test can read what the list published.
    private final class Box: ObservableObject {
        @Published var selection: Set<String> = []
        /// Every value the list wrote, including ones that didn't change it.
        var writes: [Set<String>] = []
        /// How many of those writes `onChange` was told about.
        var changes = 0
    }

    private struct Harness: View {
        let carded: [String]
        let keys: [String]
        @ObservedObject var box: Box

        var body: some View {
            List(selection: Binding(get: { box.selection },
                                    set: { box.writes.append($0); box.selection = $0 })) {
                if !carded.isEmpty {
                    Section {
                        ForEach(carded, id: \.self) { key in
                            Text("card \(key)")
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .tag(key)
                        }
                    } header: {
                        Text("Up Next")
                    }
                }
                Section {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .tag(key)
                    }
                } header: {
                    Text("Projects")
                }
            }
            .onChange(of: box.selection) { _, _ in box.changes += 1 }
        }
    }

    private let keys = (1...8).map { "P-00\($0)" }
    private var window: NSWindow!
    private var box: Box!
    private var table: NSTableView!

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    /// **One tag, two rows: does selecting it highlight both?**
    ///
    /// If it does, the two rows are one selection value and moving between them is not a change —
    /// which is the shape of a click that lands and does nothing.
    func testADuplicatedTagHighlightsBothRows() throws {
        try openList(carding: ["P-003"])
        select(row: cardRow)
        XCTAssertEqual(box.selection, ["P-003"])
        XCTAssertEqual(table.selectedRowIndexes.count, 2,
                       "a card and its row are one tag and should highlight together")
    }

    /// **Moving the selection from a card to the row it stands for writes, but does not change.**
    ///
    /// Two different rows, one tag. The list writes the tag it now holds — so the binding's setter
    /// runs, and sees the click — but the value it writes is the value already there. Anything hung
    /// off `onChange` is not told, because nothing changed. That is the whole difference between
    /// driving the switch from the write and driving it from the change.
    func testMovingBetweenTwoRowsOfOneTagWritesButDoesNotChange() throws {
        try openList(carding: ["P-003"])
        let card = cardRow
        let row = listRow(of: "P-003", carding: true)
        XCTAssertNotEqual(card, row, "the two rows collapsed into one")

        select(row: card)
        XCTAssertEqual(box.selection, ["P-003"], "row \(card) isn't the P-003 card")
        let afterCard = box.writes.count
        select(row: row)
        print("DIAG card=\(card) row=\(row) selection=\(box.selection.sorted())"
              + " writes=\(box.writes.map { $0.sorted() })"
              + " tableSel=\(table.selectedRowIndexes.map { $0 })")
        XCTAssertGreaterThan(box.writes.count, afterCard,
                             "moving between two rows of one tag published nothing at all")
    }

    /// The control: two rows of *different* tags, which is every other row in the list.
    func testMovingBetweenTwoTagsPublishesTheChange() throws {
        try openList(carding: [])
        select(row: listRow(of: "P-002", carding: false))
        XCTAssertEqual(box.selection, ["P-002"], "the row indexes don't line up with the keys")
        select(row: listRow(of: "P-005", carding: false))
        XCTAssertEqual(box.selection, ["P-005"], "an ordinary selection move didn't publish")
    }

    // MARK: Putting a list on screen

    private func openList(carding carded: [String]) throws {
        TestApp.start()
        box = Box()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(carded: carded, keys: keys, box: box))
        window.makeKeyAndOrderFront(nil)
        table = try XCTUnwrap(waitForTable(), "SwiftUI's List never built a table view")
        let expected = keys.count + carded.count + (carded.isEmpty ? 1 : 2)
        XCTAssertEqual(table.numberOfRows, expected, "the list isn't shaped the way the tests read it")
    }

    /// SwiftUI builds its table on a later run-loop turn, so the test has to let the loop turn.
    private func waitForTable() -> NSTableView? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if let found = Self.findTable(in: window.contentView), found.numberOfRows > 0 {
                found.layoutSubtreeIfNeeded()
                return found
            }
        }
        return nil
    }

    private static func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = findTable(in: child) { return found }
        }
        return nil
    }

    /// Where the rows fall. A section header is a row of its own, so with a band above the list the
    /// order is: Up Next header, one card, Projects header, then the eight projects. Every test that
    /// uses these also asserts what the binding published, so a wrong index fails as a wrong index
    /// rather than as the thing being measured.
    private let cardRow = 1

    private func listRow(of key: String, carding: Bool) -> Int {
        let headers = carding ? 3 : 1   // Up Next header + its one card + Projects header
        return headers + (keys.firstIndex(of: key) ?? 0)
    }

    /// Move the selection the way the table moves it, and let SwiftUI publish it back.
    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
    }
}
