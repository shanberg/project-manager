import AppKit

/// Geometry constants shared by the project window, the focus panel, and the SwiftUI content of both.
/// These used to be statics on the panel controller, back when there was exactly one window and it was
/// a panel.
enum ProjectWindow {
    /// The narrowest the task column goes. The layout is drawn for a column about this wide.
    static let minContentWidth: CGFloat = 420

    /// The widest *prose* goes: the session-note editor, and anything else that is paragraphs to be
    /// read rather than rows to be scanned. Past this, extra window width becomes margin — a line of
    /// text much longer than this is measurably harder to read, which is the whole reason for a cap.
    static let maxContentWidth: CGFloat = 700

    /// The widest a project window's *content* gets — sidebar and task column together. This is the
    /// app's answer to "how big should this window be allowed to be", and it's deliberately answered
    /// on the window rather than inside it.
    ///
    /// Capping the column inside an unbounded window is the arrangement that doesn't work: past the
    /// cap the rows stop tracking the window's right edge and the extra width becomes a stranded band
    /// of nothing, which is neither a wider list nor a narrower window. Capping the window means the
    /// content always fills what's there, and "don't stretch a task list across a 6K display" is
    /// enforced once, in the one place a user can actually see it — the resize handle stops.
    ///
    /// With the sidebar showing this leaves the column a little under 900pt; hidden, it gets the
    /// sidebar's share too. Both are comfortable widths for a list of short lines with a due chip
    /// pinned right.
    static let maxWindowContentWidth: CGFloat = 1120

    /// The widest the task column goes. Equal to the window's cap by construction — that *is* the
    /// widest column a capped window can produce, with the sidebar hidden — so in a normal window this
    /// never bites and the rows track the right edge at every size. It stands as the backstop for a
    /// window that somehow escapes the cap.
    static let maxListWidth: CGFloat = maxWindowContentWidth

    /// The sidebar's default width, and the range the divider can be dragged through.
    static let sidebarWidth: CGFloat = 224
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 360

    /// `UserDefaults` key behind the sidebar toggle (an `@AppStorage` in the view, read directly by the
    /// window when it needs the value before any SwiftUI layout has run).
    static let sidebarDefaultsKey = "PMPanelSidebar"
    /// Defaults to showing, the way every Mac source-list app opens — `bool(forKey:)` would read a key
    /// nobody has written yet as "hidden", so a first run would open with no projects list at all.
    static var isSidebarVisible: Bool {
        UserDefaults.standard.object(forKey: sidebarDefaultsKey) as? Bool ?? true
    }

    /// Starting guess for how far in a window's close/minimise/zoom buttons reach.
    ///
    /// Both panes run their content under the (hidden, transparent) titlebar so the window has no dead
    /// strip along its top — which means whichever pane is leftmost has to keep its own header clear of
    /// the traffic lights. AppKit publishes no metric for this, so each window measures its own buttons
    /// once it's on screen and publishes the result (`ProjectViewState.leadingTitlebarInset`); this is
    /// only what the first layout uses, before there's a window to measure. Sized for the unified
    /// titlebar these windows use, where the buttons sit further in than in a compact one.
    static let trafficLightsWidth: CGFloat = 92

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
