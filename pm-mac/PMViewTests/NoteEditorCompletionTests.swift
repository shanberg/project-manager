import XCTest
import AppKit
import PmLib

/// The `@` and `/` loop in the note editor: typing a query, choosing from the list, and what the keys
/// mean when no list is up.
///
/// Driven through real `NSEvent`s and the view's own `insertText`, because what's being tested is
/// which keystrokes the view swallows — and a test that called the handler directly would pass
/// whether or not the key ever reached it.
@MainActor
final class NoteEditorCompletionTests: XCTestCase {

    // MARK: @ mentions

    /// The point of the whole loop: what lands in the file is the vault's syntax, not what was typed.
    func testAcceptingAMentionWritesAWikilink() {
        let editor = NoteEditor()
        editor.reset("waiting: ")
        editor.type("@web")
        XCTAssertTrue(editor.listIsUp, "typing a query should put the list up")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "waiting: [[W-1 Website Refresh]] ")
    }

    func testArrowingChangesWhichMatchLands() {
        let editor = NoteEditor()
        editor.reset("see ")
        editor.type("@w")
        editor.key(.down)
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "see [[W-3 Vendor Contract]] ")
    }

    func testTabAcceptsToo() {
        let editor = NoteEditor()
        editor.type("@kitchen")
        editor.key(.tab)
        XCTAssertEqual(editor.text, "[[H-2 Kitchen]] ")
    }

    /// An area carries no code, so its name is the whole of it.
    func testAnAreaResolvesByItsNameAlone() {
        let editor = NoteEditor()
        editor.type("@team")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "[[Team 1:1s]] ")
    }

    /// Escape puts the list away and hands the key back: the text typed so far is left standing, and
    /// the next Return means what Return usually means.
    func testEscapeDismissesWithoutTouchingTheText() {
        let editor = NoteEditor()
        editor.reset("waiting: ")
        editor.type("@web")
        editor.key(.escape)
        XCTAssertFalse(editor.listIsUp)
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "waiting: @web\n")
    }

    /// Dismissal is per sigil. Having declined help once, you still get it for the next name.
    func testASecondMentionStillOffersAList() {
        let editor = NoteEditor()
        editor.type("@web")
        editor.key(.escape)
        editor.type(" and @vendor")
        XCTAssertTrue(editor.listIsUp)
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "@web and [[W-3 Vendor Contract]] ")
    }

    /// **The collision rule.** A trailing ` @` is the notes format's focus marker, so a bare `@` must
    /// never be read as the start of a mention — and Return on that line has to go on continuing the
    /// list, which is the editor's own behaviour and exactly what the mention handler must not swallow.
    func testABareAtIsTheFocusMarkerAndNotAMention() {
        let editor = NoteEditor()
        editor.reset("- [ ] Ship the thing")
        editor.type(" @")
        XCTAssertFalse(editor.listIsUp)
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "- [ ] Ship the thing @\n- [ ] ")
    }

    /// A query matching nothing gets out of the way rather than sitting there blocking the keyboard.
    func testNoMatchesMeansNoList() {
        let editor = NoteEditor()
        editor.type("@zzzz")
        XCTAssertFalse(editor.listIsUp)
    }

    /// Negative control. If the fixture were inert every assertion above would pass on an empty view.
    func testTheEditorActuallyChangesBetweenSteps() {
        let editor = NoteEditor()
        editor.type("@zzzz")
        let before = editor.text
        editor.reset("")
        editor.type("@web")
        XCTAssertNotEqual(editor.text, before)
    }

    // MARK: / commands

    func testSlashTaskRewritesTheLine() {
        let editor = NoteEditor()
        editor.reset("Review the contract")
        editor.type(" /task")
        XCTAssertTrue(editor.listIsUp)
        editor.key(.returnKey)
        // The slash and the space in front of it go with it.
        XCTAssertEqual(editor.text, "- [ ] Review the contract")
    }

    /// A preset writes a resolved date, not the word that chose it — the file has to hold a date.
    func testSlashDueWritesAStoredDate() {
        let editor = NoteEditor()
        editor.reset("- [ ] Ship it")
        editor.type(" /due")
        editor.key(.returnKey)
        XCTAssertNotNil(editor.text.range(of: #"^- \[ \] Ship it due: \d{4}-\d{2}-\d{2}$"#,
                                          options: .regularExpression),
                        "expected a resolved date, got \(editor.text)")
    }

    /// The whole loop in one gesture: a slash command that writes the marker and then hands straight
    /// over to the `@` picker for the name.
    func testSlashWaitingHandsOverToTheMentionPicker() {
        let editor = NoteEditor()
        editor.reset("- [ ] Legal review")
        editor.type(" /wait")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "- [ ] Legal review waiting: @")
        XCTAssertTrue(editor.listIsUp, "the wait should open the picker rather than leaving a sigil")
        editor.type("vendor")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "- [ ] Legal review waiting: [[W-3 Vendor Contract]] ")
    }

    /// And what the loop produced is what the format reads back — the two halves meeting.
    func testWhatTheLoopWritesIsWhatTheFormatParses() {
        let editor = NoteEditor()
        editor.reset("- [ ] Legal review")
        editor.type(" /wait")
        editor.key(.returnKey)
        editor.type("vendor")
        editor.key(.returnKey)
        let content = TaskContent.split(String(editor.text.dropFirst(6)))
        XCTAssertEqual(content.waiting, "W-3 Vendor Contract")
        XCTAssertEqual(content.text, "Legal review")
    }

    /// Both sigils are scanned and the nearer one to the caret wins, so a mention typed after a slash
    /// is still a mention.
    func testTheNearerSigilWins() {
        let editor = NoteEditor()
        editor.reset("/task and ")
        editor.type("@web")
        XCTAssertTrue(editor.listIsUp)
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "/task and [[W-1 Website Refresh]] ")
    }

    /// A bare `/` offers everything, unlike a bare `@` — nothing in the notes format spells a lone
    /// slash, so there is no collision to avoid.
    func testABareSlashOffersTheList() {
        let editor = NoteEditor()
        editor.type("/")
        XCTAssertTrue(editor.listIsUp)
    }
}
