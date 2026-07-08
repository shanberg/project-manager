import XCTest
@testable import PmLib

final class MarkdownHighlightTests: XCTestCase {
    // MARK: helpers

    private func pieces(_ text: String, _ kind: MarkdownSpanKind) -> [String] {
        markdownSpans(in: text).filter { $0.kind == kind }.map { String(text[$0.range]) }
    }
    private func syntaxPieces(_ text: String) -> [String] {
        markdownSpans(in: text).filter { $0.kind == .syntax }.map { String(text[$0.range]) }
    }
    private func headings(_ text: String) -> [(Int, String)] {
        markdownSpans(in: text).compactMap { s in
            if case .heading(let l) = s.kind { return (l, String(text[s.range])) } else { return nil }
        }
    }
    private func range(_ s: String, _ lo: Int, _ hi: Int) -> Range<String.Index> {
        s.index(s.startIndex, offsetBy: lo)..<s.index(s.startIndex, offsetBy: hi)
    }

    // MARK: spans

    func testHeadingLevelAndSyntax() {
        let hs = headings("### Title")
        XCTAssertEqual(hs.count, 1)
        XCTAssertEqual(hs.first?.0, 3)
        XCTAssertEqual(hs.first?.1, "Title")
        XCTAssertTrue(syntaxPieces("### Title").contains("### "), "The `### ` marker is dimmable syntax")
    }

    func testBold() {
        XCTAssertEqual(pieces("a **strong** b", .bold), ["strong"])
        XCTAssertEqual(syntaxPieces("a **strong** b").filter { $0 == "**" }.count, 2)
    }

    func testItalic() {
        XCTAssertEqual(pieces("a *soft* b", .italic), ["soft"])
        XCTAssertEqual(pieces("a _soft_ b", .italic), ["soft"])
    }

    func testBoldIsNotMisreadAsItalic() {
        // The `**` markers must not be picked up as single-asterisk italics.
        XCTAssertEqual(pieces("**strong**", .italic), [])
        XCTAssertEqual(pieces("**strong**", .bold), ["strong"])
    }

    func testCode() {
        XCTAssertEqual(pieces("run `pm show` now", .code), ["pm show"])
        XCTAssertTrue(syntaxPieces("run `pm show` now").contains("`"))
    }

    func testStrikethrough() {
        XCTAssertEqual(pieces("~~gone~~", .strikethrough), ["gone"])
    }

    func testLink() {
        let t = "see [docs](https://x.dev) here"
        XCTAssertEqual(pieces(t, .link), ["docs"])
        XCTAssertTrue(syntaxPieces(t).contains("https://x.dev"), "URL is dimmed syntax")
        XCTAssertTrue(syntaxPieces(t).contains("["))
    }

    func testListMarker() {
        XCTAssertEqual(pieces("- item", .listMarker), ["- "])
        XCTAssertEqual(pieces("1. item", .listMarker), ["1. "])
    }

    func testBlockquote() {
        XCTAssertEqual(pieces("> quoted", .blockquote), ["quoted"])
        XCTAssertTrue(syntaxPieces("> quoted").contains("> "))
    }

    func testMultilineHeadingsAndLists() {
        let t = "# One\n\nsome text\n\n## Two\n- a\n- b"
        XCTAssertEqual(headings(t).map { $0.0 }, [1, 2])
        XCTAssertEqual(pieces(t, .listMarker), ["- ", "- "])
    }

    func testPlainTextHasNoSpans() {
        XCTAssertTrue(markdownSpans(in: "just a plain sentence, nothing to style").isEmpty)
    }

    // MARK: toggleWrap

    func testToggleWrapAddsMarkers() {
        let (t, sel) = toggleWrap("hello", selection: range("hello", 0, 5), marker: "**")
        XCTAssertEqual(t, "**hello**")
        XCTAssertEqual(String(t[sel]), "hello")
    }

    func testToggleWrapRemovesMarkersOutsideSelection() {
        let (t, sel) = toggleWrap("**hello**", selection: range("**hello**", 2, 7), marker: "**")
        XCTAssertEqual(t, "hello")
        XCTAssertEqual(String(t[sel]), "hello")
    }

    func testToggleWrapRemovesMarkersInsideSelection() {
        let (t, sel) = toggleWrap("**hello**", selection: range("**hello**", 0, 9), marker: "**")
        XCTAssertEqual(t, "hello")
        XCTAssertEqual(String(t[sel]), "hello")
    }

    func testToggleWrapEmptySelectionPlacesCaretBetweenMarkers() {
        let (t, sel) = toggleWrap("", selection: range("", 0, 0), marker: "**")
        XCTAssertEqual(t, "****")
        XCTAssertTrue(sel.isEmpty)
        XCTAssertEqual(t.distance(from: t.startIndex, to: sel.lowerBound), 2)
    }

    func testToggleWrapItalicSingleChar() {
        let (t, sel) = toggleWrap("word", selection: range("word", 0, 4), marker: "*")
        XCTAssertEqual(t, "*word*")
        XCTAssertEqual(String(t[sel]), "word")
    }

    func testWrapLinkSelectsURLPlaceholder() {
        let (t, sel) = wrapLink("site", selection: range("site", 0, 4))
        XCTAssertEqual(t, "[site](url)")
        XCTAssertEqual(String(t[sel]), "url")
    }
}
