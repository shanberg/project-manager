import XCTest
import AppKit
import SwiftUI
import PmLib

/// A folder dropped on a board lists what is in it (backlog 6) — `CanvasFolderCard`.
@MainActor
final class CanvasFolderCardTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-card-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func make(_ names: [String], folders: [String] = []) {
        for name in names { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data()) }
        for name in folders {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: What is listed

    /// Folders first, then everything else, each in the Finder's order — where "file 2" comes before
    /// "file 10" — and nothing hidden.
    func testFoldersFirstInTheFindersOrderWithoutHiddenFiles() {
        make(["file 10.md", "file 2.md", ".DS_Store", "a.pdf"], folders: ["Zebra", "Apples"])
        let listing = CanvasFolderListing.read(root)
        XCTAssertEqual(listing.entries.map(\.name), ["Apples", "Zebra", "a.pdf", "file 2.md", "file 10.md"])
        XCTAssertEqual(listing.entries.map(\.isFolder), [true, true, false, false, false])
        XCTAssertEqual(listing.total, 5)
    }

    /// A package is a file, as it is in the Finder: an app dropped in a folder is not a folder to list.
    func testAPackageIsAFile() {
        make([], folders: ["Tool.app"])
        let app = root.appendingPathComponent("Tool.app")
        XCTAssertFalse(CanvasFolderListing.isFolder(app))
        XCTAssertTrue(CanvasFolderListing.isFolder(root))
        XCTAssertFalse(CanvasFolderListing.isFolder(root.appendingPathComponent("missing")))
    }

    /// A folder of thousands lists the first few hundred and still says how many there are.
    func testABigFolderIsCappedButCounted() {
        make((1...12).map { "f\($0).txt" })
        let listing = CanvasFolderListing.read(root, limit: 5)
        XCTAssertEqual(listing.entries.count, 5)
        XCTAssertEqual(listing.total, 12)
        XCTAssertEqual(CanvasFolderListing.countLabel(1), "1 item")
        XCTAssertEqual(CanvasFolderListing.countLabel(12), "12 items")
    }

    // MARK: How it is laid out

    /// Each sort keeps folders on top and orders the rest by its own key — newest and largest first —
    /// falling back to the name where the key can't tell two apart.
    func testEachSortKeepsFoldersOnTop() throws {
        make(["small.txt", "big.txt", "old.md"], folders: ["Sub"])
        try Data(count: 10).write(to: root.appendingPathComponent("small.txt"))
        try Data(count: 5000).write(to: root.appendingPathComponent("big.txt"))
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 30)],
                             ofItemAtPath: root.appendingPathComponent("old.md").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                             ofItemAtPath: root.appendingPathComponent("small.txt").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                             ofItemAtPath: root.appendingPathComponent("big.txt").path)

        XCTAssertEqual(CanvasFolderListing.read(root, sort: .name).entries.map(\.name),
                       ["Sub", "big.txt", "old.md", "small.txt"])
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .modified).entries.map(\.name),
                       ["Sub", "small.txt", "big.txt", "old.md"])
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .size).entries.map(\.name),
                       ["Sub", "big.txt", "small.txt", "old.md"])
        let byKind = CanvasFolderListing.read(root, sort: .kind).entries
        XCTAssertEqual(byKind.first?.name, "Sub")
        XCTAssertEqual(byKind.dropFirst().map(\.kind), byKind.dropFirst().map(\.kind).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// Sorted before the cap: a big folder sorted by date shows its newest, not the newest of the first
    /// few by name.
    func testTheCapComesAfterTheSort() throws {
        make(["a.txt", "b.txt", "z.txt"])
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: root.appendingPathComponent("z.txt").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: root.appendingPathComponent("a.txt").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -900)],
                                              ofItemAtPath: root.appendingPathComponent("b.txt").path)
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .modified, limit: 1).entries.map(\.name), ["z.txt"])
    }

    /// The view settings live on the node, and a card set back to the defaults leaves no keys behind.
    func testOptionsRoundTripOnTheNodeAndDefaultsWriteNothing() {
        var node = CanvasNode(content: .file(path: "Folder", subpath: nil),
                              frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(CanvasFolderOptions.of(node), CanvasFolderOptions())

        CanvasFolderOptions(view: .icons, sort: .modified).set(on: &node)
        XCTAssertEqual(CanvasFolderOptions.of(node), CanvasFolderOptions(view: .icons, sort: .modified))

        CanvasFolderOptions().set(on: &node)
        XCTAssertTrue(node.extra.isEmpty)

        node.extra[CanvasFolderOptions.viewKey] = .string("colums")
        XCTAssertEqual(CanvasFolderOptions.of(node).view, .list)
    }

    /// A card already up re-sorts when its sort changes.
    func testChangingTheSortReReadsTheFolder() throws {
        make(["a.txt", "b.txt"])
        try Data(count: 10).write(to: root.appendingPathComponent("a.txt"))
        try Data(count: 900).write(to: root.appendingPathComponent("b.txt"))
        let model = CanvasFolderModel(url: root)
        defer { model.stop() }
        XCTAssertEqual(model.listing.entries.map(\.name), ["a.txt", "b.txt"])
        model.options.sort = .size
        XCTAssertEqual(model.listing.entries.map(\.name), ["b.txt", "a.txt"])
    }

    // MARK: Staying true

    /// A file added to the folder shows up on a card already up.
    func testTheListingFollowsTheFolder() {
        make(["one.md"])
        let model = CanvasFolderModel(url: root)
        defer { model.stop() }
        XCTAssertEqual(model.listing.total, 1)
        make(["two.md"])
        let deadline = Date().addingTimeInterval(3)
        while model.listing.total != 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(model.listing.entries.map(\.name), ["one.md", "two.md"])
    }

    // MARK: Rows are links

    /// Every row reports itself to the card as a link to its item, which is what lets a click open it
    /// and a drag carry it off as a card of its own.
    func testEachRowIsALinkToItsItem() {
        make(["one.md", "two.md"], folders: ["Sub"])
        TestApp.start()
        let model = CanvasFolderModel(url: root)
        defer { model.stop() }
        let zones = CanvasLinkZones()
        let hosting = NSHostingView(rootView: CanvasFolderCard(folder: model).canvasLinkZones(zones))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // Down the card's middle, a point at a time: every row the pointer crosses answers with its item,
        // in the order they are listed.
        var seen: [String] = []
        for y in stride(from: 0.0, to: 300, by: 2) {
            if let url = zones.link(at: CGPoint(x: 150, y: y)), seen.last != url.lastPathComponent {
                seen.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(seen, ["Sub", "one.md", "two.md"])
    }

    /// In the icon view each cell is the link: across the grid's first row, every icon answers with its
    /// own item, in order.
    func testEachIconIsALinkToItsItem() {
        make(["one.md", "two.md"], folders: ["Sub"])
        TestApp.start()
        let model = CanvasFolderModel(url: root, options: CanvasFolderOptions(view: .icons))
        defer { model.stop() }
        let zones = CanvasLinkZones()
        let hosting = NSHostingView(rootView: CanvasFolderCard(folder: model).canvasLinkZones(zones))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        var seen: [String] = []
        for y in stride(from: 0.0, to: 300, by: 4) {
            for x in stride(from: 0.0, to: 300, by: 2) {
                if let url = zones.link(at: CGPoint(x: x, y: y)), !seen.contains(url.lastPathComponent) {
                    seen.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(seen, ["Sub", "one.md", "two.md"])
    }
}
