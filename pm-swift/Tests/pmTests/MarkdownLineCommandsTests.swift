import XCTest
@testable import PmLib

/// The editor's IDE-style line keys, as the pure transforms they are. `|` marks the caret; `[` and `]`
/// mark a selection.
final class MarkdownLineCommandsTests: XCTestCase {
    /// Parse "a|b" or "a[b]c" into text and selection.
    private func at(_ marked: String) -> (String, Range<String.Index>) {
        var text = marked
        if let bar = text.firstIndex(of: "|") {
            let offset = text.distance(from: text.startIndex, to: bar)
            text.remove(at: bar)
            let i = text.index(text.startIndex, offsetBy: offset)
            return (text, i..<i)
        }
        let open = text.distance(from: text.startIndex, to: text.firstIndex(of: "[")!)
        text.remove(at: text.firstIndex(of: "[")!)
        let close = text.distance(from: text.startIndex, to: text.lastIndex(of: "]")!)
        text.remove(at: text.lastIndex(of: "]")!)
        return (text, text.index(text.startIndex, offsetBy: open)..<text.index(text.startIndex, offsetBy: close))
    }
    private func shown(_ r: (text: String, selection: Range<String.Index>)) -> String {
        var out = r.text
        if r.selection.isEmpty { out.insert("|", at: r.selection.lowerBound); return out }
        let lo = out.distance(from: out.startIndex, to: r.selection.lowerBound)
        let hi = out.distance(from: out.startIndex, to: r.selection.upperBound)
        out.insert("]", at: out.index(out.startIndex, offsetBy: hi))
        out.insert("[", at: out.index(out.startIndex, offsetBy: lo))
        return out
    }
    private func run(_ marked: String, _ f: (String, Range<String.Index>) -> (text: String, selection: Range<String.Index>)?) -> String? {
        let (t, s) = at(marked)
        return f(t, s).map(shown)
    }

    // MARK: copy

    func testCopyDownMovesTheCaretToTheCopy() {
        XCTAssertEqual(run("a\nb|c\nd") { copyLines($0, selection: $1, up: false) }, "a\nbc\nb|c\nd")
    }

    func testCopyUpLeavesTheCaretOnTheUpperCopy() {
        XCTAssertEqual(run("a\nb|c\nd") { copyLines($0, selection: $1, up: true) }, "a\nb|c\nbc\nd")
    }

    func testATripleClickedLineIsOneLine() {
        // Selected through its newline: the next line isn't part of it.
        XCTAssertEqual(run("a\n[bc\n]d") { copyLines($0, selection: $1, up: false) }, "a\nbc\n[bc\n]d")
    }

    // MARK: delete

    func testDeleteKeepsTheColumn() {
        XCTAssertEqual(run("abc\nd|ef\nghi") { deleteLines($0, selection: $1) }, "abc\ng|hi")
    }

    func testDeletingTheLastLineLandsOnTheOneBefore() {
        XCTAssertEqual(run("abc\nde|f") { deleteLines($0, selection: $1) }, "ab|c")
    }

    func testDeletingEverythingLeavesAnEmptyNote() {
        XCTAssertEqual(run("[a\nb]") { deleteLines($0, selection: $1) }, "|")
    }

    // MARK: insert

    func testInsertBelowDoesNotSplit() {
        XCTAssertEqual(run("hel|lo\nworld") { insertLine($0, selection: $1, above: false) }, "hello\n|\nworld")
    }

    func testInsertBelowContinuesTheList() {
        XCTAssertEqual(run("  3. th|ree") { insertLine($0, selection: $1, above: false) }, "  3. three\n  4. |")
        XCTAssertEqual(run("- [x] do|ne") { insertLine($0, selection: $1, above: false) }, "- [x] done\n- [ ] |")
    }

    func testInsertAboveTakesTheItemsShape() {
        XCTAssertEqual(run("- b|") { insertLine($0, selection: $1, above: true) }, "- |\n- b")
        XCTAssertEqual(run("> qu|ote") { insertLine($0, selection: $1, above: true) }, "> |\n> quote")
        XCTAssertEqual(run("    code|") { insertLine($0, selection: $1, above: false) }, "    code\n    |")
    }

    // MARK: headings

    func testSetHeadingReplacesALevel() {
        XCTAssertEqual(run("## Ti|tle") { setHeading($0, selection: $1, level: 1) }, "# Ti|tle")
        XCTAssertEqual(run("Ti|tle") { setHeading($0, selection: $1, level: 3) }, "### Ti|tle")
    }

    func testTheSameLevelAgainTogglesItOff() {
        XCTAssertEqual(run("## Ti|tle") { setHeading($0, selection: $1, level: 2) }, "Ti|tle")
        XCTAssertEqual(run("## Ti|tle") { setHeading($0, selection: $1, level: 0) }, "Ti|tle")
    }

    func testAHashtagIsNotAHeading() {
        XCTAssertEqual(run("#tag|") { setHeading($0, selection: $1, level: 1) }, "# #tag|")
    }

    func testACaretInTheMarkerStaysOnTheLine() {
        XCTAssertEqual(run("##| Title") { setHeading($0, selection: $1, level: 0) }, "|Title")
    }

    func testSeveralLinesSkipBlanks() {
        XCTAssertEqual(run("[a\n\nb]") { setHeading($0, selection: $1, level: 2) }, "[## a\n\n## b]")
    }

    // MARK: tasks

    func testToggleTicksAndUnticks() {
        XCTAssertEqual(run("- [ ] a|") { toggleTask($0, selection: $1) }, "- [x] a|")
        XCTAssertEqual(run("- [x] a|") { toggleTask($0, selection: $1) }, "- [ ] a|")
    }

    func testAListItemGainsABoxAndProseBecomesATask() {
        XCTAssertEqual(run("  - a|") { toggleTask($0, selection: $1) }, "  - [ ] a|")
        XCTAssertEqual(run("  a|") { toggleTask($0, selection: $1) }, "  - [ ] a|")
    }

    func testAMixedRunComesOutUniform() {
        XCTAssertEqual(run("[- [ ] a\n- [x] b]") { toggleTask($0, selection: $1) }, "[- [x] a\n- [x] b]")
    }

    // MARK: join

    func testJoinTakesTheNextLinesIndent() {
        XCTAssertEqual(run("one |\n    two") { joinLines($0, selection: $1) }, "one |two")
    }

    func testJoinOnTheLastLineDoesNothing() {
        XCTAssertNil(run("one|") { joinLines($0, selection: $1) })
    }

    func testJoinASelectionJoinsItsLines() {
        XCTAssertEqual(run("[a\nb\nc]\nd") { joinLines($0, selection: $1) }, "[a b c]\nd")
    }

    func testJoinWithAnEmptyLineAddsNoSpace() {
        XCTAssertEqual(run("a|\n\nb") { joinLines($0, selection: $1) }, "a|\nb")
    }

    // MARK: expand

    private func expand(_ marked: String) -> String? {
        let (t, s) = at(marked)
        return expandedSelection(in: t, from: s).map { shown((t, $0)) }
    }

    func testExpandGoesWordLineBlockSectionAll() throws {
        let note = "# A\nintro\n\n## B\n- first it|em here\n- second\n\n## C\nend"
        var step = try XCTUnwrap(expand(note))
        XCTAssertEqual(step, "# A\nintro\n\n## B\n- first [item] here\n- second\n\n## C\nend")
        step = try XCTUnwrap(expand(step))
        XCTAssertEqual(step, "# A\nintro\n\n## B\n- [first item here]\n- second\n\n## C\nend", "the line's content")
        step = try XCTUnwrap(expand(step))
        XCTAssertEqual(step, "# A\nintro\n\n## B\n[- first item here]\n- second\n\n## C\nend", "the whole line")
        step = try XCTUnwrap(expand(step))
        XCTAssertEqual(step, "# A\nintro\n\n## B\n[- first item here\n- second]\n\n## C\nend", "the block")
        step = try XCTUnwrap(expand(step))
        XCTAssertEqual(step, "# A\nintro\n\n[## B\n- first item here\n- second\n]\n## C\nend", "the section")
        step = try XCTUnwrap(expand(step))
        XCTAssertEqual(step, "[# A\nintro\n\n## B\n- first item here\n- second\n\n## C\nend]", "the parent section")
        XCTAssertNil(expand(step))
    }
}
