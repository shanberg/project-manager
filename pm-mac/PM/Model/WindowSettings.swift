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

    /// Show the focus panel on every Space, so it follows you between desktops and full-screen apps.
    ///
    /// (macOS has no "show on every display": a window lives on one screen. Joining all Spaces — plus
    /// `.fullScreenAuxiliary`, which is what gets it over a full-screen app — is what makes it available
    /// wherever you are, which is what the setting is for.)
    @Published var showOnAllSpaces: Bool {
        didSet { defaults.set(showOnAllSpaces, forKey: Keys.allSpaces) }
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
        static let restoreWindows = "PMWindowRestore"
        static let openProjects = "PMWindowOpenProjects"
    }

    private init() {
        // Default on: a HUD meant to stay with you while you work is no use if it's stranded on
        // the desktop you happened to summon it from.
        showOnAllSpaces = defaults.object(forKey: Keys.allSpaces) as? Bool ?? true
        // Default on: reopening what you had is the Mac norm, and there's no first-run state to lose.
        restoreWindows = defaults.object(forKey: Keys.restoreWindows) as? Bool ?? true
    }
}
