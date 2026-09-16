import XCTest
import AppKit
import SwiftUI

/// A note editor that can put you back where you were — what a project tile uses to reopen the note you
/// left when you step back into it (backlog 24).
@MainActor
final class NoteEditorReturnTests: XCTestCase {

    private final class Caret { var last: NSRange? }

    private func host(_ text: String, startsAt: NSRange?, caret: Caret) -> (NSWindow, NSTextView?) {
        TestApp.start()
        let binding = Binding(get: { text }, set: { _ in })
        let editor = MarkdownTextEditor(text: binding, opensAtStart: true, startsAt: startsAt,
                                        onSelectionChange: { caret.last = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor.frame(width: 400, height: 300))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, Self.textView(in: window.contentView))
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    func testTheCaretStartsWhereTheHostSays() throws {
        let caret = Caret()
        let (window, found) = host("First line\nSecond line", startsAt: NSRange(location: 14, length: 0), caret: caret)
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(found)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 14, length: 0))
    }

    /// A place past the end of text that has since got shorter is no place; the note opens at its start.
    func testACaretPastTheEndFallsBackToTheStart() throws {
        let caret = Caret()
        let (window, found) = host("Short", startsAt: NSRange(location: 40, length: 0), caret: caret)
        defer { window.orderOut(nil) }
        XCTAssertEqual(try XCTUnwrap(found).selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCaretMovesAreReported() throws {
        let caret = Caret()
        let (window, found) = host("First line\nSecond line", startsAt: nil, caret: caret)
        defer { window.orderOut(nil) }
        try XCTUnwrap(found).setSelectedRange(NSRange(location: 3, length: 4))
        XCTAssertEqual(caret.last, NSRange(location: 3, length: 4))
    }
}
