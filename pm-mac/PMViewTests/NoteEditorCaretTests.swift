import XCTest
import AppKit
import SwiftUI

/// Text that arrives from outside an open editor leaves the caret where you put it.
///
/// A session note's save tidies the text and hands the tidy copy back to the editor, and it saves
/// whenever the window loses key — which is what going to another app to copy something does. The
/// editor opens at its start, and it used to apply that to *every* outside change, so the caret went
/// to the top of the note behind your back and the paste you came back with landed there.
@MainActor
final class NoteEditorCaretTests: XCTestCase {

    private var window: NSWindow!
    private var hosting: NSHostingView<MarkdownTextEditor>!

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        hosting = nil
        super.tearDown()
    }

    private func editor(_ text: String) -> MarkdownTextEditor {
        MarkdownTextEditor(text: Binding(get: { text }, set: { _ in }), opensAtStart: true)
    }

    private func host(_ text: String) throws -> NSTextView {
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: editor(text))
        window.contentView = hosting
        window.orderFront(nil)
        settle()
        return try XCTUnwrap(Self.textView(in: hosting))
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    func testATidiedCopyHandedBackKeepsTheCaret() throws {
        let textView = try host("First paragraph.\n\nSecond one.   \n\n")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        hosting.rootView = editor("First paragraph.\n\nSecond one.")
        settle()
        XCTAssertEqual(textView.string, "First paragraph.\n\nSecond one.", "the outside change should land")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// Still true of the one outside change that *is* an opening: text arriving in an empty editor.
    func testTextArrivingInAnEmptyEditorStillOpensAtTheStart() throws {
        let textView = try host("")
        hosting.rootView = editor("A note that arrived after the editor was made.")
        settle()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }
}
