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
        CanvasCardShows.set(CanvasCardShows(brief: false, notes: false, tasks: true,
                                            completed: false, latestOnly: true), on: &node)
        XCTAssertNotNil(node.extra[CanvasCardShows.key])
        CanvasCardShows.set(.everything, on: &node)
        XCTAssertNil(node.extra[CanvasCardShows.key])
    }

    // MARK: What gets written

    func testASettingRoundTripsThroughTheNode() {
        let wanted = CanvasCardShows(brief: true, notes: false, tasks: true,
                                     completed: false, latestOnly: true)
        var node = card()
        CanvasCardShows.set(wanted, on: &node)
        XCTAssertEqual(CanvasCardShows.of(node), wanted)
    }

    /// The tokens are written in a fixed order, so a card set the same way twice produces the same
    /// bytes and a `.canvas` under git doesn't churn.
    func testTheTokensAreWrittenInAFixedOrder() {
        let shows = CanvasCardShows(brief: true, notes: true, tasks: true,
                                    completed: true, latestOnly: true)
        XCTAssertEqual(shows.written, "brief,notes,tasks,completed,latest")
    }

    func testATasksOnlyCardWritesOneWord() {
        let shows = CanvasCardShows(brief: false, notes: false, tasks: true,
                                    completed: false, latestOnly: false)
        XCTAssertEqual(shows.written, "tasks")
    }

    // MARK: Reading a file somebody else touched

    func testUnknownWordsAreIgnored() {
        XCTAssertEqual(CanvasCardShows.parse("tasks, sparkles"),
                       CanvasCardShows(brief: false, notes: false, tasks: true,
                                       completed: false, latestOnly: false))
    }

    func testSpacingAndCaseDoNotMatter() {
        XCTAssertEqual(CanvasCardShows.parse("  Brief , TASKS "),
                       CanvasCardShows(brief: true, notes: false, tasks: true,
                                       completed: false, latestOnly: false))
    }

    /// A `.canvas` is hand-editable, so `pmShows: "task"` is a typo somebody will make. Naming no part
    /// of a project is not a card showing nothing — it is a card PM cannot read, and the honest
    /// recovery is the project.
    func testAListNamingNoPartFallsBackToTheWholeProject() {
        XCTAssertEqual(CanvasCardShows.parse("task"), .everything)
        XCTAssertEqual(CanvasCardShows.parse(""), .everything)
        XCTAssertEqual(CanvasCardShows.parse("completed,latest"), .everything)
    }

    // MARK: The one arrangement that isn't a view of a project

    func testTurningOffTheLastPartIsRefused() {
        let onlyTasks = CanvasCardShows(brief: false, notes: false, tasks: true,
                                        completed: true, latestOnly: false)
        XCTAssertNil(onlyTasks.setting(.tasks, to: false))
    }

    func testTurningOffAPartThatIsNotTheLastOneIsFine() {
        let two = CanvasCardShows(brief: false, notes: true, tasks: true,
                                  completed: true, latestOnly: false)
        XCTAssertEqual(two.setting(.tasks, to: false)?.tasks, false)
        XCTAssertEqual(two.setting(.tasks, to: false)?.notes, true)
    }

    /// The refusal is about emptiness, not about the part: turning one *on* can never be refused, even
    /// on a card that is already showing only that one.
    func testTurningAPartOnIsNeverRefused() {
        let onlyBrief = CanvasCardShows(brief: true, notes: false, tasks: false,
                                        completed: true, latestOnly: false)
        XCTAssertEqual(onlyBrief.setting(.brief, to: true), onlyBrief)
        XCTAssertNotNil(onlyBrief.setting(.notes, to: true))
    }

    /// Completed is a filter on the tasks, not a part of the card — hiding finished work does not make
    /// a card empty, and never had to be refused.
    func testHidingCompletedTasksIsNotHidingAPart() {
        var shows = CanvasCardShows(brief: false, notes: false, tasks: true,
                                    completed: true, latestOnly: false)
        shows.completed = false
        XCTAssertFalse(shows.isEmpty)
    }
}
