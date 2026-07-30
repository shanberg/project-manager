import AppKit

/// Geometry and chrome constants shared by the project window, the panel-style chrome, and the SwiftUI
/// content. These used to be statics on `PanelController`, when there was exactly one window and it was
/// a panel.
enum ProjectWindow {
    /// The narrowest the task column goes. The layout is drawn for a column about this wide, and it's
    /// the panel's fixed width.
    static let minContentWidth: CGFloat = 420

    /// The widest the task column goes in a real window. Past this, extra window width becomes margin
    /// and the column centers, rather than stretching rows to the full width of a large display.
    static let maxContentWidth: CGFloat = 700

    /// The sidebar's default width, and the range the divider can be dragged through.
    static let sidebarWidth: CGFloat = 224
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 360

    /// `UserDefaults` key behind the sidebar toggle (an `@AppStorage` in the view, read directly by the
    /// window when it needs the value before any SwiftUI layout has run).
    static let sidebarDefaultsKey = "PMPanelSidebar"
    static var isSidebarVisible: Bool { UserDefaults.standard.bool(forKey: sidebarDefaultsKey) }

    /// Smallest window the content stays usable in.
    static let minWindowHeight: CGFloat = 320

    /// The panel style's rounded-corner radius. A borderless window has nothing to round it, so the
    /// glass background and the SwiftUI content each clip to this and the shadow follows their shape.
    static let cornerRadius: CGFloat = 16

    /// Max height as a Tarot-card proportion of the content column (~2.75×4.75), for the panel style's
    /// auto-fit. Content beyond this scrolls; below it, the panel fits exactly.
    static let maxHeightRatio: CGFloat = 4.75 / 2.75

    /// Groups this app's windows for `NSWindow` tabbing, so ⌘T and the tab bar's `+` work.
    static let tabbingIdentifier = "PMProject"

    /// Marks a window as one of ours, for the few places that need to tell a project window from a
    /// settings window or a system panel.
    static let windowIdentifier = "PMProjectWindow"
}

/// How a project window presents itself.
///
/// `.window` is a real Mac window: a titlebar (hidden, with the content running under it), standard
/// resize edges, and the window frame doing the clipping. `.panel` is the app's original chrome, kept
/// as a setting: borderless and glass-rounded, auto-fitting its height to its content, hiding when it
/// loses focus, and snapping to the screen edges.
enum WindowChromeStyle: String, CaseIterable {
    case window
    case panel

    var isPanel: Bool { self == .panel }
}
