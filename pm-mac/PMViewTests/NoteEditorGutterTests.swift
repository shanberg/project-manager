import XCTest
import AppKit
import SwiftUI

/// The margin a note's markers hang into is spent only where a column can afford it: a wide editor
/// hangs `## ` and `- ` out to the left of one content column, a narrow one sets them inline.
@MainActor
final class NoteEditorGutterTests: XCTestCase {

    private static let note = "## Heading\n- a bullet long enough to wrap onto a second line when the column is narrow, which it is\nProse"

    private func host(width: CGFloat) -> (NSWindow, NSTextView?) {
        TestApp.start()
        let binding = Binding(get: { Self.note }, set: { _ in })
        let editor = MarkdownTextEditor(text: binding, opensAtStart: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, Self.textView(in: window.contentView))
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    private static var advance: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: MarkdownTextEditor.baseFont]).width
    }

    /// Where the character at `offset` is drawn, from the container's left edge.
    private static func x(of offset: Int, in textView: NSTextView) throws -> CGFloat {
        let layout = try XCTUnwrap(textView.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let glyph = layout.glyphIndexForCharacter(at: offset)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
            + layout.location(forGlyphAt: glyph).x
    }

    private static func style(at offset: Int, in textView: NSTextView) throws -> NSParagraphStyle {
        try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
                      as? NSParagraphStyle)
    }

    private static let bullet = (note as NSString).range(of: "- ").location
    private static let prose = (note as NSString).range(of: "Prose").location

    func testAWideColumnHangsTheMarkersInTheGutter() throws {
        let (window, found) = host(width: 900)
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(found)
        let gutter = (Self.advance * MarkdownTextEditor.gutterAdvances).rounded()
        XCTAssertEqual(try Self.x(of: 0, in: textView), gutter - 3 * Self.advance, accuracy: 1)
        XCTAssertEqual(try Self.x(of: 3, in: textView), gutter, accuracy: 1)
        XCTAssertEqual(try Self.x(of: Self.prose, in: textView), gutter, accuracy: 1)
    }

    func testANarrowColumnSetsTheMarkersInline() throws {
        let (window, found) = host(width: 420)
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(found)
        XCTAssertEqual(try Self.x(of: 0, in: textView), 0, accuracy: 0.5)
        XCTAssertEqual(try Self.x(of: Self.prose, in: textView), 0, accuracy: 0.5)
        XCTAssertEqual(try Self.x(of: Self.bullet, in: textView), 0, accuracy: 0.5)
        // The bullet's wraps still hang under its words, not under the dash.
        XCTAssertEqual(try Self.style(at: Self.bullet, in: textView).headIndent, 2 * Self.advance, accuracy: 0.5)
    }

    func testNarrowingAWideEditorGivesTheGutterBack() throws {
        let (window, found) = host(width: 900)
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(found)
        XCTAssertGreaterThan(try Self.x(of: Self.prose, in: textView), 20)
        window.setContentSize(NSSize(width: 420, height: 300))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try Self.x(of: Self.prose, in: textView), 0, accuracy: 0.5)
    }
}
