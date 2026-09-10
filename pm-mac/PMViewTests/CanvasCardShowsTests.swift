import XCTest
import PmLib
@testable import PMViewTests

/// What a project card draws of its project, and what that writes into a shared document.
final class CanvasCardShowsTests: XCTestCase {

    private func card(_ extra: [String: JSONValue] = [:]) -> CanvasNode {
        CanvasNode(content: .file(path: "docs/Notes - Walkable.md", subpath: nil),
                   frame: CanvasRect(x: 0, y: 0, width: 400, height: 300),
                   extra: extra)
    }

    // MARK: The default

    func testACardNobodyNarrowedShowsTheWholeProject() {
        XCTAssertEqual(CanvasCardShows.of(card()), .everything)
    }

    /// The `CanvasCardZoom` bargain: the default is the absence of the key, so a card narrowed and
    /// widened again leaves the file exactly as it found it.
    func testShowingEverythingAgainTakesTheKeyOutOfTheFile() {
        var node = card()
        CanvasCardShows.set(.tasks, on: &node)
        XCTAssertNotNil(node.extra[CanvasCardShows.key])
        CanvasCardShows.set(.everything, on: &node)
        XCTAssertNil(node.extra[CanvasCardShows.key])
    }

    // MARK: What gets written

    func testEveryPresetRoundTripsThroughTheNode() {
        for preset in CanvasCardShows.allCases {
            var node = card()
            CanvasCardShows.set(preset, on: &node)
            XCTAssertEqual(CanvasCardShows.of(node), preset, "\(preset.title)")
        }
    }

    /// One word, and a word a person reading the `.canvas` in Obsidian can act on.
    func testACardWritesItsPresetAsOneWord() {
        var node = card()
        CanvasCardShows.set(.current, on: &node)
        XCTAssertEqual(node.extra[CanvasCardShows.key], .string("current"))
    }

    // MARK: What each card is made of

    func testEverythingDrawsTheWholeDocument() {
        let shows = CanvasCardShows.everything
        XCTAssertTrue(shows.brief)
        XCTAssertTrue(shows.showsProse(ofSessionAt: 3))
        XCTAssertTrue(shows.showsTask(checked: true))
    }

    /// The point of the pair: `current` narrows the *prose* to the latest sitting without narrowing the
    /// tasks to it, which the old `latestOnly` flag could not express — it truncated the session list,
    /// so hiding an older sitting's words also hid the work it left open.
    func testCurrentDrawsTheLatestProseAndEverySittingsOpenWork() {
        let shows = CanvasCardShows.current
        XCTAssertTrue(shows.showsProse(ofSessionAt: 0))
        XCTAssertFalse(shows.showsProse(ofSessionAt: 1))
        XCTAssertTrue(shows.showsTask(checked: false), "an open task from a sitting three back")
        XCTAssertFalse(shows.showsTask(checked: true))
        XCTAssertFalse(shows.brief)
    }

    func testTasksDrawsOpenWorkAndNothingElse() {
        let shows = CanvasCardShows.tasks
        XCTAssertFalse(shows.brief)
        XCTAssertFalse(shows.showsProse(ofSessionAt: 0))
        XCTAssertTrue(shows.showsTask(checked: false))
        XCTAssertFalse(shows.showsTask(checked: true))
    }

    func testBriefDrawsTheBriefAlone() {
        let shows = CanvasCardShows.brief
        XCTAssertTrue(shows.brief)
        XCTAssertFalse(shows.showsProse(ofSessionAt: 0))
        XCTAssertFalse(shows.showsTask(checked: false))
    }

    /// Every preset draws something. The five-flag version could reach "nothing at all" and had to
    /// refuse it in three places; naming the cards outright means the state does not exist.
    func testNoPresetIsABlankRectangle() {
        for preset in CanvasCardShows.allCases {
            XCTAssertTrue(preset.brief
                            || preset.showsProse(ofSessionAt: 0)
                            || preset.showsTask(checked: false),
                          "\(preset.title) draws nothing")
        }
    }

    // MARK: Reading a file somebody else touched

    func testSpacingAndCaseDoNotMatter() {
        XCTAssertEqual(CanvasCardShows.parse("  Current "), .current)
        XCTAssertEqual(CanvasCardShows.parse("BRIEF"), .brief)
    }

    /// A `.canvas` is hand-editable, so `pmShows: "currnet"` is a typo somebody will make. Naming
    /// nothing PM knows is not a card showing nothing — it is a card PM cannot read, and the honest
    /// recovery is the project.
    func testAValueNamingNoCardFallsBackToTheWholeProject() {
        XCTAssertEqual(CanvasCardShows.parse("currnet"), .everything)
        XCTAssertEqual(CanvasCardShows.parse(""), .everything)
        XCTAssertEqual(CanvasCardShows.parse("completed"), .everything)
    }

    // MARK: Cards written by the five-flag version

    /// Anything scoped to the latest sitting was asking "where is this now", whatever else it said.
    func testALegacyLatestOnlyCardBecomesCurrent() {
        XCTAssertEqual(CanvasCardShows.parse("notes,tasks,latest"), .current)
        XCTAssertEqual(CanvasCardShows.parse("brief,notes,tasks,completed,latest"), .current)
        XCTAssertEqual(CanvasCardShows.parse("tasks,latest"), .current)
    }

    func testTheLegacySinglePartCardsKeepTheirMeaning() {
        XCTAssertEqual(CanvasCardShows.parse("brief"), .brief)
        XCTAssertEqual(CanvasCardShows.parse("brief,completed"), .brief)
        XCTAssertEqual(CanvasCardShows.parse("tasks"), .tasks)
        XCTAssertEqual(CanvasCardShows.parse("tasks,completed"), .tasks)
    }

    /// The combinations with no preset widen rather than narrowing. Showing more than you asked for is
    /// one click from fixed; showing less looks like the card is broken.
    func testALegacyCardWithNoPresetWidensToTheWholeProject() {
        XCTAssertEqual(CanvasCardShows.parse("brief,tasks,completed"), .everything)
        XCTAssertEqual(CanvasCardShows.parse("brief,notes"), .everything)
        XCTAssertEqual(CanvasCardShows.parse("notes"), .everything)
    }
}
