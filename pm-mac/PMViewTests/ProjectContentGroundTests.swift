import XCTest
import AppKit

/// **The column has to paint, because for a moment it is all there is.**
///
/// Pointing a window at another project drops every pane the old one had and waits for the new
/// project's canvas path, which arrives with that store's first read of the folder. For those
/// milliseconds the content column holds an empty pane on purpose — see
/// `ProjectSplitViewController.makeBoardless`, which argues for waiting rather than putting something
/// on screen to take away again.
///
/// Nothing in that column was painting, and an unpainted region of a layer-backed hierarchy in an
/// opaque window is not the window's grey. Switching between two projects that were both showing a
/// board flashed black between them. So the column paints its own ground now, in the colour a board is
/// painted with — see `ProjectContentGround`.
///
/// Pinned here rather than argued about, because the failure is one pixel of one frame: a view that
/// draws nothing and a view that draws the right grey are indistinguishable in every other test, and
/// the difference is the whole bug.
@MainActor
final class ProjectContentGroundTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.orderFront(nil)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    /// What a view actually puts on screen in the middle of its own bounds, drawn into a bitmap that
    /// starts fully transparent — so a view that draws nothing answers with alpha zero rather than
    /// with whatever happens to be behind it.
    private func paintedCentre(of view: NSView) -> NSColor? {
        window.contentView = view
        view.frame = window.contentView!.bounds
        window.layoutIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.colorAt(x: Int(bounds.midX), y: Int(bounds.midY))
    }

    /// The board's grey, put through the same bitmap as the thing being tested.
    ///
    /// Compared rather than converted, because the two are not the same number in every space the
    /// drawing might land in: `bitmapImageRepForCachingDisplay` hands back a rep in the display's own
    /// profile and reports the pixels it read out of it as calibrated, so a sample converted to sRGB
    /// and a colour resolved in sRGB disagree by a tenth while being the same grey on screen. Drawing
    /// the reference the same way takes the whole question out.
    private func boardGround() -> NSColor? { paintedCentre(of: GroundReference()) }

    private final class GroundReference: NSView {
        override func draw(_ dirty: NSRect) {
            CanvasPalette.board.setFill()
            dirty.fill()
        }
    }

    private func assertIsBoardGround(_ colour: NSColor?, file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let colour else { return XCTFail("nothing was drawn at all", file: file, line: line) }
        guard let wanted = boardGround() else {
            return XCTFail("the reference drew nothing", file: file, line: line)
        }
        XCTAssertEqual(colour.alphaComponent, 1, accuracy: 0.01,
                       "the column left a hole rather than painting", file: file, line: line)
        XCTAssertEqual(colour.redComponent, wanted.redComponent, accuracy: 0.01,
                       "not the grey a board is painted with", file: file, line: line)
        XCTAssertEqual(colour.greenComponent, wanted.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(colour.blueComponent, wanted.blueComponent, accuracy: 0.01, file: file, line: line)
    }

    /// With no pane mounted at all — the instant after a retarget drops the old project's tabs.
    func testEmptyColumnPaintsTheBoardGround() {
        assertIsBoardGround(paintedCentre(of: ProjectContentPaneController().view))
    }

    /// And with the waiting pane up, which is what is actually on screen for the length of the switch.
    /// It draws nothing itself by design, so the ground behind it is the whole of what is seen.
    func testWaitingPaneShowsTheBoardGroundThroughIt() {
        let pane = ProjectContentPaneController()
        _ = pane.view
        pane.show(ProjectWaitingPaneController(), for: "canvas")
        assertIsBoardGround(paintedCentre(of: pane.view))
    }
}
