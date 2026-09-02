import AppKit
import SwiftUI

/// Clicking away from an open editor: who reports where the editor is, and what counts as away.
///
/// Lifted out of `TaskEditors` because it isn't an editor — it's the one rule shared by every surface
/// that opens one (both panes of a project window, the focus panel's card), and it's the piece with
/// geometry worth testing on its own.

/// The active inline editor reports its window-space frame so a mouse-down monitor can tell an
/// outside click (which cancels the editor) from a click within it. Only one editor is open at a
/// time, so the first non-nil frame wins.
struct ActiveEditorFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

extension View {
    /// Publish this editor's frame (SwiftUI global / window space) for the outside-click monitor.
    func reportEditorFrame() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ActiveEditorFrameKey.self, value: geo.frame(in: .global))
        })
    }
}

/// Watches for left mouse-downs in its own window while an editor is open and cancels the editor when
/// the click lands outside its reported frame (swallowing that click so it only dismisses).
///
/// Scoped to one window: the app can have several project windows open plus the focus panel, each with
/// its own editor, and a click in one of them must not dismiss another's.
final class OutsideClickMonitor: ObservableObject {
    var editorFrame: CGRect?
    var onOutsideClick: (() -> Void)?
    /// The window this monitor belongs to; clicks anywhere else are left alone.
    weak var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window === self.window
            else { return event }
            // SwiftUI's global space is top-left origin; AppKit's locationInWindow is bottom-left.
            guard let frame = self.editorFrame else { return event }
            let flipped = CGRect(x: frame.minX, y: window.frame.height - frame.maxY,
                                 width: frame.width, height: frame.height)
            if flipped.contains(event.locationInWindow) { return event }
            if Self.isWindowChrome(event.locationInWindow, in: window) { return event }
            self.onOutsideClick?()
            return nil   // consume: an outside click only dismisses, it doesn't also act
        }
    }

    /// Whether a point is on the window's own chrome — the strip you drag the window by, or the resize
    /// border — rather than on the UI behind the editor.
    ///
    /// Excluded explicitly, because the frame an editor reports is only ever its own *pane*. With the
    /// sidebar showing, the titlebar strip above it and the window's left edge both fall outside the
    /// content column, so grabbing the window at its top-left to move or resize it counted as an
    /// outside click: the editor closed and the mouse-down was swallowed, so the window didn't even
    /// move. Reaching for a window's chrome says nothing about what you want the editor to do.
    ///
    /// `contentLayoutRect` is what draws the line at the top: these windows run their content up under
    /// a transparent titlebar (`.fullSizeContentView`), so the content view's own bounds include the
    /// strip and can't tell you where it ends — but `contentLayoutRect` still excludes it. Where a pane
    /// *does* put controls up there, they're inside that pane's reported frame and were already
    /// answered above.
    private static func isWindowChrome(_ point: CGPoint, in window: NSWindow) -> Bool {
        if point.y >= window.contentLayoutRect.maxY { return true }
        let border: CGFloat = 4   // the resize edges, which live just inside the frame
        return point.x <= border || point.x >= window.frame.width - border || point.y <= border
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editorFrame = nil
    }
}
