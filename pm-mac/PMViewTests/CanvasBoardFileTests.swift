import PmLib
import XCTest

/// A board's file is read and written off main — see `CanvasFileQueue`.
///
/// The property under test is the one a stalled cloud provider breaks: a read or a write that never
/// returns holds the file's queue, never the main thread. Each test stands in a slow or stuck reader or
/// writer and checks the main thread got its answer at once.
@MainActor
final class CanvasBoardFileTests: XCTestCase {
    private var url: URL!
    private var reader: (@Sendable (URL) throws -> CanvasDocument)!
    private var writer: (@Sendable (CanvasDocument, URL) throws -> Void)!
    private var release: DispatchSemaphore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("board-file-tests-\(UUID().uuidString).canvas")
        try Self.board("before").write(to: url)
        reader = CanvasFileQueue.reader
        writer = CanvasFileQueue.writer
        release = DispatchSemaphore(value: 0)
    }

    override func tearDownWithError() throws {
        // Free anything a test left stuck, then let its queue drain before the next test's file.
        for _ in 0..<8 { release.signal() }
        CanvasFileQueue.queue(for: url).sync {}
        CanvasFileQueue.reader = reader
        CanvasFileQueue.writer = writer
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func board(_ text: String) -> CanvasDocument {
        CanvasDocument(nodes: [CanvasNode(id: "card", content: .text(text),
                                          frame: CanvasRect(x: 0, y: 0, width: 200, height: 120))])
    }

    private func text(_ document: CanvasDocument) -> String? {
        if case .text(let value) = document.nodes.first?.content { return value }
        return nil
    }

    private func edit(_ store: CanvasDocumentStore, to text: String) {
        store.changeQuietly { $0.nodes[0].content = .text(text) }
    }

    /// Let the main queue run until `condition` holds.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "condition")
        func poll() {
            if condition() { return done.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
        }
        poll()
        wait(for: [done], timeout: timeout)
    }

    /// Bump the file's modification date past anything the store has seen.
    private func touch(_ seconds: TimeInterval = 10) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)],
                                              ofItemAtPath: url.path)
    }

    // MARK: Saving

    func testAStuckWriteLeavesMainFree() throws {
        let store = try CanvasDocumentStore(url: url)
        let release = release!
        CanvasFileQueue.writer = { _, _ in release.wait() }

        edit(store, to: "after")
        let start = Date()
        store.save()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "save waited on the write")
        XCTAssertEqual(store.writesInFlight, 1)

        edit(store, to: "after again")   // the board keeps working
        XCTAssertEqual(text(store.document), "after again")
    }

    func testSavesLandInTheOrderAsked() throws {
        let store = try CanvasDocumentStore(url: url)
        let written = LockedList()
        let writer = writer!
        CanvasFileQueue.writer = { document, url in
            Thread.sleep(forTimeInterval: 0.05)
            try writer(document, url)
            if case .text(let value) = document.nodes.first?.content { written.append(value) }
        }
        edit(store, to: "one")
        store.save()
        edit(store, to: "two")
        store.save()
        waitUntil { store.writesInFlight == 0 }

        XCTAssertEqual(written.all, ["one", "two"])
        XCTAssertEqual(text(try CanvasDocument.read(contentsOf: url)), "two")
    }

    /// A board closed without a change isn't written on the way out.
    func testNothingChangedIsNothingWritten() throws {
        let store = try CanvasDocumentStore(url: url)
        let written = LockedList()
        CanvasFileQueue.writer = { _, _ in written.append("write") }
        store.save()
        CanvasFileQueue.queue(for: url).sync {}
        XCTAssertEqual(written.all, [])
    }

    /// Quitting with a write stuck waits a bounded time and goes.
    func testQuitDoesNotWaitForeverOnAStuckWrite() throws {
        let store = try CanvasDocumentStore(url: url)
        let release = release!
        CanvasFileQueue.writer = { _, _ in release.wait() }
        edit(store, to: "after")
        store.save()

        let start = Date()
        XCTAssertFalse(CanvasFileQueue.finishAll(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    // MARK: Reading it again

    func testAnOutsideChangeIsReadOffMainAndShown() throws {
        let store = try CanvasDocumentStore(url: url)
        var reloads = 0
        store.addWatcher(self, changed: {}, reloaded: { reloads += 1 })
        try Self.board("from Obsidian").write(to: url)
        try touch()

        store.checkForOutsideChange()
        XCTAssertEqual(text(store.document), "before", "read on main, not off it")
        waitUntil { !store.isRereading }
        XCTAssertEqual(text(store.document), "from Obsidian")
        XCTAssertEqual(reloads, 1)
        store.removeWatcher(self)
    }

    func testAStuckReReadLeavesMainFreeAndAsksOnlyOnce() throws {
        let store = try CanvasDocumentStore(url: url)
        let release = release!
        let reads = LockedList()
        CanvasFileQueue.reader = { _ in
            reads.append("read")
            release.wait()
            return Self.board("late")
        }
        try touch()

        let start = Date()
        store.checkForOutsideChange()
        store.checkForOutsideChange()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "the check waited on the read")
        XCTAssert(store.isRereading)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(reads.all.count, 1, "a stuck read was asked for again")
        edit(store, to: "still editing")
        XCTAssertEqual(text(store.document), "still editing")
    }

    /// Our own write is not somebody else's change.
    func testOurOwnSaveIsNotReadBackAsAnOutsideChange() throws {
        let store = try CanvasDocumentStore(url: url)
        var reloads = 0
        store.addWatcher(self, changed: {}, reloaded: { reloads += 1 })
        edit(store, to: "ours")
        store.save()
        store.checkForOutsideChange()   // while the write is out
        waitUntil { store.writesInFlight == 0 }
        store.checkForOutsideChange()   // after it landed
        waitUntil { !store.isRereading }
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(text(store.document), "ours")
        store.removeWatcher(self)
    }

    // MARK: Opening

    func testOpeningReadsOffMainAndTheStoreUsesThatRead() throws {
        let release = release!
        let reads = LockedList()
        let reader = reader!
        CanvasFileQueue.reader = { url in
            reads.append("read")
            release.wait()
            return try reader(url)
        }
        var landed = false
        let start = Date()
        CanvasStoreRegistry.load(url) { landed = true }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "load waited on the read")
        XCTAssertFalse(CanvasStoreRegistry.isReady(url))
        XCTAssertNil(CanvasStoreRegistry.storeIfReady(for: url), "a board not read yet was read on main")

        release.signal()
        waitUntil { landed }
        let store = try XCTUnwrap(CanvasStoreRegistry.storeIfReady(for: url))
        defer { CanvasStoreRegistry.release(store) }
        XCTAssertEqual(text(store.document), "before")
        XCTAssertEqual(reads.all.count, 1, "the store read the file again")
    }

    /// What was read is thrown away if the file changed since; the next ask reads again.
    func testAReadOverTakenByAChangeIsNotUsed() throws {
        var landed = false
        CanvasStoreRegistry.load(url) { landed = true }
        waitUntil { landed }
        XCTAssert(CanvasStoreRegistry.isReady(url))
        try Self.board("changed").write(to: url)
        try touch()
        XCTAssertFalse(CanvasStoreRegistry.isReady(url))
        XCTAssertNil(CanvasStoreRegistry.storeIfReady(for: url))
    }
}

/// A list appended to from the file queue and read from the test.
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
