import AppKit
import XCTest

/// The overview's window pictures (docs/spaces.md § Overview).
@MainActor
final class WindowSnapshotTests: XCTestCase {
    /// The picture fills its bitmap at the window's density: drawn before its size was set, it filled
    /// only the bottom-left quarter on a Retina screen.
    func testThePictureFillsItsBitmap() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        let red = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        red.wantsLayer = true
        red.layer?.backgroundColor = NSColor.systemRed.cgColor
        window.contentView = red
        var got: NSImage?
        WindowSnapshot.take(window) { got = $0 }
        let image = try XCTUnwrap(got)
        XCTAssertEqual(image.size, NSSize(width: 400, height: 250))
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, Int(400 * window.backingScaleFactor))
        // Top-right corner: outside the quarter the bug drew into.
        let corner = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.redComponent, 0.8)
        XCTAssertLessThan(corner.greenComponent, 0.5)
    }
}
