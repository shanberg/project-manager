import XCTest
import AppKit
import SwiftUI

/// The header's `…` hands an AppKit menu the view to open against, on the press itself — see
/// `HeaderMenuButton`, which is how the focus capsule's menu became the card's own contextual menu.
@MainActor
final class HeaderMenuButtonTests: XCTestCase {
    /// A press lands on a control — the kind of view that carves the titlebar's drag band — and opens
    /// against that control, on mouse-down rather than waiting for the release, as a pull-down does.
    func testAPressOpensAgainstTheControlOnMouseDown() throws {
        TestApp.start()
        var opened: [NSView] = []
        let hosting = NSHostingView(rootView: HeaderMenuButton(symbol: "ellipsis", help: "Actions") {
            opened.append($0)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let control = try XCTUnwrap(controls(in: hosting).first)
        XCTAssertGreaterThan(control.bounds.width, 10)
        XCTAssertEqual(control.accessibilityRole(), .menuButton)
        XCTAssertEqual(control.accessibilityLabel(), "Actions")

        let centre = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: centre, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(hosting.hitTest(hosting.superview?.convert(centre, from: nil) ?? centre) === control)
        control.mouseDown(with: down)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === control)
    }

    /// ⌃Return opens the same menu against the same button: a changed token opens it once, and the
    /// token the button first appears with opens nothing.
    func testAChangedTokenOpensAgainstTheButton() throws {
        TestApp.start()
        final class Token: ObservableObject { @Published var value = 7 }
        struct Host: View {
            @ObservedObject var token: Token
            let open: (NSView) -> Void
            var body: some View {
                HeaderMenuButton(symbol: "ellipsis", help: "Actions", openToken: token.value, open: open)
            }
        }
        var opened: [NSView] = []
        let token = Token()
        let hosting = NSHostingView(rootView: Host(token: token) { opened.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(opened.isEmpty, "appearing opened the menu")

        token.value += 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === controls(in: hosting).first)
    }

    private func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { ($0 as? NSControl).map { [$0] } ?? controls(in: $0) }
    }
}
