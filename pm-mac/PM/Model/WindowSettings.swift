import Foundation
import Combine

/// Window-behavior settings the app owns, backed by `UserDefaults`.
///
/// These deliberately do *not* live in `panel-settings.json` alongside `pinned` / `floating`. That file
/// is a contract with the Raycast extension, whose writer rewrites it with exactly those two keys — so
/// anything else stored there would be silently dropped the next time Raycast toggled a setting.
@MainActor
@Observable
final class WindowSettings {
    static let shared = WindowSettings()

    /// Show the focus panel on every Space, so it follows you between desktops and full-screen apps.
    ///
    /// (macOS has no "show on every display": a window lives on one screen. Joining all Spaces — plus
    /// `.fullScreenAuxiliary`, which is what gets it over a full-screen app — is what makes it available
    /// wherever you are, which is what the setting is for.)
    var showOnAllSpaces: Bool {
        didSet { defaults.set(showOnAllSpaces, forKey: Keys.allSpaces) }
    }

    /// Reopen the projects that were open when the app last quit.
    var restoreWindows: Bool {
        didSet { defaults.set(restoreWindows, forKey: Keys.restoreWindows) }
    }

    /// One window open when the app last quit, as `WindowManager.restoreOnLaunch` brings it back.
    struct OpenWindow: Codable, Equatable {
        /// The project it showed; nil for a window on a canvas file, or on no project at all.
        var project: String?
        /// The canvas file it was opened on (`ProjectWindowController.openedCanvas`), as a path.
        var canvas: String?
        /// Where it was, as `NSWindow.frameDescriptor` — the windowed frame, for one in full screen.
        /// Empty where a window had no frame to give.
        var frame: String
        var minimized: Bool
        var fullScreen: Bool
        /// Its place in the stack: 0 the frontmost. Nil where it could not be told.
        var depth: Int?
    }

    /// The windows open when the app last quit, in the order they were opened.
    ///
    /// Read from the two lists this replaced — the projects, and their frames index for index — when it
    /// has never been written.
    var openWindows: [OpenWindow] {
        get {
            if let data = defaults.data(forKey: Keys.openWindows),
               let windows = try? JSONDecoder().decode([OpenWindow].self, from: data) { return windows }
            let keys = defaults.stringArray(forKey: Keys.openProjects) ?? []
            let frames = defaults.stringArray(forKey: Keys.openFrames) ?? []
            return keys.enumerated().map { index, key in
                OpenWindow(project: key, canvas: nil, frame: frames.indices.contains(index) ? frames[index] : "",
                           minimized: false, fullScreen: false, depth: nil)
            }
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.openWindows)
            defaults.removeObject(forKey: Keys.openProjects)
            defaults.removeObject(forKey: Keys.openFrames)
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let allSpaces = "PMWindowAllSpaces"
        static let restoreWindows = "PMWindowRestore"
        static let openProjects = "PMWindowOpenProjects"
        static let openFrames = "PMWindowOpenFrames"
        static let openWindows = "PMWindowOpenWindows"
    }

    private init() {
        // Default on: a HUD meant to stay with you while you work is no use if it's stranded on
        // the desktop you happened to summon it from.
        showOnAllSpaces = defaults.object(forKey: Keys.allSpaces) as? Bool ?? true
        // Default on: reopening what you had is the Mac norm, and there's no first-run state to lose.
        restoreWindows = defaults.object(forKey: Keys.restoreWindows) as? Bool ?? true
    }
}
