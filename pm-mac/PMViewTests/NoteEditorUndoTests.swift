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
