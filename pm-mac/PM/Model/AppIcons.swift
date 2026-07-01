import AppKit

/// Resolves real application icons (Finder, Obsidian) for use in the menu and panel, so "Open in
/// Finder / Obsidian" actions carry their app's icon instead of a generic SF Symbol. Results are
/// cached per size for the app's lifetime; a missing app simply returns nil and callers fall back to
/// an SF Symbol.
enum AppIcons {
    enum App: String { case finder, obsidian, raycast }

    static func menuIcon(_ app: App) -> NSImage? { icon(app, side: 16) }
    static func panelImage(_ app: App) -> NSImage? { icon(app, side: 15) }

    private static var cache: [String: NSImage] = [:]

    private static func icon(_ app: App, side: CGFloat) -> NSImage? {
        let key = "\(app.rawValue)-\(Int(side))"
        if let hit = cache[key] { return hit }
        guard let base = base(app), let copy = base.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side)
        cache[key] = copy
        return copy
    }

    private static func base(_ app: App) -> NSImage? {
        switch app {
        case .finder:
            return NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .obsidian:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .raycast:
            // Resolve via the raycast:// scheme handler so it finds whichever Raycast (stable or the
            // Raycast 2 beta) is registered, rather than a hardcoded bundle id.
            guard let scheme = URL(string: "raycast://"),
                  let url = NSWorkspace.shared.urlForApplication(toOpen: scheme) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
