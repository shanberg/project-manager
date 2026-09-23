import XCTest
import AppKit

/// `MarkdownTextEditor.Coordinator.shouldClaimFocus` — the decision behind the delayed retries that
/// survive a SwiftUI `@FocusState` teardown racing the editor's own handoff (see `claimFocus`'s doc
/// comment). Asked directly, with no timer to wait on: the retries are real wall-clock delays, and a
/// test that raced them instead of this would be a test of the scheduler, not the decision.
///
/// **A retry has to tell "nobody's claimed it" from "somebody else has."** It used to check only
/// whether this text view still held the caret, so a retry landing after you had already stepped out
/// onto another tile found the caret gone — same as the teardown case it exists for — and took it
/// straight back, stranding the keyboard in a note you had already left.
@MainActor
final class NoteEditorFocusClaimTests: XCTestCase {

    private func window() -> NSWindow {
        TestApp.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The teardown case: nothing has claimed the window, so the retry should.
    func testClaimsWhenNothingHoldsTheWindow() {
        let window = window()
        let textView = NSTextView()
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.firstResponder === window)
        XCTAssertTrue(MarkdownTextEditor.Coordinator.shouldClaimFocus(window, textView))
    }

    /// Already holding it: nothing to do, and asking again would be a no-op at best.
    func testDoesNotClaimWhenItAlreadyHoldsFocus() {
        let window = window()
        let textView = NSTextView()
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertFalse(MarkdownTextEditor.Coordinator.shouldClaimFocus(window, textView))
    }

    /// Stepped out onto another tile: a specific view holds first responder on purpose, and a retry
    /// landing after that has no business taking it back. This is the bug: the old check only asked
    /// whether the text view still held focus, not who else did.
    func testDoesNotClaimWhenAnotherViewHoldsFocusOnPurpose() {
        let window = window()
        let textView = NSTextView()
        let anotherTile = NSView()
        window.contentView?.addSubview(textView)
        window.contentView?.addSubview(anotherTile)
        XCTAssertTrue(window.makeFirstResponder(anotherTile))
        XCTAssertFalse(MarkdownTextEditor.Coordinator.shouldClaimFocus(window, textView))
    }
}
