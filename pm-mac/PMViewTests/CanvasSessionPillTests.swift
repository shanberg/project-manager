import XCTest
import AppKit
import SwiftUI

/// What the address bar's session pill does to the row it sits in.
///
/// The pill is the one thing in that capsule whose width comes from a name somebody typed, and the
/// capsule is a fixed box holding an address that is already being truncated. So the questions worth
/// asking are all about size: does a pill stay the size of its word, does a long name get cut before
/// it eats the address, and does either of them change once there is a flexible address beside it.
///
/// Drawn rather than reasoned about, because "greedy" is a property of SwiftUI's layout rather than of
/// the code, and the frame a real `NSHostingView` settles on is the only honest answer. The row here is
/// a model of the address capsule's — `CanvasAddressField` reaches for half the app to compile — but
/// the pill in it is the real one, which is where the question lives.
@MainActor
final class CanvasSessionPillTests: XCTestCase {

    /// A pill is the size of its word, near enough to read as a label rather than a field.
    func testAPillIsTheSizeOfItsName() {
        let private_ = size(of: CanvasSessionPill(name: "Private", isPrivate: true))
        XCTAssertEqual(private_.height, 14, accuracy: 3, "taller than a caption in a 21pt row")
        XCTAssertGreaterThan(private_.width, 30)
        XCTAssertLessThan(private_.width, 70)

        // Shorter word, visibly narrower pill: the width is the name's and nothing else's.
        let work = size(of: CanvasSessionPill(name: "Work", isPrivate: false))
        XCTAssertLessThan(work.width, private_.width - 8)
    }

    /// **A name nobody sensible typed is cut, not honoured.** The address is what the bar is for, and a
    /// profile called something enormous must not take it.
    func testALongNameIsCutRatherThanTakingTheRow() {
        let long = "Client staging tenant number four"
        XCTAssertEqual(CanvasSessionPill.shown(long).count, CanvasSessionPill.longestName)
        XCTAssertTrue(CanvasSessionPill.shown(long).hasSuffix("\u{2026}"))
        XCTAssertEqual(CanvasSessionPill.shown("Work"), "Work", "a name that fits is left alone")

        let cut = size(of: CanvasSessionPill(name: long, isPrivate: false))
        XCTAssertLessThan(cut.width, 100, "a cut name still fits beside an address")
    }

    /// **The pill does not grow into the room the row has spare, and does not give any up either.**
    ///
    /// This is why the cap is a cut string rather than `frame(maxWidth:)`: in a row like the address
    /// capsule's — a fixed width, a flexible address beside it — a maximum is something SwiftUI will
    /// happily fill, and the pill would arrive sized for a name nobody typed. Measured through a marker
    /// view, which is the only handle a test has on where SwiftUI put something.
    func testThePillKeepsItsWidthBesideAFlexibleAddress() throws {
        let alone = size(of: CanvasSessionPill(name: "Work", isPrivate: false))

        for address in ["example.com", "wiki.example.com/spaces/ENG/pages/8814593/A-very-long-title"] {
            let width = try widthInRow(address: address)
            XCTAssertEqual(width, alone.width, accuracy: 1,
                           "the pill changed width when the address beside it did (\(address))")
        }
    }

    // MARK: Drawing one

    /// A pill on its own, at the size it asks to be.
    private func size(of pill: CanvasSessionPill) -> NSSize {
        NSHostingView(rootView: pill).fittingSize
    }

    /// The pill in a model of the address capsule: a fixed box, the pill at the head of it, and an
    /// address that will take whatever is left.
    private func widthInRow(address: String) throws -> CGFloat {
        let row = HStack(spacing: 4) {
            CanvasSessionPill(name: "Work", isPrivate: false)
                .background(Marker())
            Text(address)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 6)
        .padding(.trailing, 22)
        .frame(width: 260, height: 21)

        let hosting = NSHostingView(rootView: row)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 21)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Quiet, and never the key window: this is a harness, not something to look at.
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let marker = try XCTUnwrap(markers(in: hosting).first, "the pill drew no marker")
        return marker.bounds.width
    }

    private func markers(in view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            (subview is Marker.MarkerView ? [subview] : []) + markers(in: subview)
        }
    }

    /// A real view behind the pill, the way every `HeaderCapsule` carries a `WindowDragExcluder` —
    /// see `HeaderChromeMotionTests`, which measures the header the same way.
    private struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { MarkerView() }
        func updateNSView(_ view: NSView, context: Context) {}
        final class MarkerView: NSView {}
    }
}
