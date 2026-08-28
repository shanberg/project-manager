import XCTest
@testable import PmLib

final class MentionQueryTests: XCTestCase {

    private func query(_ text: String, caretAfter marker: String? = nil) -> MentionQuery? {
        let caret = marker.flatMap { text.range(of: $0)?.upperBound } ?? text.endIndex
        return mentionQuery(in: text, caret: caret)
    }

    /// The ordinary case: a sigil and some letters.
    func testFindsAMentionBeingTyped() {
        let text = "talked to @web"
        let m = query(text)
        XCTAssertEqual(m?.query, "web")
        XCTAssertEqual(text[m!.range], "@web")
    }

    /// Project titles have spaces in them, so the query has to allow them.
    func testQueryMaySpanSpaces() {
        XCTAssertEqual(query("waiting: @Website Ref")?.query, "Website Ref")
    }

    /// A bare `@` is the focus marker, not a mention — the collision rule 4 exists for.
    func testBareSigilIsNotAMention() {
        XCTAssertNil(query("- [ ] Ship the thing @"))
    }

    /// The sigil has to start a word.
    func testEmailAddressIsNotAMention() {
        XCTAssertNil(query("write to dana@exam"))
    }

    /// A mention can't reach back across a line break.
    func testDoesNotCrossANewline() {
        XCTAssertNil(query("@website\nnext line"))
    }

    /// Nor keep claiming everything typed after a stray sigil.
    func testGivesUpPastTheCap() {
        XCTAssertNil(mentionQuery(in: "@" + String(repeating: "x", count: 60),
                                  caret: ("@" + String(repeating: "x", count: 60)).endIndex))
    }

    /// The caret mid-line reads the mention it's inside, not one later in the line.
    func testReadsTheMentionAtTheCaret() {
        let text = "@one and @two"
        let m = query(text, caretAfter: "@on")
        XCTAssertEqual(m?.query, "on")
    }

    /// Accepting writes the vault's syntax, not the sigil, and leaves the caret past it.
    func testApplyWritesAWikilinkAndPlacesTheCaret() {
        let text = "waiting: @web"
        let m = mentionQuery(in: text, caret: text.endIndex)!
        let (out, selection) = applyMention(text, range: m.range, target: "W-1 Website Refresh")
        XCTAssertEqual(out, "waiting: [[W-1 Website Refresh]] ")
        XCTAssertEqual(out.distance(from: out.startIndex, to: selection.lowerBound), out.count)
    }

    /// Accepting mid-sentence keeps what follows.
    func testApplyKeepsTheRestOfTheLine() {
        let text = "ask @web about the copy"
        let m = mentionQuery(in: text, caret: text.range(of: "@web")!.upperBound)!
        let (out, _) = applyMention(text, range: m.range, target: "W-1 Website Refresh")
        XCTAssertEqual(out, "ask [[W-1 Website Refresh]]  about the copy")
    }

    // MARK: - atomic tokens

    private func index(_ text: String, _ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: offset)
    }

    /// Both plain links and embeds are tokens.
    func testFindsEverySpan() {
        let text = "see [[W-1 Site]] and ![[shot.png]]"
        let spans = wikilinkSpans(in: text).map { String(text[$0]) }
        XCTAssertEqual(spans, ["[[W-1 Site]]", "![[shot.png]]"])
    }

    /// The edges are beside the token, not inside it — both are places a caret may legitimately rest.
    func testEdgesAreNotInside() {
        let text = "a [[X]] b"
        XCTAssertNil(wikilinkSpan(in: text, strictlyContaining: index(text, 2)))
        XCTAssertNil(wikilinkSpan(in: text, strictlyContaining: index(text, 7)))
        XCTAssertNotNil(wikilinkSpan(in: text, strictlyContaining: index(text, 4)))
    }

    /// A click inside lands on the nearer edge.
    func testCaretSnapsToTheNearestEdge() {
        let text = "a [[Website]] b"
        XCTAssertEqual(text.distance(from: text.startIndex, to: snapCaret(in: text, to: index(text, 5))), 2)
        XCTAssertEqual(text.distance(from: text.startIndex, to: snapCaret(in: text, to: index(text, 11))), 13)
    }

    /// Half a token is never a useful selection.
    func testSelectionWidensOverAPartlyCoveredToken() {
        let text = "a [[Website]] b"
        let widened = snapSelection(in: text, to: index(text, 0)..<index(text, 6))
        XCTAssertEqual(String(text[widened]), "a [[Website]]")
    }

    /// ← from just after a token lands just before it, rather than between the brackets.
    func testSteppingBackwardsClearsTheWholeToken() {
        let text = "a [[Website]] b"
        let stepped = stepCaret(in: text, from: index(text, 13), forward: false)
        XCTAssertEqual(text.distance(from: text.startIndex, to: stepped!), 2)
    }

    /// And → from just before it lands just after.
    func testSteppingForwardsClearsTheWholeToken() {
        let text = "a [[Website]] b"
        let stepped = stepCaret(in: text, from: index(text, 2), forward: true)
        XCTAssertEqual(text.distance(from: text.startIndex, to: stepped!), 13)
    }

    /// Ordinary characters still step one at a time.
    func testSteppingIsOrdinaryAwayFromTokens() {
        let text = "abc"
        XCTAssertEqual(text.distance(from: text.startIndex,
                                     to: stepCaret(in: text, from: index(text, 1), forward: true)!), 2)
        XCTAssertNil(stepCaret(in: text, from: text.startIndex, forward: false))
        XCTAssertNil(stepCaret(in: text, from: text.endIndex, forward: true))
    }

    /// Backspace after a token takes all of it, never leaving `[[]]` behind.
    func testBackspaceTakesTheWholeToken() {
        let text = "waiting: [[W-1 Website Refresh]]"
        let result = deleteWikilinkBefore(text, index: text.endIndex)
        XCTAssertEqual(result?.text, "waiting: ")
        XCTAssertNil(deleteWikilinkBefore("plain text", index: "plain text".endIndex))
    }

    // MARK: - reading a token rather than its markup

    /// A row shows the name, not the brackets.
    func testDisplayDropsTheBrackets() {
        XCTAssertEqual(displayingWikilinks("Update the contract [[W-3 Vendor Contract]] today"),
                       "Update the contract W-3 Vendor Contract today")
    }

    /// An alias is what it reads as — the vault's own rule.
    func testDisplayPrefersTheAlias() {
        XCTAssertEqual(displayingWikilinks("see [[W-1 Website Refresh|the refresh]]"),
                       "see the refresh")
    }

    /// Several in one line, and text either side of each.
    func testDisplayHandlesSeveral() {
        XCTAssertEqual(displayingWikilinks("[[A]] and [[B]] and [[C]]"), "A and B and C")
    }

    /// An embed names a picture; turning it into a bare word would claim a file is a sentence.
    func testDisplayLeavesEmbedsAlone() {
        XCTAssertEqual(displayingWikilinks("before ![[shot.png]] after"), "before ![[shot.png]] after")
    }

    /// Text with no token is returned unchanged.
    func testDisplayLeavesPlainTextAlone() {
        XCTAssertEqual(displayingWikilinks("nothing to see"), "nothing to see")
    }

    /// The span form gives a styler where to draw, and agrees with the string form about what.
    func testDisplaySpansAgreeWithTheStringForm() {
        let text = "Update [[W-3 Vendor Contract]] now"
        let spans = wikilinkDisplaySpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].name, "W-3 Vendor Contract")
        XCTAssertEqual(String(text[spans[0].range]), "[[W-3 Vendor Contract]]")
    }

    /// Every reported range names exactly its own token in the display string — the arithmetic that
    /// shifts each token left by everything removed before it.
    func testDisplayRangesLandOnTheNames() {
        for text in ["Update [[W-3 Vendor Contract]] now",
                     "[[A]] and [[B]] and [[C]]",
                     "[[W-1 Website Refresh|the refresh]] then [[H-2 Kitchen]]",
                     "no tokens here",
                     "trailing [[Z]]",
                     "![[shot.png]] and [[A]]"] {
            let shown = displayingWikilinks(text)
            let characters = Array(shown)
            for range in wikilinkDisplayRanges(in: text) {
                XCTAssertLessThanOrEqual(range.offset + range.length, characters.count, text)
                XCTAssertEqual(String(characters[range.offset..<(range.offset + range.length)]),
                               range.name, "in \(text)")
            }
        }
    }
}
