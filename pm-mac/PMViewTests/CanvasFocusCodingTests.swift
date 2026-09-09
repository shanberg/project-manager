import XCTest

/// What a tab pinned to part of a board writes to disk, and what it can still read back.
///
/// **This whole file exists for one rename.** `CanvasFocus.arrangement` became `.workspace` when the
/// app stopped calling three different things by the same word (docs/canvas-workspaces.md §7). Swift
/// synthesizes an enum's `Codable` from its case names, so that rename would have silently changed the
/// format `ProjectTabMemory` has been writing since tabs existed — and silently is the word: the tab
/// would decode as nothing, and a window somebody set up weeks ago would come back one tab short with
/// no error anywhere. `CanvasFocus.CodingKeys` pins the old spelling, and these are what keep it
/// pinned, because nothing else about the code would notice it going.
final class CanvasFocusCodingTests: XCTestCase {

    // MARK: The old spelling, read

    /// The exact bytes a build before the rename wrote. If this fails, everybody's saved tabs are gone.
    func testDecodesWhatOlderBuildsWrote() throws {
        let old = Data(#"{"arrangement":{"_0":"Dashboard"}}"#.utf8)
        let focus = try JSONDecoder().decode(CanvasFocus.self, from: old)
        XCTAssertEqual(focus, .workspace("Dashboard"))
    }

    /// And the two cases the rename did not touch, so a failure here means something else moved.
    func testDecodesTheUntouchedCases() throws {
        let whole = try JSONDecoder().decode(CanvasFocus.self,
                                             from: Data(#"{"whole":{}}"#.utf8))
        XCTAssertEqual(whole, .whole)

        let frame = try JSONDecoder().decode(CanvasFocus.self,
                                             from: Data(#"{"frame":{"_0":"group-1"}}"#.utf8))
        XCTAssertEqual(frame, .frame("group-1"))
    }

    // MARK: The old spelling, written

    /// Still *written* as `arrangement`, not merely accepted. A build that read the old word and wrote
    /// a new one would work perfectly on this machine and hand an older build — or a synced defaults
    /// row — something it cannot read, which is the same bug one release later.
    func testKeepsWritingTheOldSpelling() throws {
        let data = try JSONEncoder().encode(CanvasFocus.workspace("Dashboard"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("arrangement"), text)
        XCTAssertFalse(text.contains("workspace"), text)
    }

    /// A name is not a key: a workspace called "workspace" must not make the assertion above lie, and
    /// it is exactly the kind of name somebody types while trying the feature out for the first time.
    func testAWorkspaceNamedWorkspaceStillRoundTrips() throws {
        let data = try JSONEncoder().encode(CanvasFocus.workspace("workspace"))
        XCTAssertEqual(try JSONDecoder().decode(CanvasFocus.self, from: data), .workspace("workspace"))
    }

    // MARK: Round trips

    func testRoundTripsEveryCase() throws {
        for focus in [CanvasFocus.whole, .frame("group-1"), .workspace("Dashboard")] {
            let data = try JSONEncoder().encode(focus)
            XCTAssertEqual(try JSONDecoder().decode(CanvasFocus.self, from: data), focus)
        }
    }

    /// The tab is what actually gets stored, so the pinning has to survive being nested in one — the
    /// case above encodes the focus on its own, and `ProjectTab` wraps it twice.
    func testSurvivesInsideAStoredTab() throws {
        let tabs = [ProjectTab(.notes, id: "a"),
                    ProjectTab(.board(.workspace("Dashboard")), id: "b")]
        let data = try JSONEncoder().encode(tabs)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("arrangement"))
        XCTAssertEqual(try JSONDecoder().decode([ProjectTab].self, from: data), tabs)
    }
}
