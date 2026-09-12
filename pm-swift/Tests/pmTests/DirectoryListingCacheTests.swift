import Foundation
import XCTest
@testable import PmLib

/// The cache every PARA root listing goes through, and the three rules that keep it from answering with
/// a listing that is out of date. See `DirectoryListingCache`.
final class DirectoryListingCacheTests: XCTestCase {

    /// A filesystem and a clock the test controls.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        var stampValue: Date? = Date(timeIntervalSince1970: 1_000)
        var nowValue = Date(timeIntervalSince1970: 2_000)
        var names = ["W-1 One"]
        var lists = 0
        var failNext = false
        /// Runs during a listing, to change the directory in the middle of one.
        var duringList: (() -> Void)?

        func cache(racyWindow: TimeInterval = 2, maxAge: TimeInterval = 10) -> DirectoryListingCache {
            DirectoryListingCache(
                stamp: { [self] _ in lock.lock(); defer { lock.unlock() }; return stampValue },
                list: { [self] _ in
                    lock.lock(); lists += 1
                    let fail = failNext; failNext = false
                    let during = duringList; duringList = nil
                    let snapshot = names
                    lock.unlock()
                    during?()
                    if fail { throw CocoaError(.fileReadUnknown) }
                    return snapshot.map { .init(name: $0, isDirectory: true) }
                },
                now: { [self] in lock.lock(); defer { lock.unlock() }; return nowValue },
                racyWindow: racyWindow, maxAge: maxAge)
        }
    }

    func testAnUnchangedDirectoryIsListedOnce() throws {
        let world = World(), cache = world.cache()
        _ = try cache.entries(of: "/root")
        _ = try cache.entries(of: "/root")
        _ = try cache.entries(of: "/root")
        XCTAssertEqual(world.lists, 1)
    }

    func testAChangedDateListsAgainAndSeesTheChange() throws {
        let world = World(), cache = world.cache()
        _ = try cache.entries(of: "/root")
        world.names.append("W-2 Two")
        world.stampValue = Date(timeIntervalSince1970: 1_001)
        XCTAssertEqual(try cache.entries(of: "/root").map(\.name), ["W-1 One", "W-2 Two"])
        XCTAssertEqual(world.lists, 2)
    }

    /// **The date is read before the listing.** A change landing during the listing is stored under the
    /// old date, so the next call sees the date moved and lists again. Read after, the stale entries would
    /// be stored under the new date and look current indefinitely.
    func testAChangeDuringAListingIsNotStoredAsCurrent() throws {
        let world = World(), cache = world.cache()
        world.duringList = {
            world.names.append("W-2 Two")
            world.stampValue = Date(timeIntervalSince1970: 1_001)
        }
        _ = try cache.entries(of: "/root")
        XCTAssertEqual(try cache.entries(of: "/root").map(\.name), ["W-1 One", "W-2 Two"],
                       "the change made mid-listing must be seen on the very next call")
    }

    /// **Git's "racily clean" rule.** On a filesystem with whole-second dates, a folder created in the
    /// same second as a listing leaves the directory's date unchanged, so a listing stored while the
    /// date is that recent could be stale with nothing to show it.
    func testAListingIsNotKeptWhileTheDirectoryChangedJustNow() throws {
        let world = World(), cache = world.cache()
        world.stampValue = Date(timeIntervalSince1970: 1_999.5)   // half a second before "now"
        _ = try cache.entries(of: "/root")
        world.names.append("W-2 Two")                              // same second: the date does not move
        XCTAssertEqual(try cache.entries(of: "/root").map(\.name), ["W-1 One", "W-2 Two"])
        XCTAssertEqual(world.lists, 2)
    }

    /// A filesystem that never moves a directory's date is wrong for `maxAge` at most.
    func testAnEntryIsTrustedForItsMaximumAgeAndNoLonger() throws {
        let world = World(), cache = world.cache(maxAge: 10)
        _ = try cache.entries(of: "/root")
        world.nowValue = world.nowValue.addingTimeInterval(9)
        _ = try cache.entries(of: "/root")
        XCTAssertEqual(world.lists, 1)
        world.nowValue = world.nowValue.addingTimeInterval(2)
        _ = try cache.entries(of: "/root")
        XCTAssertEqual(world.lists, 2)
    }

    func testAFailedListingIsNotCached() throws {
        let world = World(), cache = world.cache()
        world.failNext = true
        XCTAssertThrowsError(try cache.entries(of: "/root"))
        XCTAssertEqual(try cache.entries(of: "/root").map(\.name), ["W-1 One"])
        XCTAssertEqual(world.lists, 2)
    }

    func testADirectoryWithNoDateIsNeverCached() throws {
        let world = World(), cache = world.cache()
        world.stampValue = nil
        _ = try cache.entries(of: "/root")
        _ = try cache.entries(of: "/root")
        XCTAssertEqual(world.lists, 2)
    }

    func testEachDirectoryIsCachedSeparately() throws {
        let world = World(), cache = world.cache()
        _ = try cache.entries(of: "/active")
        _ = try cache.entries(of: "/archive")
        _ = try cache.entries(of: "/active")
        XCTAssertEqual(world.lists, 2)
    }

    // MARK: Through the real resolver, on a real disk

    /// The case the racy rule exists for, end to end: a project made and then used at once, in one process.
    func testAProjectCreatedJustNowIsFoundByName() throws {
        try withVault { root in
            let active = root.appendingPathComponent("Projects")
            _ = try? resolveProjectPath(nameOrPrefix: "W-1")     // warm the cache, if it would keep anything
            try makeProject("W-7 Brand New", in: active)
            XCTAssertEqual((try resolveProjectPath(nameOrPrefix: "W-7 Brand New") as NSString).lastPathComponent,
                           "W-7 Brand New")
        }
    }

    func testAProjectRenamedOnDiskIsFoundByItsNewNameAndNotItsOld() throws {
        try withVault { root in
            let active = root.appendingPathComponent("Projects")
            try makeProject("W-3 Before", in: active)
            Thread.sleep(forTimeInterval: 2.2)                     // old enough that its listing is kept
            XCTAssertNoThrow(try resolveProjectPath(nameOrPrefix: "W-3 Before"))
            try FileManager.default.moveItem(at: active.appendingPathComponent("W-3 Before"),
                                             to: active.appendingPathComponent("W-3 After"))
            XCTAssertNoThrow(try resolveProjectPath(nameOrPrefix: "W-3 After"))
            XCTAssertThrowsError(try resolveProjectPath(nameOrPrefix: "W-3 Before"))
        }
    }

    private func makeProject(_ name: String, in folder: URL) throws {
        let docs = folder.appendingPathComponent(name).appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let title = name.split(separator: " ", maxSplits: 1).last.map(String.init) ?? name
        try "# \(title)\n".write(to: docs.appendingPathComponent("Notes - \(title).md"), atomically: true, encoding: .utf8)
    }

    private func withVault(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("listing-cache-\(UUID().uuidString)")
        for dir in ["Projects", "Archive", "Areas"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        defer {
            if let saved { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
            try? fm.removeItem(at: root)
        }
        try saveConfig(PmConfig(activePath: root.appendingPathComponent("Projects").path,
                                archivePath: root.appendingPathComponent("Archive").path,
                                areasPath: root.appendingPathComponent("Areas").path,
                                domains: ["W": "Work"], subfolders: ["docs"]))
        try body(root)
    }
}
