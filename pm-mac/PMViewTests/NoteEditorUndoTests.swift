import XCTest
import AppKit
import SwiftUI

/// Which undo stack a note editor's typing lands on.
///
/// Two answers, and both matter. A note in a window keeps the window's — implementing
/// `undoManagerForTextView:` at all is what puts that at risk, since a delegate that answers the
/// question answers it for good and a bare `nil` is documented both ways. A card on a canvas gets one
/// of its own, because the window's stack there is the *document's*, and typing must not put a step on
/// it per character. See `MarkdownTextEditor.undoManager` and `CanvasTextNodeView.editingUndo`.
@MainActor
final class NoteEditorUndoTests: XCTestCase {

    private final class Box { var value = "" }

    /// A coordinator wired to a text view in a window, the way `makeNSView` wires one.
    private func editor(stack: UndoManager?)
        -> (coordinator: MarkdownTextEditor.Coordinator, view: NSTextView, window: NSWindow) {
        TestApp.start()
        let box = Box()
        var editor = MarkdownTextEditor(text: Binding(get: { box.value }, set: { box.value = $0 }))
        editor.undoManager = stack
        let coordinator = editor.makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.delegate = coordinator
        window.contentView = view
        return (coordinator, view, window)
    }

    func testAHostWithNoOpinionKeepsTheWindowsStack() {
        let (coordinator, view, window) = editor(stack: nil)
        XCTAssertTrue(coordinator.undoManager(for: view) === window.undoManager)
    }

    func testAHostsOwnStackTakesTheTyping() {
        let mine = UndoManager()
        let (coordinator, view, window) = editor(stack: mine)
        XCTAssertTrue(coordinator.undoManager(for: view) === mine)
        XCTAssertFalse(mine === window.undoManager)
    }

    /// The point of the whole arrangement: what the text view registers goes on the host's stack, and
    /// the window's is left as it was found.
    func testTypingIsUndoneOnTheHostsStack() {
        let mine = UndoManager()
        let (_, view, window) = editor(stack: mine)
        window.makeFirstResponder(view)
        view.insertText("hello", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()

        XCTAssertTrue(mine.canUndo)
        XCTAssertFalse(window.undoManager?.canUndo ?? false)
        mine.undo()
        XCTAssertEqual(view.string, "")
    }
}

/// Text put into a note from outside — a merge on save, the file changing underneath an open note —
/// and what that does to the typing already on the undo stack. See `ShortcutTextView.replaceFromOutside`.
@MainActor
final class NoteEditorOutsideTextTests: XCTestCase {

    /// Each edit in a test is its own event, as it would be in the app. The undo manager groups by
    /// run-loop pass, so without a turn between them every edit in the test is one group and one ⌘Z
    /// takes the lot — which passes or fails for reasons that have nothing to do with the editor.
    private func endEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func type(_ text: String, into editor: NoteEditor) {
        editor.view.insertText(text, replacementRange: editor.view.selectedRange())
        editor.view.breakUndoCoalescing()
        endEvent()
    }

    private func putFromOutside(_ text: String, into editor: NoteEditor) {
        editor.view.replaceFromOutside(text)
        endEvent()
    }

    /// The crash this replaces: typing on the stack, the text swapped for a shorter one, then ⌘Z.
    /// Assigning `string` left the typing step pointing past the end, and AppKit raised
    /// `NSRangeException` from inside the undo.
    func testUndoAfterShorterOutsideTextStillLinesUp() throws {
        let editor = NoteEditor()
        editor.reset()
        type("hello world", into: editor)
        putFromOutside("hi", into: editor)
        XCTAssertEqual(editor.text, "hi")

        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.undo()
        XCTAssertEqual(editor.text, "hello world")
        undo.undo()
        XCTAssertEqual(editor.text, "")
    }

    /// A merge that adds text somebody else wrote, with typing either side of it: each ⌘Z takes back
    /// exactly one of the three, in order.
    func testOutsideTextIsOneStepAmongTheTyping() throws {
        let editor = NoteEditor()
        editor.reset()
        type("abc", into: editor)
        putFromOutside("abc\n\nfrom elsewhere", into: editor)
        editor.view.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
        type(" d", into: editor)
        XCTAssertEqual(editor.text, "abc\n\nfrom elsewhere d")

        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.undo()
        XCTAssertEqual(editor.text, "abc\n\nfrom elsewhere")
        undo.undo()
        XCTAssertEqual(editor.text, "abc")
        undo.undo()
        XCTAssertEqual(editor.text, "")
    }

    /// Only the span that differs is replaced, so a change at the end leaves the start alone — and
    /// the same text again is no step at all.
    func testOnlyTheDifferenceIsReplaced() throws {
        let editor = NoteEditor()
        editor.reset("one two three")
        endEvent()
        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.removeAllActions()

        putFromOutside("one two three", into: editor)
        XCTAssertFalse(undo.canUndo)

        putFromOutside("one two four", into: editor)
        XCTAssertEqual(editor.text, "one two four")
        undo.undo()
        XCTAssertEqual(editor.text, "one two three")
    }
}
