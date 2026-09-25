import AppKit
import XCTest

/// The line commands reach the editor from the keyboard, as real key events. The transforms themselves
/// are PmLib's and tested there (`MarkdownLineCommandsTests`); this is the routing.
@MainActor
final class NoteEditorLineCommandTests: XCTestCase {
    private func event(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags,
                       in editor: NoteEditor) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: editor.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testShiftOptionDownCopiesTheLine() {
        let editor = NoteEditor()
        editor.put("a\nb\nc", caretAt: 2)
        // As the hardware sends an arrow: `.function` and `.numericPad` ride along.
        editor.view.keyDown(with: event("\u{F701}", code: 125, [.shift, .option, .function, .numericPad], in: editor))
        XCTAssertEqual(editor.text, "a\nb\nb\nc")
        XCTAssertEqual(editor.caret, 4)
    }

    func testOptionUpStillMovesTheLine() {
        let editor = NoteEditor()
        editor.put("a\nb", caretAt: 2)
        editor.view.keyDown(with: event("\u{F700}", code: 126, [.option, .function, .numericPad], in: editor))
        XCTAssertEqual(editor.text, "b\na")
    }

    func testOptionReturnOpensALineWithoutSplitting() {
        let editor = NoteEditor()
        editor.put("- one two", caretAt: 5)
        editor.view.keyDown(with: event("\r", code: 36, [.option], in: editor))
        XCTAssertEqual(editor.text, "- one two\n- ")
        XCTAssertEqual(editor.caret, 12)
    }

    func testCommandKeysAreClaimedByTheEditorHoldingTheCaret() {
        let editor = NoteEditor()
        editor.put("a\nbc\nd", caretAt: 3)
        XCTAssertTrue(editor.view.performKeyEquivalent(with: event("K", code: 40, [.command, .shift], in: editor)))
        XCTAssertEqual(editor.text, "a\nd")
        editor.put("Title", caretAt: 2)
        XCTAssertTrue(editor.view.performKeyEquivalent(with: event("2", code: 19, [.control, .command], in: editor)))
        XCTAssertEqual(editor.text, "## Title")
        XCTAssertTrue(editor.view.performKeyEquivalent(with: event("x", code: 7, [.command, .shift], in: editor)))
        XCTAssertEqual(editor.text, "- [ ] ## Title")
    }

    /// Negative control: a view that doesn't hold the caret leaves the key for whoever does.
    func testAnEditorWithoutTheCaretLeavesTheKeyAlone() {
        let editor = NoteEditor()
        editor.put("a\nb", caretAt: 0)
        editor.window.makeFirstResponder(nil)
        XCTAssertFalse(editor.view.performKeyEquivalent(with: event("j", code: 38, [.command], in: editor)))
        XCTAssertEqual(editor.text, "a\nb")
    }

    func testExpandThenShrinkRetracesTheSteps() {
        let editor = NoteEditor()
        editor.put("hello world\nnext", caretAt: 2)
        let expand = event("\u{F703}", code: 124, [.control, .shift, .command, .function, .numericPad], in: editor)
        let shrink = event("\u{F702}", code: 123, [.control, .shift, .command, .function, .numericPad], in: editor)
        XCTAssertTrue(editor.view.performKeyEquivalent(with: expand))
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertTrue(editor.view.performKeyEquivalent(with: expand))
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 0, length: 11))
        XCTAssertTrue(editor.view.performKeyEquivalent(with: shrink))
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertTrue(editor.view.performKeyEquivalent(with: shrink))
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 2, length: 0))
    }

    /// Format ▸ Bold, Italic and Link: the item's action reaches the editor, and the menu writes ⌘B,
    /// ⌘I and ⌘K on them while open, like the line commands.
    func testFormatBoldItalicAndLinkReachTheEditor() {
        let editor = NoteEditor()
        editor.put("word", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(editor.view.tryToPerform(EditorLineCommand.bold.action, with: nil))
        XCTAssertEqual(editor.text, "**word**")

        let menu = NSMenu()
        let items = [EditorLineCommand.bold, .italic, .link].map {
            menu.addItem(withTitle: $0.title, action: $0.action, keyEquivalent: "")
        }
        EditorMenuKeys.shared.menuWillOpen(menu)
        XCTAssertEqual(items.map(\.keyEquivalent), ["b", "i", "k"])
        XCTAssertEqual(items.map(\.title), ["Bold", "Italic", "Link"])
        EditorMenuKeys.shared.menuDidClose(menu)
    }

    /// The Format menu shows keys it must not claim: a disabled main-menu item swallows its key, which
    /// would take ⌥↑ away from the board. See `EditorMenuKeys`.
    func testTheFormatMenuShowsItsKeysOnlyWhileOpen() {
        TestApp.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let menu = NSMenu()
        menu.delegate = EditorMenuKeys.shared
        let item = menu.addItem(withTitle: "Join Lines", action: EditorLineCommand.join.action, keyEquivalent: "")
        let heading = menu.addItem(withTitle: "Heading 3", action: EditorLineCommand.heading(3).action,
                                   keyEquivalent: "")
        heading.tag = 3
        let j = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: "j",
                                 charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        XCTAssertFalse(menu.performKeyEquivalent(with: j))

        EditorMenuKeys.shared.menuWillOpen(menu)
        XCTAssertEqual(item.keyEquivalent, "j")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(heading.keyEquivalent, "3")
        XCTAssertEqual(heading.keyEquivalentModifierMask, [.control, .command])
        // Negative control: with the key on it, the item does take the key.
        XCTAssertTrue(menu.performKeyEquivalent(with: j))

        EditorMenuKeys.shared.menuDidClose(menu)
        XCTAssertFalse(menu.performKeyEquivalent(with: j))
    }
}
