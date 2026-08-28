import AppKit
import SwiftUI

/// PM's Settings window (⌘,).
///
/// An `NSTabViewController` in `.toolbar` style is the real macOS preferences window: toolbar icons
/// across the top, the window title following the selected tab, and the frame resizing to each pane's
/// content as you move between them. Each pane is SwiftUI in a hosting controller.
///
/// Settings used to be three checkboxes in a menubar submenu, which is where a menubar-only app has to
/// put them. A regular app gets to have the real thing.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        tabs.addTabViewItem(Self.tab(GeneralSettingsView(), title: "General",
                                     symbol: "gearshape", identifier: "general"))
        tabs.addTabViewItem(Self.tab(WindowsSettingsView(), title: "Windows",
                                     symbol: "macwindow", identifier: "windows"))
        tabs.addTabViewItem(Self.tab(ProjectsSettingsView(), title: "Projects",
                                     symbol: "folder", identifier: "projects"))
        tabs.addTabViewItem(Self.tab(NotesSettingsView(), title: "Notes",
                                     symbol: "note.text", identifier: "notes"))
        tabs.addTabViewItem(Self.tab(ShortcutsSettingsView(), title: "Shortcuts",
                                     symbol: "keyboard", identifier: "shortcuts"))
        tabs.addTabViewItem(Self.tab(NotificationSettingsView(), title: "Notifications",
                                     symbol: "bell", identifier: "notifications"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.setFrameAutosaveName("PMSettings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The panes, named so a command can ask for one by name rather than by index — an index would
    /// silently point at the wrong pane the next time the order changes.
    enum Pane: String {
        case general, windows, projects, notes, shortcuts, notifications
    }

    func show(selecting pane: Pane? = nil) {
        // Settings belong to the app, not a document, so they open centered on first use and remember
        // where they were put after that.
        if window?.frameAutosaveName.isEmpty ?? true { window?.center() }
        if let pane, let tabs = contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func tab<Content: View>(_ view: Content, title: String, symbol: String,
                                           identifier: String) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view.frame(width: 460))
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.identifier = identifier
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}
