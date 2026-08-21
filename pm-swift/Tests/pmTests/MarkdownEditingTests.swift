import XCTest
@testable import PmLib

/// The editor behaviours a markdown editor is expected to have, tested as the pure text transforms
/// they're written as — no text view involved.
final class MarkdownEditingTests: XCTestCase {
    private func range(_ s: String, _ lo: Int, _ hi: Int) -> Range<String.Index> {
        s.index(s.startIndex, offsetBy: lo)..<s.index(s.startIndex, offsetBy: hi)
    }
    private func caret(_ s: String, _ at: Int) -> Range<String.Index> { range(s, at, at) }
    /// Renders a result as text with a `|` where the caret is, so expectations read like the editor.
    private func shown(_ r: (text: String, selection: Range<String.Index>)) -> String {
        var out = r.text
        out.insert("|", at: r.selection.lowerBound)
        return out
    }

    // MARK: prefixes

    func testListPrefixBullet() {
        let p = markdownListPrefix(of: "- item")
        XCTAssertEqual(p?.marker, "-")
        XCTAssertEqual(p?.indent, "")
        XCTAssertNil(p?.checkbox)
        XCTAssertEqual(p?.text, "- ")
    }

    func testListPrefixOrderedAndNested() {
        let p = markdownListPrefix(of: "    3) item")
        XCTAssertEqual(p?.indent, "    ")
        XCTAssertEqual(p?.marker, "3)")
        XCTAssertEqual(p?.number, 3)
        XCTAssertTrue(p?.isOrdered == true)
        XCTAssertEqual(p?.next, "    4) ")
    }

    func testListPrefixCheckbox() {
        XCTAssertEqual(markdownListPrefix(of: "- [x] done")?.checkbox, "[x]")
        XCTAssertEqual(markdownListPrefix(of: "- [x] done")?.text, "- [x] ")
        // A new item after a done one starts unchecked.
        XCTAssertEqual(markdownListPrefix(of: "- [x] done")?.next, "- [ ] ")
    }

    func testNonListLines() {
        XCTAssertNil(markdownListPrefix(of: "-word"), "a dash with no space is prose")
        XCTAssertNil(markdownListPrefix(of: "plain text"))
        XCTAssertNil(markdownListPrefix(of: "1x. item"))
    }

    func testQuotePrefix() {
        XCTAssertEqual(markdownQuotePrefix(of: "> quoted"), "> ")
        XCTAssertEqual(markdownQuotePrefix(of: ">> deep"), ">> ")
        XCTAssertNil(markdownQuotePrefix(of: "not quoted"))
    }

    // MARK: Return

    func testReturnContinuesBullet() {
        let t = "- one"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 5))!), "- one\n- |")
    }

    func testReturnIncrementsOrderedList() {
        let t = "1. one"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 6))!), "1. one\n2. |")
    }

    func testReturnCarriesCheckbox() {
        let t = "- [ ] task"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 10))!), "- [ ] task\n- [ ] |")
    }

    func testReturnKeepsIndentation() {
        let t = "  - deep"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 8))!), "  - deep\n  - |")
    }

    func testReturnRenumbersFollowingItems() {
        let t = "1. one\n2. two\n3. three"
        // Caret at the end of the first item: the new item is 2, and what follows shifts up.
        let r = continueList(t, selection: caret(t, 6))!
        XCTAssertEqual(r.text, "1. one\n2. \n3. two\n4. three")
    }

    func testReturnRenumberingStepsOverNestedItems() {
        let t = "1. one\n  - sub\n2. two"
        let r = continueList(t, selection: caret(t, 6))!
        XCTAssertEqual(r.text, "1. one\n2. \n  - sub\n3. two")
    }

    func testReturnOnEmptyItemEndsTheList() {
        let t = "- one\n- "
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 8))!), "- one\n|")
    }

    func testReturnOnEmptyCheckboxEndsTheList() {
        let t = "- [ ] "
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 6))!), "|")
    }

    func testReturnContinuesBlockquote() {
        let t = "> quoted"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 8))!), "> quoted\n> |")
    }

    func testReturnSplitsAnItemInTheMiddle() {
        let t = "- onetwo"
        XCTAssertEqual(shown(continueList(t, selection: caret(t, 5))!), "- one\n- |two")
    }

    func testReturnInsideTheMarkerIsOrdinary() {
        let t = "- one"
        XCTAssertNil(continueList(t, selection: caret(t, 1)), "caret in the marker: plain newline")
    }

    func testReturnInProseIsOrdinary() {
        let t = "just prose"
        XCTAssertNil(continueList(t, selection: caret(t, 10)))
    }

    func testReturnReplacesASelection() {
        let t = "- onetwo"
        let r = continueList(t, selection: range(t, 5, 8))!
        XCTAssertEqual(shown(r), "- one\n- |")
    }

    // MARK: Tab

    func testIndentAndOutdentASingleLine() {
        let t = "- item"
        let indented = indentLines(t, selection: caret(t, 6))
        XCTAssertEqual(shown(indented), "  - item|")
        let back = outdentLines(indented.text, selection: indented.selection)
        XCTAssertEqual(shown(back), "- item|")
    }

    func testIndentASelectionOfLines() {
        let t = "- a\n- b"
        let r = indentLines(t, selection: range(t, 0, 7))
        XCTAssertEqual(r.text, "  - a\n  - b")
        XCTAssertEqual(String(r.text[r.selection]), "- a\n  - b", "the selection still covers both lines")
    }

    func testOutdentLeavesUnindentedLinesAlone() {
        let t = "- a"
        let r = outdentLines(t, selection: caret(t, 3))
        XCTAssertEqual(shown(r), "- a|")
    }

    func testOutdentTakesATab() {
        let t = "\t- a"
        XCTAssertEqual(outdentLines(t, selection: caret(t, 4)).text, "- a")
    }

    func testTabIndentsOnlyInListsAndMultilineSelections() {
        let list = "- item"
        XCTAssertTrue(tabShouldIndent(list, selection: caret(list, 6)))
        let prose = "just prose"
        XCTAssertFalse(tabShouldIndent(prose, selection: caret(prose, 10)))
        let two = "one\ntwo"
        XCTAssertTrue(tabShouldIndent(two, selection: range(two, 0, 7)))
    }

    // MARK: moving lines

    func testMoveLineDownAndBack() {
        let t = "one\ntwo\nthree"
        let down = moveLines(t, selection: caret(t, 0), up: false)!
        XCTAssertEqual(down.text, "two\none\nthree")
        XCTAssertEqual(shown(down), "two\n|one\nthree", "the caret rides along")
        let up = moveLines(down.text, selection: down.selection, up: true)!
        XCTAssertEqual(up.text, t)
    }

    func testMoveLinesStopsAtTheEnds() {
        let t = "one\ntwo"
        XCTAssertNil(moveLines(t, selection: caret(t, 0), up: true))
        XCTAssertNil(moveLines(t, selection: caret(t, 7), up: false))
    }

    func testMoveASelectionOfLines() {
        let t = "a\nb\nc"
        let r = moveLines(t, selection: range(t, 0, 3), up: false)!
        XCTAssertEqual(r.text, "c\na\nb")
    }

    func testDuplicateLineSelectsTheCopy() {
        let t = "- item"
        let r = duplicateLines(t, selection: caret(t, 6))
        XCTAssertEqual(r.text, "- item\n- item")
        XCTAssertEqual(shown(r), "- item\n- item|", "the caret lands in the copy")
    }

    // MARK: typing and pasting

    func testWrapSelectionKeepsContentSelected() {
        let t = "word"
        let r = wrapSelection(t, selection: range(t, 0, 4), open: "*", close: "*")
        XCTAssertEqual(r.text, "*word*")
        XCTAssertEqual(String(r.text[r.selection]), "word")
        // Typing the marker again wraps it again, rather than toggling back off.
        let again = wrapSelection(r.text, selection: r.selection, open: "*", close: "*")
        XCTAssertEqual(again.text, "**word**")
    }

    func testWrapPairs() {
        XCTAssertEqual(markdownWrapPair(for: "(")?.close, ")")
        XCTAssertEqual(markdownWrapPair(for: "`")?.open, "`")
        XCTAssertNil(markdownWrapPair(for: "a"))
        XCTAssertNil(markdownWrapPair(for: "-"))
    }

    func testPastableURLs() {
        XCTAssertTrue(isPastableURL("https://example.com/a?b=c"))
        XCTAssertTrue(isPastableURL("  https://example.com  "))
        XCTAssertTrue(isPastableURL("mailto:someone@example.com"))
        XCTAssertFalse(isPastableURL("just some text"))
        XCTAssertFalse(isPastableURL("https://example.com and more"))
        XCTAssertFalse(isPastableURL(""))
    }

    func testPasteLinkOverASelection() {
        let t = "see the docs here"
        let r = pasteLink(t, selection: range(t, 8, 12), url: "https://x.dev")
        XCTAssertEqual(r.text, "see the [docs](https://x.dev) here")
        XCTAssertEqual(shown(r), "see the [docs](https://x.dev)| here", "caret lands after the link")
    }

    // MARK: dropped files

    func testFileInTheNotesOwnFolderLinksRelatively() {
        let note = URL(fileURLWithPath: "/vault/Projects/site.md")
        let file = URL(fileURLWithPath: "/vault/Projects/spec.pdf")
        XCTAssertEqual(markdownFileLink(for: file, relativeTo: note), "[spec](spec.pdf)")
    }

    func testImagesEmbed() {
        let note = URL(fileURLWithPath: "/vault/Projects/site.md")
        let file = URL(fileURLWithPath: "/vault/attachments/shot one.png")
        XCTAssertEqual(markdownFileLink(for: file, relativeTo: note),
                       "![shot one](../attachments/shot%20one.png)")
    }

    func testDistantFilesLinkAbsolutely() {
        let note = URL(fileURLWithPath: "/vault/Projects/site.md")
        let file = URL(fileURLWithPath: "/Users/someone/Downloads/report.pdf")
        XCTAssertEqual(markdownFileLink(for: file, relativeTo: note),
                       "[report](/Users/someone/Downloads/report.pdf)")
    }

    func testNoNoteLocationMeansAbsolute() {
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(markdownFileLink(for: file, relativeTo: nil), "[a](/tmp/a.txt)")
    }
}
