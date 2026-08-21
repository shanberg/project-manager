import AppKit

/// Resolves real application icons (Finder, Obsidian) for use in menus and task views, so "Open in
/// Finder / Obsidian" actions carry their app's icon instead of a generic SF Symbol. Results are
/// cached per size for the app's lifetime; a missing app simply returns nil and callers fall back to
/// an SF Symbol.
enum AppIcons {
    enum App: String { case finder, obsidian }

    static func menuIcon(_ app: App) -> NSImage? { icon(app, side: 16) }
    static func smallImage(_ app: App) -> NSImage? { icon(app, side: 15) }

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
        }
    }
}
