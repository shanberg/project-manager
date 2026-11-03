import XCTest
import Foundation
@testable import PmLib

/// Reading Claude Code transcripts for the minutes they were busy, and placing their folders.
final class AgentActivityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func minute(_ text: String) -> Int? {
        Array(text.utf8).withUnsafeBufferPointer { AgentActivity.epochMinute($0) }
    }

    private func date(_ text: String) -> Date { DoneLog.date(text)! }

    private func line(_ stamp: String?, cwd: String? = "/dev/carmody", type: String = "assistant") -> String {
        var fields = [#""type":"\#(type)""#]
        if let cwd { fields.append(#""cwd":"\#(cwd)""#) }
        fields.append(#""message":{"content":"a \"quoted\" thing"}"#)
        if let stamp { fields.append(#""timestamp":"\#(stamp)""#) }
        return "{" + fields.joined(separator: ",") + "}\n"
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        // Begun before the test's day, as a real transcript holding its lines would have been.
        try FileManager.default.setAttributes([.creationDate: date("2026-11-01T00:00:00Z")], ofItemAtPath: url.path)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private let day = DoneRange(start: DoneLog.date("2026-11-02T00:00:00Z")!, end: DoneLog.date("2026-11-03T00:00:00Z")!)

    // MARK: Timestamps

    func testATimestampIsItsMinute() {
        XCTAssertEqual(minute("2026-11-03T02:46:19.471Z"),
                       Int(date("2026-11-03T02:46:00Z").timeIntervalSince1970 / 60))
        XCTAssertEqual(minute("1970-01-01T00:01:59Z"), 1)
        XCTAssertEqual(minute("2024-02-29T23:59:00Z"),
                       Int(date("2024-02-29T23:59:00Z").timeIntervalSince1970 / 60))
    }

    func testAnythingButUTCIsNotATimestamp() {
        XCTAssertNil(minute("2026-11-03T02:46:19+01:00"))
        XCTAssertNil(minute("yesterday"))
        XCTAssertNil(minute("2026-13-03T02:46:19Z"))
    }

    // MARK: Reading

    func testBusyMinutesAreReadOncePerFolderPerMinute() throws {
        _ = try write(line(nil, type: "queue-operation")
                      + line("2026-11-02T10:00:05.000Z")
                      + line("2026-11-02T10:00:50.000Z", cwd: nil)
                      + line("2026-11-02T10:03:00.000Z")
                      + line("2026-11-01T09:00:00.000Z"),
                      to: "-dev-carmody/a.jsonl")
        _ = try write(line("2026-11-02T10:03:30.000Z"), to: "-dev-carmody/b.jsonl")
        let moments = AgentActivity.moments(in: day, root: root.path)
        XCTAssertEqual(moments.map(\.minute), [date("2026-11-02T10:00:00Z"), date("2026-11-02T10:03:00Z")])
        XCTAssertEqual(Set(moments.map(\.folder)), ["/dev/carmody"])
    }

    /// Subagents write their own transcripts in folders under the session's.
    func testSubagentTranscriptsCount() throws {
        _ = try write(line("2026-11-02T11:00:00Z", cwd: "/dev/designs"), to: "-dev-designs/s/subagents/x.jsonl")
        XCTAssertEqual(AgentActivity.moments(in: day, root: root.path).map(\.folder), ["/dev/designs"])
    }

    /// Transcripts grow while they're read. A line still being written waits for the next read.
    func testAGrowingTranscriptIsReadFromWhereItStopped() throws {
        let url = try write(line("2026-11-02T12:00:00Z") + #"{"type":"assistant","timestamp":"2026-11-02T12:0"#,
                            to: "-dev-carmody/grow.jsonl")
        XCTAssertEqual(AgentActivity.moments(in: day, root: root.path).count, 1)
        try append(#"5:00Z"}"# + "\n" + line("2026-11-02T12:09:00Z"), to: url)
        XCTAssertEqual(AgentActivity.moments(in: day, root: root.path).map(\.minute),
                       [date("2026-11-02T12:00:00Z"), date("2026-11-02T12:05:00Z"), date("2026-11-02T12:09:00Z")])
    }

    func testATranscriptUntouchedSinceTheRangeBeganIsNotRead() throws {
        let url = try write(line("2026-11-02T12:00:00Z"), to: "-dev-carmody/old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: date("2026-10-30T00:00:00Z")], ofItemAtPath: url.path)
        XCTAssertTrue(AgentActivity.moments(in: day, root: root.path).isEmpty)
    }

    func testNoTranscriptsIsNoMoments() {
        XCTAssertTrue(AgentActivity.moments(in: day, root: root.appendingPathComponent("missing").path).isEmpty)
    }

    // MARK: Whose folder it is

    private var folders: AgentFolders {
        AgentFolders(projects: [(folder: "H-004 Maxwell Carmody", claims: []),
                                (folder: "W-004 Design Editor", claims: ["~/dev/designs", "/work/mono"]),
                                (folder: "W-009 Mono Docs", claims: ["/work/mono/docs/"]),
                                (folder: "W-001 Website", claims: []),
                                (folder: "C-001 Website", claims: [])])
    }

    func testAFolderSpellingATitleIsThatProjects() {
        XCTAssertEqual(folders.project(for: "/Users/x/dev/maxwell-carmody"), "H-004 Maxwell Carmody")
        XCTAssertEqual(folders.project(for: "/Users/x/dev/MaxwellCarmody/packages/core/src"), "H-004 Maxwell Carmody")
    }

    func testAClaimBeatsTheNameAndTheDeepestClaimWins() {
        XCTAssertEqual(folders.project(for: (NSHomeDirectory() as NSString).appendingPathComponent("dev/designs/app")),
                       "W-004 Design Editor")
        XCTAssertEqual(folders.project(for: "/work/mono/src"), "W-004 Design Editor")
        XCTAssertEqual(folders.project(for: "/work/mono/docs/guide"), "W-009 Mono Docs")
    }

    func testATitleTwoProjectsShareMatchesNeither() {
        XCTAssertNil(folders.project(for: "/dev/website"))
    }

    func testNothingAboveTheHomeFolderIsMatchedByName() {
        let home = NSHomeDirectory()
        let named = AgentFolders(projects: [(folder: "S-001 " + (home as NSString).lastPathComponent, claims: [])])
        XCTAssertNil(named.project(for: (home as NSString).appendingPathComponent("scratch")))
    }

    func testResolveGivesEachMomentItsProject() {
        let moments = folders.resolve([AgentMoment(minute: Date(), folder: "/dev/maxwell-carmody"),
                                       AgentMoment(minute: Date(), folder: "/dev/elsewhere")])
        XCTAssertEqual(moments.map(\.project), ["H-004 Maxwell Carmody", nil])
    }

    func testPmFoldersIsAListOrOnePath() {
        XCTAssertEqual(projectAgentFolders(rawText: "---\npm-folders: [\"~/dev/a\", '~/dev/b']\n---\n# A\n"),
                       ["~/dev/a", "~/dev/b"])
        XCTAssertEqual(projectAgentFolders(rawText: "---\npm-folders: ~/dev/a\n---\n"), ["~/dev/a"])
        XCTAssertEqual(projectAgentFolders(rawText: "---\npm-color: red\n---\n"), [])
    }
}
