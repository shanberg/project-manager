import XCTest
import AppKit
import PmLib

/// How a token is laid out and drawn, asserted through the layout manager rather than through pixels.
///
/// Glyph *properties* need no bitmap at all: `propertyForGlyph(at:)` and `boundingRect(forGlyphRange:)`
/// turn "this is hidden", "this has padding" and "this wraps here" into ordinary assertions.
@MainActor
final class TokenDrawingTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TokenDisplay.defaultsKey)
        super.tearDown()
    }

    /// The brackets become **control characters**, not null glyphs. A null glyph has no width and
    /// simply disappears, which is what produced a bare background hugging the letters; a control
    /// character takes a width of the layout manager's choosing and paints nothing, so the same
    /// characters that were punctuation become the space inside the pill.
    func testTheBracketsBecomeControlCharacters() {
        let editor = NoteEditor()
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()
        XCTAssertEqual(editor.glyphProperty(at: 4), .controlCharacter)
        XCTAssertEqual(editor.glyphProperty(at: 5), .controlCharacter)
        XCTAssertEqual(editor.glyphProperty(at: 25), .controlCharacter)
        XCTAssertEqual(editor.glyphProperty(at: 26), .controlCharacter)
    }

    func testTheNameAndTheProseAroundItAreOrdinaryGlyphs() {
        let editor = NoteEditor()
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()
        XCTAssertNotEqual(editor.glyphProperty(at: 8), .controlCharacter)
        XCTAssertNotEqual(editor.glyphProperty(at: 0), .controlCharacter)
    }

    func testTheBracketsStillTakeUpRoomSoThePillHasPadding() {
        let editor = NoteEditor()
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()
        XCTAssertGreaterThan(editor.glyphWidth(at: 4), 0)
    }

    /// Negative control, and the preference: with "Show link syntax" on, the brackets are ordinary
    /// glyphs again — and turning it back off restores the pill.
    func testShowingSyntaxDrawsTheBracketsNormally() {
        let editor = NoteEditor()
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()

        UserDefaults.standard.set(true, forKey: TokenDisplay.defaultsKey)
        editor.regenerateGlyphs()
        XCTAssertNotEqual(editor.glyphProperty(at: 4), .controlCharacter)

        UserDefaults.standard.set(false, forKey: TokenDisplay.defaultsKey)
        editor.regenerateGlyphs()
        XCTAssertEqual(editor.glyphProperty(at: 4), .controlCharacter)
    }

    // MARK: clicking

    /// A **plain** click, not ⌘-click. The editor requires ⌘ to follow a markdown link because the
    /// caret has to be able to land inside `[label](url)` to edit it — and that reason doesn't survive
    /// an atomic token, where the caret can never land inside.
    func testAPlainClickOnATokenOpensWhatItNames() {
        let editor = NoteEditor()
        var opened: String?
        editor.view.onOpenProject = { opened = $0 }
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()
        editor.click(at: centre(of: NSRange(location: 8, length: 3), in: editor))
        XCTAssertEqual(opened, "W-1 Website Refresh")
    }

    func testAClickInTheProseOpensNothing() {
        let editor = NoteEditor()
        var opened: String?
        editor.view.onOpenProject = { opened = $0 }
        editor.reset("see [[W-1 Website Refresh]] now")
        editor.layOut()
        let line = centre(of: NSRange(location: 8, length: 3), in: editor)
        editor.click(at: NSPoint(x: 2, y: line.y))
        XCTAssertNil(opened)
    }

    private func centre(of characters: NSRange, in editor: NoteEditor) -> NSPoint {
        let glyphs = editor.layoutManager.glyphRange(forCharacterRange: characters,
                                                     actualCharacterRange: nil)
        let rect = editor.layoutManager.boundingRect(forGlyphRange: glyphs, in: editor.container)
        return NSPoint(x: rect.midX, y: rect.midY)
    }
}

/// What the row's label reports when SwiftUI asks how big it wants to be.
///
/// Every bug in this list was a plausible-looking layout rather than an error, which is why the
/// measurements are pinned against a second measurement taken a different way.
@MainActor
final class TokenLabelSizingTests: XCTestCase {

    private let sample = "Draft the launch announcement"

    private func label(_ string: String) -> (view: TokenLabelView, ideal: NSSize) {
        TestApp.start()
        let view = TokenLabelView()
        view.attributed = NSAttributedString(string: string,
                                             attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return (view, view.size(fitting: TokenLabelView.unbounded))
    }

    /// Pinned against a plain `NSAttributedString.size()`, which does the same measurement by a
    /// completely different route — so this can't agree with a bug by copying it.
    ///
    /// The loose version of this check ("less than 400pt") passed happily while
    /// `CGFloat.greatestFiniteMagnitude` as a container width was overflowing TextKit's arithmetic and
    /// the "ideal" being returned was garbage.
    func testTheIdealWidthMatchesAnIndependentMeasurement() {
        let (_, ideal) = label(sample)
        let reference = NSAttributedString(string: sample,
                                           attributes: [.font: NSFont.systemFont(ofSize: 13)]).size()
        XCTAssertEqual(ideal.width, reference.width, accuracy: 2)
        XCTAssertLessThan(ideal.height, reference.height * 1.6, "it should be one line tall")
    }

    /// Offered a whole row it asks only for its ideal, so the spacer beside it gets the rest.
    func testOfferedAWholeRowItAsksForItsIdeal() {
        let (view, ideal) = label(sample)
        let wide = view.size(offered: 900)
        XCTAssertEqual(wide.width, ideal.width, accuracy: 1)
        XCTAssertEqual(wide.height, ideal.height, accuracy: 1)
    }

    func testTooNarrowItWrapsRatherThanTruncating() {
        let (view, ideal) = label(sample)
        let narrow = view.size(offered: 80)
        XCTAssertGreaterThan(narrow.height, ideal.height)
        XCTAssertLessThanOrEqual(narrow.width, 80)
    }

    /// **The zero probe**, which is what decides how an `HStack` treats it.
    ///
    /// Answering it with the ideal made the label look inflexible at its full width, and a stack with
    /// two apparently-inflexible children divides the space between them — which is why every task
    /// took half the row and wrapped four lines deep while the window had room to spare.
    func testTheZeroProbeReportsAWrappableMinimum() {
        let (view, ideal) = label(sample)
        let minimum = view.size(offered: 0)
        XCTAssertLessThan(minimum.width, ideal.width)
        XCTAssertGreaterThan(minimum.width, 20, "a minimum should still be one word wide")
        XCTAssertLessThan(minimum.width, ideal.width - 40, "which is what reports it as flexible")
    }

    /// The brackets contribute exactly the padding that was set — not twice it.
    ///
    /// `boundingBoxForControlGlyphAt` is asked once per *glyph*, and there are two brackets a side, so
    /// the obvious "half the padding per side" gives the token double. Measurable only as the
    /// difference between the token laid out and its bare name.
    func testTheBracketsAddTheConfiguredPaddingAndNoMore() {
        let (view, withToken) = label("[[Vendor]]")
        view.attributed = NSAttributedString(string: "Vendor",
                                             attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let bare = view.size(fitting: TokenLabelView.unbounded)
        let contributed = withToken.width - bare.width
        XCTAssertGreaterThan(contributed, 6, "contributed \(contributed)pt")
        XCTAssertLessThan(contributed, 10, "contributed \(contributed)pt")
    }
}
