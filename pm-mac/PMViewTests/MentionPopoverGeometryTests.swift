import XCTest
import AppKit

/// Where the completion list actually appears.
///
/// `isVisible` is true the moment `orderFront` runs, *wherever the frame happens to be* — so a panel
/// positioned off-screen passed every visibility check while being invisible to the person using it.
/// `firstRect(forCharacterRange:)` returns **screen** coordinates, and converting them a second time
/// as window coordinates is what put it there.
@MainActor
final class MentionPopoverGeometryTests: XCTestCase {

    func testTheListAppearsAgainstTheCaretAndOnAScreen() throws {
        let field = try XCTUnwrap(TaskField(), "no field editor")
        field.type("@ven")

        let panel = try XCTUnwrap(field.coordinator.completions.popover.frame,
                                  "the list has no frame to check")
        let anchor = try XCTUnwrap((field.field.currentEditor() as? NSTextView)?
            .firstRect(forCharacterRange: NSRange(location: 0, length: 4), actualRange: nil))

        XCTAssertTrue(NSScreen.screens.map(\.visibleFrame).contains { $0.intersects(panel) },
                      "the list is off every screen: \(panel)")
        XCTAssertTrue(adjacent(panel, to: anchor), "panel \(panel) is not against \(anchor)")
        // Negative control: the same test against a deliberately wrong rect must fail, or a check that
        // passes on an empty bitmap passes on everything.
        XCTAssertFalse(adjacent(panel, to: anchor.offsetBy(dx: 5000, dy: 5000)))
    }

    /// Either side of the caret line: below by default, flipped above when there's no room below —
    /// which is the case a window near the bottom of the screen actually hits.
    private func adjacent(_ panel: NSRect, to caret: NSRect) -> Bool {
        abs(panel.minX - caret.minX) < 40
            && (abs(panel.maxY - caret.minY) < 40 || abs(panel.minY - caret.maxY) < 40)
    }
}
