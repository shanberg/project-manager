import XCTest

/// A file card's writing session — `CanvasDocSession`: writes off main, in order, retried after a
/// failure, renames after the writes, and a bounded wait at quit.
@MainActor
final class CanvasDocSessionTests: XCTestCase {
    private var folder: URL!
    private var file: URL!
    private var saved: (@Sendable (String, URL) throws -> Void)!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doc-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("note.md")
        try "start".write(to: file, atomically: true, encoding: .utf8)
        saved = CanvasDocSession.writer
        CanvasDocSession.delay = 0.05
    }

    override func tearDownWithError() throws {
        CanvasDocSession.writer = saved
        CanvasDocSession.delay = 0.5
        try? FileManager.default.removeItem(at: folder)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func disk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// A write that doesn't return — a stalled provider — leaves the main thread turning; the typing
    /// lands once it does.
    func testAStuckWriteLeavesTheMainThreadFree() {
        let stuck = DispatchSemaphore(value: 0)
        let real = saved!
        CanvasDocSession.writer = { text, url in stuck.wait(); try real(text, url) }
        let session = CanvasDocSession(url: file, text: "start")
        session.changed("typed")
        let started = Date()
        session.flush()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "flush waited for the write")
        XCTAssertTrue(session.isWriting)
        var turns = 0
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            DispatchQueue.main.async { turns += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(turns, 10, "the main queue stopped while the write was stuck")
        stuck.signal()
        spin { !session.isWriting }
        XCTAssertEqual(disk(), "typed")
    }

    /// Writes land in the order asked, so the file ends as the last typing, never an earlier one.
    func testWritesLandInOrder() {
        let real = saved!
        let slowFirst = NSLock()
        nonisolated(unsafe) var count = 0
        CanvasDocSession.writer = { text, url in
            slowFirst.lock(); count += 1; let n = count; slowFirst.unlock()
            if n == 1 { Thread.sleep(forTimeInterval: 0.2) }
            try real(text, url)
        }
        let session = CanvasDocSession(url: file, text: "start")
        var landed = 0
        session.onWrite = { landed += 1 }
        for text in ["one", "two", "three"] {
            session.changed(text)
            session.flush()
        }
        spin { landed == 3 }
        XCTAssertEqual(landed, 3)
        XCTAssertEqual(disk(), "three")
        XCTAssertFalse(session.hasUnsavedEdits)
    }

    /// The pending write goes after the last change by itself, without a flush.
    func testTypingIsWrittenAfterAPause() {
        let session = CanvasDocSession(url: file, text: "start")
        session.changed("paused")
        spin { disk() == "paused" }
        XCTAssertEqual(disk(), "paused")
    }

    /// A write that fails leaves the typing unsaved, so the next change writes it again.
    func testAFailedWriteStaysUnsaved() {
        struct Refused: Error {}
        CanvasDocSession.writer = { _, _ in throw Refused() }
        let session = CanvasDocSession(url: file, text: "start")
        session.changed("lost?")
        session.flush()
        spin { !session.isWriting }
        XCTAssertTrue(session.hasUnsavedEdits, "a failed write counted as saved")
        CanvasDocSession.writer = saved
        session.changed("lost? no")
        session.flush()
        spin { !session.isWriting }
        XCTAssertEqual(disk(), "lost? no")
    }

    /// Work after the writes — an untitled card's rename — runs after the last write, never before.
    func testARenameWaitsForTheWrites() {
        let real = saved!
        CanvasDocSession.writer = { text, url in Thread.sleep(forTimeInterval: 0.2); try real(text, url) }
        let session = CanvasDocSession(url: file, text: "start")
        session.changed("Title\nbody")
        session.flush()
        let named = folder.appendingPathComponent("Title.md")
        var done: Error?? = .none
        let from = file!
        session.afterWrites({ try FileManager.default.moveItem(at: from, to: named) }) { done = .some($0) }
        spin { done != nil }
        XCTAssertNotNil(done, "the rename never came back")
        XCTAssertNil(done ?? nil)
        XCTAssertEqual(try? String(contentsOf: named, encoding: .utf8), "Title\nbody")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Quit asks for waiting writes and waits for them; a stuck one is given up on in bounded time.
    func testQuitWaitsForWritesButNotForever() {
        let session = CanvasDocSession(url: file, text: "start")
        session.changed("before quit")
        XCTAssertTrue(CanvasDocSession.finishAll(timeout: 2))
        XCTAssertEqual(disk(), "before quit")

        let stuck = DispatchSemaphore(value: 0)
        CanvasDocSession.writer = { _, _ in stuck.wait() }
        session.changed("stuck")
        let started = Date()
        XCTAssertFalse(CanvasDocSession.finishAll(timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "quit waited past its bound")
        stuck.signal()
        spin { !session.isWriting }
    }
}
