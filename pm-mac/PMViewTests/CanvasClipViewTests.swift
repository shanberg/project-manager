import AppKit
import XCTest

/// A drag held at the edge of a tiled board doesn't scroll it (`CanvasClipView`), nor does a press
/// carried past it. Calls AppKit's own drag-scroll step with a stand-in drag at the clip's top edge, and
/// its autoscroll with a mouse-dragged event above it.
@MainActor
final class CanvasClipViewTests: XCTestCase {
    private func scrolled(holdingStill: Bool) -> (before: NSPoint, after: NSPoint) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        let clip = CanvasClipView()
        clip.holdsStill = { holdingStill }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.contentView = clip
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
        window.contentView!.addSubview(scroll)
        clip.scroll(to: NSPoint(x: 500, y: 500))
        let before = clip.bounds.origin
        let drag = StandInDrag(at: NSPoint(x: 200, y: 298), in: window)
        for _ in 0..<5 { _ = clip.autoscroll(forDragging: drag, timeDelta: 0.1) }
        return (before, clip.bounds.origin)
    }

    /// A press inside the board carried out past its top edge — what a view in a tile does when a
    /// selection or a click's wobble leaves it — asks the clip to follow (`NSView.autoscroll(with:)`).
    private func pressScrolled(holdingStill: Bool) -> (before: NSPoint, after: NSPoint) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let clip = CanvasClipView()
        clip.holdsStill = { holdingStill }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.contentView = clip
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
        let tile = NSView(frame: NSRect(x: 500, y: 500, width: 300, height: 200))
        board.addSubview(tile)
        scroll.documentView = board
        window.contentView!.addSubview(scroll)
        clip.scroll(to: NSPoint(x: 500, y: 500))
        let before = clip.bounds.origin
        for _ in 0..<5 {
            let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 200, y: 340),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            _ = tile.autoscroll(with: event)
        }
        return (before, clip.bounds.origin)
    }

    func testATiledBoardHoldsStillUnderAPressCarriedPastItsEdge() {
        let moved = pressScrolled(holdingStill: true)
        XCTAssertEqual(moved.after, moved.before)
    }

    /// The control: off the tiles, the same press scrolls — so the event reaches AppKit's real step.
    func testAnUntiledBoardStillScrollsUnderAPressCarriedPastItsEdge() {
        let moved = pressScrolled(holdingStill: false)
        XCTAssertNotEqual(moved.after, moved.before)
    }

    func testATiledBoardHoldsStillUnderADragAtItsEdge() {
        let moved = scrolled(holdingStill: true)
        XCTAssertEqual(moved.after, moved.before)
    }

    /// The control: off the tiles, the same drag scrolls — so the stand-in reaches AppKit's real step.
    func testAnUntiledBoardStillScrollsUnderADragAtItsEdge() {
        let moved = scrolled(holdingStill: false)
        XCTAssertNotEqual(moved.after, moved.before)
    }
}

/// Just enough of a drag for AppKit's autoscroll; private questions it asks are answered with zero.
private final class StandInDrag: NSObject, NSDraggingInfo {
    let location: NSPoint
    weak var window: NSWindow?
    init(at location: NSPoint, in window: NSWindow) { self.location = location; self.window = window }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { .general }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    @objc var isTouchDragging: Bool { false }

    override class func resolveInstanceMethod(_ selector: Selector!) -> Bool {
        let zero: @convention(block) (AnyObject) -> Int = { _ in 0 }
        return class_addMethod(self, selector, imp_implementationWithBlock(zero), "q@:")
    }
}
