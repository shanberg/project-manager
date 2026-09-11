import AppKit
import SwiftUI

/// A backing AppKit view that opts its region out of a borderless window's
/// `isMovableByWindowBackground`, so a mouse-drag that begins on it starts a SwiftUI `.onDrag` (item
/// reorder) or registers a click, instead of being claimed by AppKit as a window move.
///
/// In a file of its own so the header's parts can compile into `PMViewTests` without the task editors
/// it used to live beside.
struct WindowDragExcluder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ExcluderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ExcluderView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
