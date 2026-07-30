import Foundation
import Combine

/// Window-behavior settings the app owns, backed by `UserDefaults`.
///
/// These deliberately do *not* live in `panel-settings.json` alongside `pinned` / `floating`. That file
/// is a contract with the Raycast extension, whose writer rewrites it with exactly those two keys — so
/// anything else stored there would be silently dropped the next time Raycast toggled a setting.
@MainActor
final class WindowSettings: ObservableObject {
    static let shared = WindowSettings()

    /// Show project windows on every Space, so they follow you between desktops and full-screen apps.
    /// (macOS has no "show on every display": a window lives on one screen. This is the setting that
    /// makes a window available wherever you are.)
    @Published var showOnAllSpaces: Bool {
        didSet { defaults.set(showOnAllSpaces, forKey: Keys.allSpaces) }
    }

    /// Keep project windows above other apps' windows.
    @Published var floatAboveOthers: Bool {
        didSet { defaults.set(floatAboveOthers, forKey: Keys.floating) }
    }

    /// Standard window chrome, or the original floating panel.
    @Published var chromeStyle: WindowChromeStyle {
        didSet { defaults.set(chromeStyle.rawValue, forKey: Keys.chromeStyle) }
    }

    /// Reopen the projects that were open when the app last quit.
    @Published var restoreWindows: Bool {
        didSet { defaults.set(restoreWindows, forKey: Keys.restoreWindows) }
    }

    /// The projects that had a window open when the app last quit, in the order they were opened.
    var openProjectKeys: [String] {
        get { defaults.stringArray(forKey: Keys.openProjects) ?? [] }
        set { defaults.set(newValue, forKey: Keys.openProjects) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let allSpaces = "PMWindowAllSpaces"
        static let floating = "PMWindowFloating"
        static let chromeStyle = "PMWindowChromeStyle"
        static let restoreWindows = "PMWindowRestore"
        static let openProjects = "PMWindowOpenProjects"
    }

    private init() {
        showOnAllSpaces = defaults.bool(forKey: Keys.allSpaces)
        floatAboveOthers = defaults.bool(forKey: Keys.floating)
        chromeStyle = defaults.string(forKey: Keys.chromeStyle)
            .flatMap(WindowChromeStyle.init(rawValue:)) ?? .window
        // Default on: reopening what you had is the Mac norm, and there's no first-run state to lose.
        restoreWindows = defaults.object(forKey: Keys.restoreWindows) as? Bool ?? true
    }
}
