import XCTest
import AppKit
import SwiftUI
import PmLib

/// A folder dropped on a board is a Finder window on it — `CanvasFolderListing`, `CanvasFolderModel`,
/// `CanvasFolderOptions` and the AppKit browser that draws them (`CanvasFolderBrowser`).
///
/// The browser is driven with real events in a harness window, as the list lens is: clicks, ⌘-clicks,
/// double-clicks and keys go to the outline itself, and what is asserted is the selection, the folder
/// shown and the files on disk. Quick Look and the Trash are left out — one opens a system panel and
/// the other moves files into the real Trash.
@MainActor
final class CanvasFolderCardTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func make(_ names: [String], folders: [String] = []) {
        for name in folders {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                     withIntermediateDirectories: true)
        }
        for name in names { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data()) }
    }

    private func age(_ name: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)],
                                              ofItemAtPath: root.appendingPathComponent(name).path)
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
        XCTAssertFalse(CanvasFolderListing.isFolder(root.appendingPathComponent("Tool.app")))
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

    /// Each sort keeps folders on top and orders the rest by its own key — newest and largest first —
    /// falling back to the name where the key can't tell two apart.
    func testEachSortKeepsFoldersOnTop() throws {
        make(["small.txt", "big.txt", "old.md"], folders: ["Sub"])
        try Data(count: 10).write(to: root.appendingPathComponent("small.txt"))
        try Data(count: 5000).write(to: root.appendingPathComponent("big.txt"))
        try age("old.md", by: 86_400 * 30)
        try age("small.txt", by: 60)
        try age("big.txt", by: 3600)

        XCTAssertEqual(CanvasFolderListing.read(root, sort: .name).entries.map(\.name),
                       ["Sub", "big.txt", "old.md", "small.txt"])
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .modified).entries.map(\.name),
                       ["Sub", "small.txt", "big.txt", "old.md"])
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .size).entries.map(\.name),
                       ["Sub", "big.txt", "small.txt", "old.md"])
    }

    /// The other way round, and with folders among the files: what a second click on a column header
    /// and Keep Folders on Top turned off give.
    func testReversedAndFoldersAmongTheFiles() {
        make(["b.txt", "d.txt"], folders: ["a", "c"])
        var options = CanvasFolderOptions()
        options.reversed = true
        XCTAssertEqual(CanvasFolderListing.read(root, options: options).entries.map(\.name), ["c", "a", "d.txt", "b.txt"])
        options.foldersOnTop = false
        XCTAssertEqual(CanvasFolderListing.read(root, options: options).entries.map(\.name), ["d.txt", "c", "b.txt", "a"])
    }

    /// Sorted before the cap: a big folder sorted by date shows its newest, not the newest of the first
    /// few by name.
    func testTheCapComesAfterTheSort() throws {
        make(["a.txt", "b.txt", "z.txt"])
        try age("z.txt", by: 0)
        try age("a.txt", by: 600)
        try age("b.txt", by: 900)
        XCTAssertEqual(CanvasFolderListing.read(root, sort: .modified, limit: 1).entries.map(\.name), ["z.txt"])
    }

    /// Tags come with their colours: a Finder colour tag by its label number, read from the file.
    func testTagsAreReadWithTheirColours() throws {
        make(["tagged.md"])
        let file = root.appendingPathComponent("tagged.md")
        try (file as NSURL).setResourceValue(["Red", "Blue"], forKey: .tagNamesKey)
        let entry = try XCTUnwrap(CanvasFolderListing.read(root).entries.first)
        XCTAssertEqual(entry.tags.map(\.name), ["Red", "Blue"])
        XCTAssertEqual(entry.tags.map(\.color), [6, 4])
    }

    /// An alias carries the Finder's arrow — its icon draws it — and is still a file.
    func testAnAliasIsMarked() throws {
        make(["original.md"])
        let data = try root.appendingPathComponent("original.md").bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(data, to: root.appendingPathComponent("original.md alias"))
        let alias = try XCTUnwrap(CanvasFolderListing.read(root).entries.first { $0.name.hasSuffix("alias") })
        XCTAssertTrue(alias.isAlias)
        XCTAssertFalse(alias.isFolder)
    }

    /// What a cloud drive's resource values say, as the status column says it — a failed upload over
    /// everything, then uploading, downloading, and in the cloud only. A file on a local disk says
    /// nothing.
    func testSyncStatusFromTheProvidersValues() {
        struct Failure: LocalizedError { var errorDescription: String? { "Storage is full." } }
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: nil, downloading: .notDownloaded, isUploading: true,
                                           isDownloading: nil, uploadError: nil), .none)
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: true, downloading: .current, isUploading: true,
                                           isDownloading: false, uploadError: Failure()), .failed("Storage is full."))
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: true, downloading: .current, isUploading: true,
                                           isDownloading: false, uploadError: nil), .uploading)
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: true, downloading: .notDownloaded, isUploading: false,
                                           isDownloading: true, uploadError: nil), .downloading)
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: true, downloading: .notDownloaded, isUploading: false,
                                           isDownloading: false, uploadError: nil), .onlineOnly)
        XCTAssertEqual(CanvasFolderSync.of(isUbiquitous: true, downloading: .current, isUploading: false,
                                           isDownloading: false, uploadError: nil), .none)
        XCTAssertNil(CanvasFolderIcons.syncSymbol(.none))
        XCTAssertNotNil(CanvasFolderIcons.syncSymbol(.onlineOnly))
    }

    // MARK: View options

    /// The settings live on the node, one key each, and a card set back to the defaults leaves no keys
    /// behind. A key PM can't read falls back rather than drawing nothing.
    func testOptionsRoundTripOnTheNodeAndDefaultsWriteNothing() {
        let builtIn = CanvasFolderOptions()
        var node = CanvasNode(content: .file(path: "Folder", subpath: nil),
                              frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(CanvasFolderOptions.of(node, defaults: builtIn), builtIn)

        var set = CanvasFolderOptions(view: .icons, sort: .modified)
        set.reversed = true
        set.group = .kind
        set.columns = [.kind, .created]
        set.iconSize = 96
        set.statusBar = true
        set.pathBar = false
        set.set(on: &node, defaults: builtIn)
        XCTAssertEqual(CanvasFolderOptions.of(node, defaults: builtIn), set)
        XCTAssertEqual(node.extra[CanvasFolderOptions.columnsKey], .string("created,kind"), "in the Finder's order")

        builtIn.set(on: &node, defaults: builtIn)
        XCTAssertTrue(node.extra.isEmpty)

        node.extra[CanvasFolderOptions.viewKey] = .string("colums")
        XCTAssertEqual(CanvasFolderOptions.of(node, defaults: builtIn).view, .list)
    }

    /// Anything a card hasn't set follows the defaults — Use as Defaults — and what it has set doesn't.
    func testACardFollowsTheDefaultsForWhatItHasNotSet() {
        var defaults = CanvasFolderOptions()
        defaults.statusBar = true
        defaults.view = .icons
        var node = CanvasNode(content: .file(path: "Folder", subpath: nil),
                              frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        node.extra[CanvasFolderOptions.viewKey] = .string("list")
        let options = CanvasFolderOptions.of(node, defaults: defaults)
        XCTAssertEqual(options.view, .list)
        XCTAssertTrue(options.statusBar)
    }

    /// A column header: the same column again turns it round, another starts in its own direction.
    func testSortingByAColumnTurnsItRound() {
        var options = CanvasFolderOptions()
        XCTAssertTrue(options.ascending)
        options.sortBy(.name, flipping: true)
        XCTAssertFalse(options.ascending)
        options.sortBy(.modified, flipping: true)
        XCTAssertEqual(options.sort, .modified)
        XCTAssertFalse(options.ascending, "newest first")
        options.sortBy(.modified, flipping: true)
        XCTAssertTrue(options.ascending)
    }

    /// Groups in the Finder's order, whatever order their items came in.
    func testGroupsComeInTheFindersOrder() {
        let now = Date()
        func entry(_ name: String, days: Double, folder: Bool = false, size: Int? = nil) -> CanvasFolderEntry {
            CanvasFolderEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isFolder: folder,
                              type: folder ? .folder : .plainText, modified: now.addingTimeInterval(-days * 86_400),
                              size: size)
        }
        let entries = [entry("old", days: 90, size: 2_000_000_000), entry("new", days: 0, size: 10),
                       entry("Sub", days: 3, folder: true)]
        XCTAssertEqual(CanvasFolderGroup.modified.groups(of: entries, now: now).map(\.title),
                       ["Today", "Previous 7 Days", "Earlier"])
        XCTAssertEqual(CanvasFolderGroup.kind.groups(of: entries, now: now).map(\.title), ["Folders", "Documents"])
        XCTAssertEqual(CanvasFolderGroup.size.groups(of: entries, now: now).map(\.title),
                       ["Folders", "Over 1 GB", "Under 1 MB"])
        XCTAssertEqual(CanvasFolderGroup.none.groups(of: entries, now: now).count, 1)
    }

    /// Columns give way as the card narrows: all at their widths, then the dates written shorter to
    /// keep a column that would have gone — Kind, on a card 487 points wide (485 inside its border) — then the last ones off.
    func testColumnsGiveWayAsTheCardNarrows() {
        let wanted: [CanvasFolderColumn] = [.modified, .size, .kind]
        let fit = CanvasFolderList.columnsThatFit
        XCTAssertEqual(fit(wanted, 600).columns, wanted)
        XCTAssertEqual(fit(wanted, 600).dateWidth, 168)
        XCTAssertEqual(fit(wanted, 520).columns, wanted)
        XCTAssertEqual(fit(wanted, 520).dateWidth, 96)
        XCTAssertEqual(fit(wanted, 485).columns, wanted)
        XCTAssertEqual(fit(wanted, 485).dateWidth, 72)
        XCTAssertEqual(fit(wanted, 400).columns, [.modified, .size])
        XCTAssertEqual(fit(wanted, 300).columns, [.modified])
        XCTAssertEqual(fit(wanted, 200).columns, [])
    }

    /// A date from longest to shortest, and Today and Yesterday only while relative dates are on.
    func testDatesAreWrittenAsLongAsThereIsRoomFor() {
        let now = Date()
        let today = CanvasFolderDetailCell.dateStrings(now, relative: true, now: now)
        XCTAssertTrue(today[0].hasPrefix("Today at "))
        XCTAssertEqual(today.last, "Today")
        let yesterday = CanvasFolderDetailCell.dateStrings(now.addingTimeInterval(-86_400), relative: true, now: now)
        XCTAssertTrue(yesterday[0].hasPrefix("Yesterday"))
        let absolute = CanvasFolderDetailCell.dateStrings(now, relative: false, now: now)
        XCTAssertFalse(absolute[0].hasPrefix("Today"))
        XCTAssertEqual(absolute.count, 3)
        XCTAssertLessThan(absolute[2].count, absolute[1].count)
    }

    func testTheStatusBarSaysWhatTheFindersDoes() {
        XCTAssertEqual(CanvasFolderBrowser.status(total: 13, selected: 0, available: nil), "13 items")
        XCTAssertTrue(CanvasFolderBrowser.status(total: 13, selected: 2, available: 41_200_000_000)
            .hasPrefix("2 of 13 items selected, 41"))
    }

    /// The path bar starts where the Finder's does: a cloud drive's own folder, else home.
    func testThePathBarStartsAtTheDrive() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-someone")
        let inside = drive.appendingPathComponent("My Drive/Brand")
        XCTAssertEqual(CanvasFolderBrowser.pathChain(to: inside).map(\.lastPathComponent),
                       ["GoogleDrive-someone", "My Drive", "Brand"])
        XCTAssertEqual(CanvasFolderBrowser.pathChain(to: home.appendingPathComponent("Documents")).first?.path,
                       home.standardizedFileURL.path)
    }

    /// The Finder's name for a copy.
    func testACopyIsNamedTheFindersWay() {
        make(["notes.md", "notes copy.md"])
        XCTAssertEqual(CanvasFolderActions.copyName(for: root.appendingPathComponent("notes.md")).lastPathComponent,
                       "notes copy 2.md")
        XCTAssertEqual(CanvasFolderActions.copyName(for: root.appendingPathComponent("other.md")).lastPathComponent,
                       "other copy.md")
    }

    // MARK: Filing off main

    /// A drop's copy runs on `CanvasFolderDrop.queue`: asked for, it returns at once, the card says
    /// it's copying until it lands, and then the file is there and the undo has what was done.
    func testFilingCopiesOffMainAndTheCardSaysSoMeanwhile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("filing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let big = source.appendingPathComponent("movie.mov")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }

        // Held up behind something else on the queue, as a long copy before it would be.
        let release = DispatchSemaphore(value: 0)
        CanvasFolderDrop.queue.async { release.wait() }
        var landed: [(from: URL, to: URL)]?
        let start = Date()
        CanvasFolderDrop.file([big], into: root, copying: true, model: model) { done, failure in
            XCTAssertNil(failure)
            landed = done
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "the copy ran on main")
        XCTAssertEqual(model.filing?.count, 1)
        XCTAssertEqual(model.filing?.copying, true)
        release.signal()

        let deadline = Date().addingTimeInterval(10)
        while landed == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(landed?.map(\.to.lastPathComponent), ["movie.mov"])
        XCTAssertNil(model.filing)
        XCTAssert(FileManager.default.fileExists(atPath: root.appendingPathComponent("movie.mov").path))
    }

    // MARK: Staying true

    /// A file added to the folder shows up on a card already up.
    func testTheListingFollowsTheFolder() {
        make(["one.md"])
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        XCTAssertEqual(model.listing.total, 1)
        make(["two.md"])
        let deadline = Date().addingTimeInterval(3)
        while model.listing.total != 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(model.listing.entries.map(\.name), ["one.md", "two.md"])
    }

    /// A card already up re-sorts when its sort changes.
    func testChangingTheSortReReadsTheFolder() throws {
        make(["a.txt", "b.txt"])
        try Data(count: 10).write(to: root.appendingPathComponent("a.txt"))
        try Data(count: 900).write(to: root.appendingPathComponent("b.txt"))
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        XCTAssertEqual(model.listing.entries.map(\.name), ["a.txt", "b.txt"])
        model.options.sort = .size
        model.waitForReads()
        XCTAssertEqual(model.listing.entries.map(\.name), ["b.txt", "a.txt"])
    }

    /// A folder opened with its triangle is read, and closing it forgets it and everything opened in it.
    func testOpeningAFolderRowReadsItAndClosingForgetsIt() {
        make(["Docs/brief.md", "Docs/Specs/one.md"], folders: ["Docs", "Docs/Specs"])
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        let docs = root.appendingPathComponent("Docs")
        model.expand(docs)
        model.expand(docs.appendingPathComponent("Specs"))
        model.waitForReads()
        XCTAssertEqual(model.children[docs]?.entries.map(\.name), ["Specs", "brief.md"])
        model.collapse(docs)
        XCTAssertTrue(model.children.isEmpty)
    }

    // MARK: Going into folders

    func testTheCardGoesIntoItsFoldersAndBack() throws {
        make(["top.md", "Docs/brief.md"], folders: ["Docs", "Docs/Specs"])
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        XCTAssertFalse(model.isInside)
        XCTAssertTrue(model.go(to: root.appendingPathComponent("Docs")))
        model.waitForReads()
        XCTAssertTrue(model.isInside)
        XCTAssertEqual(model.listing.entries.map(\.name), ["Specs", "brief.md"])
        XCTAssertEqual(model.parent.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertTrue(model.go(to: model.parent))
        model.waitForReads()
        XCTAssertFalse(model.isInside)
    }

    /// Only down from the card's own folder: a folder beside it — even one whose name starts the same —
    /// or a file is not the card's to show.
    func testTheCardStaysInsideItsOwnFolder() throws {
        make(["top.md"], folders: ["Docs"])
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + " old")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        XCTAssertFalse(model.go(to: sibling))
        XCTAssertFalse(model.go(to: root.deletingLastPathComponent()))
        XCTAssertFalse(model.go(to: root.appendingPathComponent("top.md")))
        XCTAssertFalse(model.isInside)
    }

    /// The folder you are in going away takes the card back to its own.
    func testAFolderDeletedUnderTheCardSendsItHome() throws {
        make(["top.md"], folders: ["Docs"])
        let model = CanvasFolderModel(url: root)
        model.waitForReads()
        defer { model.stop() }
        model.go(to: root.appendingPathComponent("Docs"))
        model.waitForReads()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Docs"))
        let deadline = Date().addingTimeInterval(3)
        while model.isInside, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(model.isInside)
        model.waitForReads()
        XCTAssertEqual(model.listing.entries.map(\.name), ["top.md"])
    }

    // MARK: Reads off the main thread

    /// A card goes up without reading its folder: the read is the card's own queue's, and the card says
    /// it is loading until it lands. A stalled cloud provider holds a directory read indefinitely.
    func testTheCardGoesUpBeforeItsFolderIsRead() {
        make(["one.md"])
        let model = CanvasFolderModel(url: root)
        defer { model.stop() }
        XCTAssertFalse(model.loaded)
        XCTAssertEqual(model.listing.total, 0)
        XCTAssertTrue(model.waitForReads())
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.listing.entries.map(\.name), ["one.md"])
    }

    /// A read that doesn't return — standing in for read() of a dataless file whose provider has
    /// stalled — leaves the main thread turning, and the answer comes when the read does.
    func testABlockedFileReadLeavesTheMainThreadFree() {
        let stuck = DispatchSemaphore(value: 0)
        var answer: Data??
        let started = Date()
        BackgroundFileRead.read(root.appendingPathComponent("stuck.png"), with: { _ in
            stuck.wait()
            return Data([1, 2, 3])
        }) { answer = .some($0) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "asking blocked the caller")
        var turns = 0
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            DispatchQueue.main.async { turns += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(turns, 10, "the main queue stopped while the read was stuck")
        XCTAssertNil(answer, "the blocked read answered")
        stuck.signal()
        let landing = Date().addingTimeInterval(3)
        while answer == nil, Date() < landing { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(answer ?? nil, Data([1, 2, 3]), "the read's answer never came back to main")
    }

    /// A file on this Mac isn't cloud-only; a path that isn't there isn't either.
    func testALocalFileIsNotCloudOnly() {
        make(["here.md"])
        XCTAssertFalse(CloudFile.isCloudOnly(root.appendingPathComponent("here.md")))
        XCTAssertFalse(CloudFile.isCloudOnly(root.appendingPathComponent("gone.md")))
    }

    /// The icon view draws what a file looks like: a picture gets a thumbnail from Quick Look,
    /// remembered for the next rebuild.
    func testAPictureHasAThumbnail() async throws {
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let file = root.appendingPathComponent("orange.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
        let entry = try XCTUnwrap(CanvasFolderListing.read(root).entries.first)
        let thumbnails = CanvasFolderThumbnails()
        let made = await thumbnails.image(for: entry, side: 40)
        XCTAssertNotNil(made)
        let again = await thumbnails.image(for: entry, side: 40)
        XCTAssertTrue(made === again, "asked Quick Look twice for an unchanged file")
        XCTAssertTrue(thumbnails.cached(for: entry, side: 40) === made)
    }

    // MARK: The browser, driven

    private final class Host: CanvasFolderBrowserHost {
        var commits: [(CanvasFolderOptions, String)] = []
        var focused = 0
        var steppedOut = 0
        var added: [URL] = []
        func folderBrowser(_ browser: CanvasFolderBrowser, commit options: CanvasFolderOptions, actionName: String) {
            commits.append((options, actionName))
        }
        func folderBrowserTookFocus(_ browser: CanvasFolderBrowser) { focused += 1 }
        func folderBrowserStepOut(_ browser: CanvasFolderBrowser) { steppedOut += 1 }
        func folderBrowser(_ browser: CanvasFolderBrowser, addCardsFor urls: [URL]) { added += urls }
    }

    private func browser(_ options: CanvasFolderOptions = CanvasFolderOptions(), width: CGFloat = 560,
                         host: Host? = nil) -> (CanvasFolderBrowser, Host) {
        TestApp.start()
        let host = host ?? Host()
        let model = CanvasFolderModel(url: root, options: options)
        model.waitForReads()
        let browser = CanvasFolderBrowser(model: model, linkZones: CanvasLinkZones())
        browser.host = host
        // A harness window: the ordinary window ground, and never key unless a test asks.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        browser.frame = window.contentView!.bounds
        browser.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(browser)
        window.orderBack(nil)
        self.window = window
        browser.layoutSubtreeIfNeeded()
        browser.outline.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            browser.teardown()
            model.stop()
        }
        return (browser, host)
    }

    /// Let the model's reads land and the browser draw them — what a key that opens a folder waits on.
    private func settle(_ browser: CanvasFolderBrowser) {
        browser.model.waitForReads()
        browser.reloadNow()
    }

    private func names(_ outline: CanvasFolderOutline) -> [String] {
        outline.shownURLs.map(\.lastPathComponent)
    }

    /// A click in `view` at `point` (its own coordinates), with the mouse-up already waiting so the
    /// view's tracking loop comes out.
    private func click(_ view: NSView, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let window = view.window else { return XCTFail("not in a window") }
        let inWindow = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: true)
        view.mouseDown(with: event(.leftMouseDown))
        while NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    private func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], to view: NSView) {
        guard let window = view.window else { return XCTFail("not in a window") }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    /// The list draws the folder in the card's order, a row per item, with a header to sort by.
    func testTheListDrawsTheFolder() {
        make(["b.md", "a.md"], folders: ["Sub"])
        let (browser, _) = browser()
        XCTAssertEqual(names(browser.outline), ["Sub", "a.md", "b.md"])
        XCTAssertNotNil(browser.outline.headerView)
        XCTAssertTrue(browser.outline.usesAlternatingRowBackgroundColors)
    }

    /// Picks rows the way clicks do, and gives the list the keyboard.
    ///
    /// **Not synthetic clicks.** A table in this bundle doesn't select from a posted left click — a
    /// plain one leaves its mouse-up untaken and selects nothing, and a ⌘-click replaces the selection
    /// rather than adding to it — so the clicks are the table's own selection call. How a click selects
    /// is AppKit's; what is pinned here is what the card does with the selection.
    private func pick(_ rows: Int..., in outline: CanvasFolderOutline) {
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    /// The list taking the keyboard tells the card, which makes it the card the board is about; the
    /// selection is by item, in the order drawn.
    func testTheListTakingTheKeyboardTellsTheCard() {
        make(["a.md", "b.md", "c.md", "d.md"])
        let (browser, host) = browser()
        let outline = browser.outline
        pick(2, 0, in: outline)
        XCTAssertGreaterThan(host.focused, 0, "the card was told the list took the keyboard")
        XCTAssertEqual(outline.selectedURLs.map(\.lastPathComponent), ["a.md", "c.md"])
    }

    /// Opening a folder (⌘↓, as a double-click does) goes into it, in the card; ⌘↑ comes back out with
    /// it selected.
    func testOpeningAFolderGoesIntoIt() {
        make(["top.md"], folders: ["Docs"])
        FileManager.default.createFile(atPath: root.appendingPathComponent("Docs/inside.md").path, contents: Data())
        let (browser, _) = browser()
        let outline = browser.outline
        pick(0, in: outline)
        key("\u{F701}", code: 125, flags: [.command, .numericPad, .function], to: outline)
        XCTAssertTrue(browser.model.isInside)
        settle(browser)
        XCTAssertEqual(names(outline), ["inside.md"])
        key("\u{F700}", code: 126, flags: [.command, .numericPad, .function], to: outline)
        settle(browser)
        XCTAssertFalse(browser.model.isInside)
        XCTAssertEqual(outline.selectedURLs.map(\.lastPathComponent), ["Docs"])
    }

    /// The triangle: → opens a folder row where it is, ← closes it.
    func testArrowKeysOpenAndCloseAFolderRow() {
        make(["top.md"], folders: ["Docs"])
        FileManager.default.createFile(atPath: root.appendingPathComponent("Docs/brief.md").path, contents: Data())
        let (browser, _) = browser()
        let outline = browser.outline
        pick(0, in: outline)
        key("\u{F703}", code: 124, flags: [.numericPad, .function], to: outline)
        settle(browser)
        XCTAssertEqual(names(outline), ["Docs", "brief.md", "top.md"])
        XCTAssertEqual(browser.model.expanded.map(CanvasFolderEntry.key), [CanvasFolderEntry.key(root.appendingPathComponent("Docs"))])
        key("\u{F702}", code: 123, flags: [.numericPad, .function], to: outline)
        XCTAssertEqual(names(outline), ["Docs", "top.md"])
        XCTAssertTrue(browser.model.expanded.isEmpty)
    }

    /// Return renames in place, the name selected without its extension; the new name is on disk, and
    /// undo puts the old one back.
    func testReturnRenamesInPlaceAndUndoes() throws {
        make(["draft.md"])
        let (browser, _) = browser()
        let outline = browser.outline
        pick(0, in: outline)
        key("\r", code: 36, to: outline)
        let editor = try XCTUnwrap(outline.window?.firstResponder as? NSTextView, "the name is being edited")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "draft")
        editor.insertText("final", replacementRange: editor.selectedRange())
        outline.window?.makeFirstResponder(outline)
        settle(browser)
        let renamed = root.appendingPathComponent("final.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(outline.selectedURLs.map(\.lastPathComponent), ["final.md"])
        outline.window?.undoManager?.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.md").path))
    }

    /// ⌫ on its own is the Finder's beep, not the board's delete; Escape gives the keyboard back.
    func testDeleteIsSwallowedAndEscapeStepsOut() {
        make(["keep.md"])
        let (browser, host) = browser()
        let outline = browser.outline
        pick(0, in: outline)
        key("\u{7F}", code: 51, to: outline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.md").path))
        key("\u{1b}", code: 53, to: outline)
        XCTAssertEqual(host.steppedOut, 1)
    }

    /// A click on a column header sorts by it and writes that to the card; again turns it round.
    func testAColumnHeaderSortsAndWritesTheCard() throws {
        make(["a.md", "b.md"])
        let (browser, host) = browser()
        let outline = browser.outline
        let header = try XCTUnwrap(outline.headerView)
        let kind = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        XCTAssertGreaterThanOrEqual(kind, 0)
        let rect = header.headerRect(ofColumn: kind)
        click(header, at: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(host.commits.last?.0.sort, .size)
        XCTAssertEqual(host.commits.last?.1, "Sort by Size")
        click(header, at: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(host.commits.last?.0.sort, .size)
        XCTAssertEqual(host.commits.last?.0.reversed, true)
    }

    /// The columns the card asks for that fit: a narrow card shows fewer, and Name always.
    func testANarrowCardShowsFewerColumns() {
        make(["a.md"])
        let (wide, _) = browser(width: 640)
        let shown = { (outline: NSOutlineView) in outline.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) }
        XCTAssertEqual(shown(wide.outline), ["name", "modified", "size", "kind"])
        window?.orderOut(nil)
        let (narrow, _) = browser(width: 320)
        XCTAssertEqual(shown(narrow.outline), ["name", "modified"])
    }

    /// With groups, the headings draw and can't be picked.
    func testGroupHeadingsCannotBeSelected() {
        make(["a.md"], folders: ["Sub"])
        var options = CanvasFolderOptions()
        options.group = .kind
        let (browser, _) = browser(options)
        let outline = browser.outline
        XCTAssertEqual(outline.numberOfRows, 4, "two headings, two items")
        for row in 0..<outline.numberOfRows {
            let item = outline.item(atRow: row) as? CanvasFolderRow
            XCTAssertEqual(outline.delegate?.outlineView?(outline, shouldSelectItem: item as Any) ?? true,
                           item?.isGroup == false, "row \(row)")
        }
    }

    /// The contextual menu is the Finder's, with the count in it for several, and the empty space has
    /// its own.
    func testTheContextualMenusAreTheFinders() throws {
        make(["a.md", "b.md"])
        let (browser, _) = browser()
        let outline = browser.outline
        pick(0, 1, in: outline)
        let several = browser.actions.itemMenu(for: outline.selectedURLs, in: outline).items.map(\.title)
        XCTAssertEqual(several.first, "Open 2 Items")
        XCTAssertTrue(several.contains("Move 2 Items to Trash"))
        XCTAssertTrue(several.contains("Add 2 Cards to Board"))
        XCTAssertFalse(several.contains("Rename"))
        let one = browser.actions.itemMenu(for: [outline.selectedURLs[0]], in: outline).items.map(\.title)
        XCTAssertTrue(one.contains("Rename"))
        XCTAssertTrue(one.contains("Quick Look “a.md”"))
        let empty = browser.actions.emptyMenu(in: outline).items.map(\.title)
        XCTAssertEqual(empty.first, "New Folder")
        XCTAssertTrue(empty.contains("Show View Options"))
    }

    /// Dragging rows out carries the files themselves, so they land on the board as file cards.
    func testADraggedRowIsItsFile() {
        make(["a.md"])
        let (browser, _) = browser()
        let writer = browser.list.outlineView(browser.outline, pasteboardWriterForItem: browser.list.top[0])
        XCTAssertEqual(((writer as? NSURL) as URL?).map(CanvasFolderEntry.key), CanvasFolderEntry.key(root.appendingPathComponent("a.md")))
    }

    /// The list is the browser's to click; the header is the board's, to pick the card up by.
    func testTheListTakesClicksAndTheHeaderDoesNot() {
        make(["a.md"])
        let (browser, _) = browser()
        XCTAssertFalse(browser.takesClick(at: NSPoint(x: 100, y: 10)))
        XCTAssertTrue(browser.takesClick(at: NSPoint(x: 100, y: 120)))
    }

    /// The icon view: an item per file, the same selection commands, and the size the card asked for.
    func testTheIconsDrawTheFolderAndSelect() {
        make(["a.md", "b.md"], folders: ["Sub"])
        var options = CanvasFolderOptions()
        options.view = .icons
        options.iconSize = 48
        let (browser, _) = browser(options)
        XCTAssertTrue(browser.listScroll.isHidden)
        XCTAssertEqual(browser.icons.shownURLs.map(\.lastPathComponent), ["Sub", "a.md", "b.md"])
        browser.icons.select([root.appendingPathComponent("b.md")], scrolling: false)
        XCTAssertEqual(browser.icons.selectedURLs.map(\.lastPathComponent), ["b.md"])
        XCTAssertEqual((browser.icons.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.height, 48 + 46)
    }

    /// Switching views keeps the selection.
    func testSwitchingViewsKeepsTheSelection() {
        make(["a.md", "b.md"])
        let (browser, _) = browser()
        pick(1, in: browser.outline)
        var options = browser.model.options
        options.view = .icons
        browser.apply(options)
        browser.reloadNow()
        XCTAssertEqual(browser.icons.selectedURLs.map(\.lastPathComponent), ["b.md"])
    }

    /// New Folder makes "untitled folder", selected and ready to be named.
    func testNewFolderIsReadyToBeNamed() throws {
        let (browser, _) = browser()
        browser.window?.makeFirstResponder(browser.outline)
        browser.actions.newFolder()
        browser.model.waitForReads()
        XCTAssertTrue(CanvasFolderListing.isFolder(root.appendingPathComponent("untitled folder")))
        XCTAssertEqual(browser.outline.selectedURLs.map(\.lastPathComponent), ["untitled folder"])
        XCTAssertTrue(browser.outline.window?.firstResponder is NSTextView, "its name is being edited")
    }

    /// Several rows go to the board as cards, through the card.
    func testAddCardsAsksTheCard() {
        make(["a.md", "b.md"])
        let (browser, host) = browser()
        browser.actions.addCards(browser.outline.shownURLs)
        XCTAssertEqual(host.added.map(\.lastPathComponent), ["a.md", "b.md"])
    }
}
