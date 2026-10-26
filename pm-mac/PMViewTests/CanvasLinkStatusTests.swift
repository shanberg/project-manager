import AppKit
import XCTest

/// What the hover line says. The hover itself comes from the real pointer and can't be posted —
/// see docs/web-cards.md, "Browser habits a card follows".
@MainActor
final class CanvasLinkStatusTests: XCTestCase {
    func testAWebLinkReadsWithoutItsScheme() {
        XCTAssertEqual(CanvasLinkStatus.text(for: URL(string: "https://example.com/a/b?c=1"), flags: []),
                       "example.com/a/b?c=1")
    }

    func testCommandSaysWhatCommandClickWillDo() {
        XCTAssertEqual(CanvasLinkStatus.text(for: URL(string: "http://example.com/"), flags: .command),
                       "Open as a new card: example.com/")
    }

    func testOtherSchemesKeepTheirScheme() {
        XCTAssertEqual(CanvasLinkStatus.text(for: URL(string: "mailto:a@example.com"), flags: []),
                       "mailto:a@example.com")
    }

    func testNothingForNoLinkOrScript() {
        XCTAssertNil(CanvasLinkStatus.text(for: nil, flags: []))
        XCTAssertNil(CanvasLinkStatus.text(for: URL(string: "javascript:void(0)"), flags: []))
    }

    func testTheLineTakesNoClicks() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let status = CanvasLinkStatus.install(in: container)
        status.show("example.com")
        container.layoutSubtreeIfNeeded()
        XCTAssertFalse(status.isHidden)
        XCTAssertTrue(container.hitTest(NSPoint(x: status.frame.midX, y: status.frame.midY)) === container)
        XCTAssertEqual(status.frame.minX, 4)
    }
}
