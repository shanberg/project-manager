import XCTest
@testable import PmLib

/// Numbered lists keep counting right as the editor reshapes them: each nesting level counts on its
/// own, bullets and numbers mix, and only the list an edit touched is renumbered. `|` marks the caret.
final class ListNumberingTests: XCTestCase {
    private func at(_ marked: String) -> (String, Range<String.Index>) {
        var text = marked
        let offset = text.distance(from: text.startIndex, to: text.firstIndex(of: "|")!)
        text.remove(at: text.firstIndex(of: "|")!)
        let i = text.index(text.startIndex, offsetBy: offset)
        return (text, i..<i)
    }
    private func shown(_ r: (text: String, selection: Range<String.Index>)) -> String {
        var out = r.text
        out.insert("|", at: r.selection.lowerBound)
        return out
    }
    private func run(_ marked: String,
                     _ f: (String, Range<String.Index>) -> (text: String, selection: Range<String.Index>)?) -> String? {
        let (t, s) = at(marked)
        return f(t, s).map(shown)
    }
    private func tab(_ marked: String) -> String? { run(marked) { indentLines($0, selection: $1) } }
    private func untab(_ marked: String) -> String? { run(marked) { outdentLines($0, selection: $1) } }
    private func enter(_ marked: String) -> String? { run(marked) { continueList($0, selection: $1) } }

    // MARK: Tab and Shift-Tab

    func testIndentingAnItemStartsACountInsideTheOneAbove() {
        XCTAssertEqual(tab("1. a\n2. b\n3. c|\n4. d"), "1. a\n2. b\n  1. c|\n3. d")
    }

    func testIndentingJoinsASublistAlreadyThere() {
        XCTAssertEqual(tab("1. a\n  1. x\n2. b|\n3. c"), "1. a\n  1. x\n  2. b|\n2. c")
    }

    func testOutdentingRejoinsTheOuterCount() {
        XCTAssertEqual(untab("1. a\n  1. x\n  2. y|\n2. b"), "1. a\n  1. x\n2. y|\n3. b")
    }

    func testOutdentingTheFirstOfASublistRenumbersWhatItLeft() {
        XCTAssertEqual(untab("1. a\n  1. x|\n  2. y\n2. b"), "1. a\n2. x|\n  1. y\n3. b")
    }

    func testIndentingSeveralItemsNumbersThemAsOneSublist() {
        let (t, _) = at("1. a\n2. b\n3. c\n4. d|")
        let lo = t.index(t.startIndex, offsetBy: 7)   // inside "2. b"
        let r = indentLines(t, selection: lo..<t.endIndex)
        XCTAssertEqual(r.text, "1. a\n  1. b\n  2. c\n  3. d")
    }

    // MARK: Mixing bullets and numbers

    func testNumbersUnderABulletCountOnTheirOwn() {
        XCTAssertEqual(enter("- a\n  1. x|\n- b\n  1. y"), "- a\n  1. x\n  2. |\n- b\n  1. y")
    }

    func testBulletsUnderANumberDoNotBreakItsCount() {
        XCTAssertEqual(enter("1. a|\n  - x\n  - y\n2. b"), "1. a\n2. |\n  - x\n  - y\n3. b")
    }

    func testIndentingABulletLeavesTheNumbersAroundItCounting() {
        XCTAssertEqual(tab("1. a\n- b|\n2. c"), "1. a\n  - b|\n2. c")
    }

    func testNumbersAfterABulletAtTheSameDepthAreANewList() {
        XCTAssertEqual(tab("- a\n  - b\n  2. c|"), "- a\n  - b\n    1. c|")
    }

    // MARK: Where a list starts

    func testATopLevelListKeepsTheNumberItStartsAt() {
        XCTAssertEqual(enter("5. a|\n6. b"), "5. a\n6. |\n7. b")
    }

    func testMovingTheLastItemToTheTopKeepsTheCount() {
        let moved = run("1. a\n2. b\n3. c|") { moveLines($0, selection: $1, up: true) }
            .flatMap { m in run(m) { moveLines($0, selection: $1, up: true) } }
        XCTAssertEqual(moved, "1. c|\n2. a\n3. b")
    }

    func testDeletingTheFirstItemKeepsTheListStartingAtOne() {
        XCTAssertEqual(run("1. a|\n2. b\n3. c") { deleteLines($0, selection: $1) }, "1. b|\n2. c")
    }

    func testDeletingAMiddleItemClosesTheGap() {
        XCTAssertEqual(run("1. a\n2. b|\n3. c") { deleteLines($0, selection: $1) }, "1. a\n2. c|")
    }

    // MARK: The caret, and the rest of the note

    func testTheCaretStaysWithItsTextWhenANumberGrowsADigit() {
        let list = (1...9).map { "\($0). i\($0)" }.joined(separator: "\n")
        let r = run("0. new|\n" + list) { indentLines($0, selection: $1) }
            .flatMap { m in run(m) { outdentLines($0, selection: $1) } }
        XCTAssertEqual(r?.components(separatedBy: "\n").first, "0. new|")
        XCTAssertEqual(r?.components(separatedBy: "\n").last, "9. i9")
        let grown = run("1. a\n" + (2...9).map { "\($0). x" }.joined(separator: "\n") + "|") {
            copyLines($0, selection: $1, up: false)
        }
        XCTAssertEqual(grown?.components(separatedBy: "\n").last, "10. x|")
    }

    func testAListElsewhereInTheNoteIsLeftAsWritten() {
        XCTAssertEqual(enter("1. a|\n2. b\n\nLater:\n1. x\n1. y"), "1. a\n2. |\n3. b\n\nLater:\n1. x\n1. y")
    }

    func testContinuationLinesStayInTheList() {
        XCTAssertEqual(enter("1. a|\n   more about a\n2. b"), "1. a\n2. |\n   more about a\n3. b")
    }

    func testTabIndentedNotesNestTheSameWay() {
        XCTAssertEqual(tab("1. a\n\t1. x\n2. b|"), "1. a\n\t1. x\n  2. b|")
    }

    // MARK: Styles

    func testRetypingTheFirstNumberAsALetterLettersTheList() {
        XCTAssertEqual(enter("  a. x|\n  2. y\n  3. z"), "  a. x\n  b. |\n  c. y\n  d. z")
    }

    func testALetteredSublistUnderANumberedList() {
        XCTAssertEqual(enter("1. a\n  a. x|\n2. b"), "1. a\n  a. x\n  b. |\n2. b")
        XCTAssertEqual(tab("1. a\n  a. x\n2. y|\n3. b"), "1. a\n  a. x\n  b. y|\n2. b")
    }

    func testRomanNumerals() {
        XCTAssertEqual(enter("i. a|"), "i. a\nii. |")
        XCTAssertEqual(enter("i. a\nii. b\niii. c\niv. d|"), "i. a\nii. b\niii. c\niv. d\nv. |")
        XCTAssertEqual(enter("I) a|\nII) b"), "I) a\nII) |\nIII) b")
    }

    func testAnHIsFollowedByAnI() {
        XCTAssertEqual(enter("h. a|"), "h. a\ni. |")
    }

    func testTheFirstItemsDelimiterAndCaseCarry() {
        XCTAssertEqual(enter("A) a|\n2. b"), "A) a\nB) |\nC) b")
    }

    func testDeletingTheFirstLetteredItemKeepsTheListAtA() {
        XCTAssertEqual(run("a. x|\nb. y\nc. z") { deleteLines($0, selection: $1) }, "a. y|\nb. z")
    }

    func testLettersPastZGoOnInNumbers() {
        XCTAssertEqual(MarkdownListStyle.lowerAlpha.label(26), "z")
        XCTAssertEqual(MarkdownListStyle.lowerAlpha.label(27), "27")
        XCTAssertEqual(MarkdownListStyle.upperRoman.label(14), "XIV")
    }

    func testProseThatLooksLikeAMarkerIsNotAList() {
        for line in ["Mr. Smith", "OK. fine", "e.g. this", "mix. it", "DC. area", "vv. no", "abc. no"] {
            XCTAssertNil(markdownListPrefix(of: line), line)
        }
        for line in ["a. x", "Z) x", "iv. x", "XX. x", "1) x"] {
            XCTAssertNotNil(markdownListPrefix(of: line), line)
        }
    }

    func testLetteredItemsHangInTheGutter() {
        let text = "b. item"
        let block = markdownBlocks(in: text).first
        XCTAssertEqual(block.map { String(text[$0.marker]) }, "b. ")
    }

    // MARK: Retyping a marker

    private func typed(_ marked: String) -> String? { run(marked) { restyleList($0, selection: $1) } }

    func testTypingALetterOverTheFirstNumberRestylesTheList() {
        XCTAssertEqual(typed("1. a\n  a. |x\n  2. y\n    1. deeper\n  3. z\n2. b"),
                       "1. a\n  a. |x\n  b. y\n    1. deeper\n  c. z\n2. b")
    }

    func testRetypingALaterItemIsLeftAlone() {
        XCTAssertNil(typed("1. a\nb. |x\n3. c"))
    }

    func testNothingToRestyleStandsAsTyped() {
        XCTAssertNil(typed("1. |x\n2. y"))
        XCTAssertNil(typed("a. x|\n2. y"))   // the caret isn't at the marker
        XCTAssertNil(typed("- |x\n2. y"))
    }

    func testTheFirstItemUnderABulletCounts() {
        XCTAssertEqual(typed("- a\n  i. |x\n  2. y"), "- a\n  i. |x\n  ii. y")
    }

    func testATypedStartingNumberIsKept() {
        XCTAssertEqual(typed("5. |x\n2. y\n3. z"), "5. |x\n6. y\n7. z")
        XCTAssertEqual(typed("  3. |x\n  2. y"), "  3. |x\n  4. y")
    }
}
