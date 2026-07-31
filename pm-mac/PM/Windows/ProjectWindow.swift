import AppKit

/// Geometry constants shared by the project window, the focus panel, and the SwiftUI content of both.
/// These used to be statics on the panel controller, back when there was exactly one window and it was
/// a panel.
enum ProjectWindow {
    /// The narrowest the task column goes. The layout is drawn for a column about this wide.
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

    /// How far in from a window's leading edge the close/minimise/zoom buttons reach, plus clearance.
    ///
    /// Both panes run their content under the (hidden, transparent) titlebar so the window has no dead
    /// strip along its top — which means whichever pane is leftmost has to keep its own header clear of
    /// the traffic lights by hand. AppKit publishes no metric for this; the buttons sit at x = 20 / 40 /
    /// 60 with a ~14pt diameter, so the third one ends around 74.
    static let trafficLightsWidth: CGFloat = 78

    /// Smallest window the content stays usable in.
    static let minWindowHeight: CGFloat = 320

    /// The focus panel's fixed width. Narrower than the task column's floor on purpose: it holds one
    /// task, a breadcrumb and a "next" line, and at the project window's width those would read as a
    /// mostly-empty row rather than a card.
    static let focusPanelWidth: CGFloat = 380

    /// The focus panel's rounded-corner radius. A borderless window has nothing to round it, so the
    /// glass background and the SwiftUI content each clip to this and the shadow follows their shape.
    static let cornerRadius: CGFloat = 16

    /// Max height as a Tarot-card proportion of the focus panel's width (~2.75×4.75), for its auto-fit.
    /// Content beyond this scrolls inside the card; below it, the panel fits exactly.
    static let maxHeightRatio: CGFloat = 4.75 / 2.75

    /// Groups this app's windows for `NSWindow` tabbing, so ⌘T and the tab bar's `+` work.
    static let tabbingIdentifier = "PMProject"

    /// Marks a window as one of ours, for the few places that need to tell a project window from a
    /// settings window or a system panel.
    static let windowIdentifier = "PMProjectWindow"
}
