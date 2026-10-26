import XCTest
import AppKit
import SwiftUI

/// `TokenText`, the SwiftUI task line, measured against the AppKit label it replaced.
///
/// A click can't be delivered to SwiftUI here (see `CanvasLinkZones`), so the click targets are
/// checked by where they land: the zones the click layer would build, read off the same layout.
@MainActor
final class TokenTextTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ProjectCodes.defaultsKey)
        super.tearDown()
    }

    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    }

    private func width(_ string: String) -> CGFloat {
        NSHostingView(rootView: TokenText(attributed: attributed(string)).fixedSize()).fittingSize.width
    }

    /// The brackets are kerned to the pill's padding, as `TokenLayoutManager` makes them — not
    /// drawn, and not dropped.
    func testTheBracketsAddThePaddingAndNoMore() {
        XCTAssertEqual(width("[[Vendor]]") - width("Vendor"), TokenLayoutManager.padding, accuracy: 1)
    }

    /// The same width as `TokenLabelView`, so a row wraps where it always did.
    func testItIsAsWideAsTheAppKitLabel() {
        TestApp.start()
        for string in ["Ask [[W-2 Vendor Contract]] about it", "[[Leading]] token", "No tokens here"] {
            let label = TokenLabelView()
            label.attributed = attributed(string)
            XCTAssertEqual(width(string), label.size(fitting: TokenLabelView.unbounded).width, accuracy: 1,
                           string)
        }
    }

    /// One zone per line a pill sits on, named by the token as written — code and all, even when the
    /// pill leaves the code out.
    func testEachPillGetsAZoneNamedByItsToken() throws {
        UserDefaults.standard.set(true, forKey: ProjectCodes.defaultsKey)
        let shown = zones("Ask [[W-2 Vendor Contract]] and then [[A Very Long Project Name That Wraps Over]] ok")
        UserDefaults.standard.set(false, forKey: ProjectCodes.defaultsKey)
        let hidden = zones("Ask [[W-2 Vendor Contract]] and then [[A Very Long Project Name That Wraps Over]] ok")
        for zones in [shown, hidden] {
            XCTAssertEqual(zones.filter { $0.name == "W-2 Vendor Contract" }.count, 1)
            XCTAssertGreaterThanOrEqual(zones.filter { $0.name == "A Very Long Project Name That Wraps Over" }.count, 2)
        }
        let withCode = try XCTUnwrap(shown.first { $0.name == "W-2 Vendor Contract" }).rect.width
        let withoutCode = try XCTUnwrap(hidden.first { $0.name == "W-2 Vendor Contract" }).rect.width
        XCTAssertLessThan(withoutCode, withCode - 10, "the pill leaves the code out")
    }

    private static var seen: [TokenClicks.Zone] = []

    private func zones(_ string: String) -> [TokenClicks.Zone] {
        TestApp.start()
        Self.seen = []
        let root = TokenText(attributed: attributed(string))
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear.onAppear { TokenTextTests.seen = TokenClicks.zones(in: layouts, proxy: proxy) }
                }
            }
            .frame(width: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let until = Date().addingTimeInterval(1)
        while Self.seen.isEmpty, Date() < until { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        return Self.seen
    }
}
