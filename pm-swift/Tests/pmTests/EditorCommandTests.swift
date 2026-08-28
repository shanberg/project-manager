import XCTest
@testable import PmLib

final class EditorCommandTests: XCTestCase {

    /// A fixed day, so the date presets are the same every run.
    private let now = DueFormat.parse("2026-08-28")!

    private func command(_ id: String) -> EditorCommand {
        editorCommands(now: now).first { $0.id == id }!
    }

    /// `/` with nothing typed offers everything, unlike `@`, which has nothing to search for.
    func testEmptyQueryOffersEveryCommand() {
        let all = editorCommands(now: now)
        XCTAssertEqual(rankEditorCommands(all, query: "").count, all.count)
    }

    /// Typing filters on the start of the title or of any word in it.
    func testRankingMatchesWordStarts() {
        let all = editorCommands(now: now)
        XCTAssertEqual(rankEditorCommands(all, query: "wait").map(\.id), ["waiting"])
        XCTAssertTrue(rankEditorCommands(all, query: "tod").allSatisfy { $0.id.hasPrefix("due-") })
    }

    /// The date presets are the app's own, so "next week" means one day everywhere.
    func testDuePresetsComeFromTheSharedList() {
        let ids = editorCommands(now: now).filter { $0.id.hasPrefix("due-") }.map(\.title)
        XCTAssertEqual(ids.count, duePresets(now: now).count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("Due ") })
    }

    /// `/task` makes the line a task and takes the slash with it.
    func testMakeTaskRewritesTheLine() {
        let text = "Review the contract /task"
        let range = text.range(of: "/task")!
        let out = applyEditorCommand(command("task"), to: text, removing: range)
        XCTAssertEqual(out.text, "- [ ] Review the contract")
        XCTAssertFalse(out.opensMention)
    }

    /// An indented bullet keeps its indent and gains a checkbox.
    func testMakeTaskKeepsIndentAndDropsTheBullet() {
        let text = "  - Sub point /task"
        let out = applyEditorCommand(command("task"), to: text, removing: text.range(of: "/task")!)
        XCTAssertEqual(out.text, "  - [ ] Sub point")
    }

    /// A line that's already a task is left alone.
    func testMakeTaskIsIdempotent() {
        let text = "- [ ] Already one /task"
        let out = applyEditorCommand(command("task"), to: text, removing: text.range(of: "/task")!)
        XCTAssertEqual(out.text, "- [ ] Already one")
    }

    /// A due lands at the end of the line, where the format keeps it.
    func testSetDueAppendsTheToken() {
        let text = "- [ ] Ship it /due"
        let due = editorCommands(now: now).first { $0.id.hasPrefix("due-") }!
        let out = applyEditorCommand(due, to: text, removing: text.range(of: "/due")!)
        XCTAssertTrue(out.text.hasPrefix("- [ ] Ship it due: "))
        XCTAssertFalse(out.text.contains("  due:"), "no doubled space where the slash was")
    }

    /// A due appended to a line that already has a wait sits after it, which is canonical order.
    func testSetDueSitsAfterAnExistingWait() throws {
        let text = "- [ ] Ship it waiting: [[W-1 Site]] /due"
        let due = editorCommands(now: now).first { $0.id.hasPrefix("due-") }!
        let out = applyEditorCommand(due, to: text, removing: text.range(of: "/due")!)
        let content = TaskContent.split(String(out.text.dropFirst(6)))
        XCTAssertEqual(content.text, "Ship it")
        XCTAssertEqual(content.waiting, "W-1 Site")
        XCTAssertNotNil(content.due)
    }

    /// `/waiting` writes the marker and hands over to the picker rather than stopping.
    func testStartWaitingOpensTheMentionPicker() {
        let text = "- [ ] Legal review /wait"
        let out = applyEditorCommand(command("waiting"), to: text, removing: text.range(of: "/wait")!)
        XCTAssertEqual(out.text, "- [ ] Legal review waiting: @")
        XCTAssertTrue(out.opensMention)
        XCTAssertEqual(out.text.distance(from: out.text.startIndex, to: out.selection.lowerBound),
                       out.text.count)
    }

    /// Only the line under the caret is touched.
    func testOtherLinesAreUntouched() {
        let text = "first line\n- [ ] Ship it /due\nthird line"
        let due = editorCommands(now: now).first { $0.id.hasPrefix("due-") }!
        let out = applyEditorCommand(due, to: text, removing: text.range(of: "/due")!)
        XCTAssertTrue(out.text.hasPrefix("first line\n"))
        XCTAssertTrue(out.text.hasSuffix("\nthird line"))
    }
}
