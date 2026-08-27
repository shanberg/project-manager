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

    func testWikilink() {
        XCTAssertEqual(pieces("see [[Design Notes]] first", .wikilink), ["Design Notes"])
        XCTAssertTrue(syntaxPieces("see [[Design Notes]] first").contains("[["))
    }

    func testWikilinkAliasReadsAndTargetDims() {
        let t = "see [[design-notes|the notes]]"
        XCTAssertEqual(pieces(t, .wikilink), ["the notes"])
        XCTAssertTrue(syntaxPieces(t).contains("design-notes"), "the target is dimmed syntax")
        XCTAssertTrue(syntaxPieces(t).contains("|"))
    }

    func testMarkdownLinksCarryTheirDestination() {
        let t = "a [one](https://x.dev) and [two](../notes/b.md)"
        let links = markdownLinks(in: t)
        XCTAssertEqual(links.map { $0.destination }, ["https://x.dev", "../notes/b.md"])
        XCTAssertEqual(links.map { String(t[$0.labelRange]) }, ["one", "two"])
        XCTAssertEqual(links.first.map { String(t[$0.range]) }, "[one](https://x.dev)")
    }

    func testWikilinksAreNotReadAsLinks() {
        XCTAssertTrue(markdownLinks(in: "see [[note]] there").isEmpty)
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

    // MARK: blocks

    private func blocks(_ text: String) -> [(MarkdownBlockKind, String, String, String)] {
        markdownBlocks(in: text).map { b in
            (b.kind, String(text[b.indent]), String(text[b.marker]),
             String(text[b.marker.upperBound..<b.range.upperBound]))
        }
    }

    func testBlocksCoverEveryLineIncludingBlanks() {
        let text = "one\n\n# two\n"
        let bs = markdownBlocks(in: text)
        XCTAssertEqual(bs.count, 4, "Three lines plus the empty one after the trailing newline")
        XCTAssertEqual(bs.map { String(text[$0.range]) }, ["one", "", "# two", ""])
    }

    func testBlockSplitsIndentFromMarker() {
        let bs = blocks("  - item")
        XCTAssertEqual(bs.count, 1)
        XCTAssertEqual(bs[0].0, .list)
        XCTAssertEqual(bs[0].1, "  ", "The indent is its own part, so the content column can step by it")
        XCTAssertEqual(bs[0].2, "- ", "The marker excludes the indent, so its hang is depth-independent")
        XCTAssertEqual(bs[0].3, "item")
    }

    func testBlockMarkerWidthIsDepthIndependent() {
        // The whole point of splitting indent from marker: `- ` is two characters at every depth, so
        // the hang is one constant and only the content column moves.
        for indent in ["", "  ", "    ", "\t"] {
            let bs = blocks(indent + "- item")
            XCTAssertEqual(bs[0].2, "- ", "Marker stays `- ` under indent \(indent.debugDescription)")
            XCTAssertEqual(bs[0].1, indent)
        }
    }

    func testBlockHeadingLevelAndMarker() {
        let bs = blocks("### Title")
        XCTAssertEqual(bs[0].0, .heading(level: 3))
        XCTAssertEqual(bs[0].2, "### ")
        XCTAssertEqual(bs[0].3, "Title")
    }

    func testBlockHashWithoutSpaceIsNotAHeading() {
        // Half-typed `#` must not reformat the line out from under the caret.
        XCTAssertEqual(blocks("#")[0].0, .paragraph)
        XCTAssertEqual(blocks("#tag")[0].0, .paragraph)
        XCTAssertEqual(blocks("####### seven")[0].0, .paragraph)
    }

    func testHashesHangBeforeTheSpaceArrives() {
        // The kind stays a paragraph — `#tag` is not a heading — but the hashes are still the marker,
        // so they hang. That is what lets a line be promoted to a heading without its words moving:
        // every step below puts the content on the same column.
        for (line, marker) in [("#Plain", "#"), ("# Plain", "# "),
                               ("##Plain", "##"), ("## Plain", "## "),
                               ("###Plain", "###"), ("### Plain", "### ")] {
            XCTAssertEqual(blocks(line)[0].2, marker, "marker of \(line.debugDescription)")
            XCTAssertEqual(blocks(line)[0].3, "Plain", "content of \(line.debugDescription)")
        }
        XCTAssertEqual(blocks("####### seven")[0].2, "", "Seven hashes is not a marker at all")
    }

    func testLoneBulletHangsButAWordJammedAgainstOneDoesNot() {
        XCTAssertEqual(blocks("-")[0].2, "-", "The first keystroke of a new item hangs")
        XCTAssertEqual(blocks("*")[0].2, "*")
        // `*emphasis*` opening a line is prose, not a bullet: hanging its asterisk would misread a
        // common thing to protect a rare one.
        XCTAssertEqual(blocks("*emphasis* opens the line")[0].2, "")
        XCTAssertEqual(blocks("-5 degrees overnight")[0].2, "")
    }

    func testBlockParagraphRangeIncludesTheNewline() {
        // A paragraph style has to cover the terminator, or AppKit lays the line out to suit whatever
        // style the newline kept.
        let text = "one\ntwo"
        let bs = markdownBlocks(in: text)
        XCTAssertEqual(String(text[bs[0].range]), "one")
        XCTAssertEqual(String(text[bs[0].paragraph]), "one\n")
        XCTAssertEqual(String(text[bs[1].paragraph]), "two", "The last line has no terminator to take")
        // Every paragraph range together covers the text exactly once, with no gap and no overlap.
        XCTAssertEqual(bs.map { String(text[$0.paragraph]) }.joined(), text)
    }

    func testBlockQuoteAndOrderedList() {
        XCTAssertEqual(blocks("> quoted")[0].0, .blockquote)
        XCTAssertEqual(blocks("> quoted")[0].2, "> ")
        XCTAssertEqual(blocks(">quoted")[0].2, ">")
        XCTAssertEqual(blocks("10. tenth")[0].0, .list)
        XCTAssertEqual(blocks("10. tenth")[0].2, "10. ")
    }

    func testBlockPlainAndBlankLinesHaveNoMarker() {
        XCTAssertEqual(blocks("just prose")[0].2, "")
        XCTAssertEqual(blocks("")[0].0, .paragraph)
        XCTAssertEqual(blocks("   ")[0].1, "   ", "A whitespace-only line is all indent")
    }

    func testBlockKindsAgreeWithSpans() {
        // A line the block scanner calls a heading is one the span tokenizer highlights as a heading,
        // and vice versa \u2014 they read the same grammar, so a note can't be shaped one way and styled another.
        let text = "# yes\n#no\n- item\n> quote\nplain"
        let kinds = markdownBlocks(in: text).map(\.kind)
        XCTAssertEqual(kinds, [.heading(level: 1), .paragraph, .list, .blockquote, .paragraph])
    }
}
