import Foundation
import PmLib

/// Whether PM writes project names with their `CODE-NNN ` prefix, and the two helpers that answer it.
///
/// One preference for the whole app rather than one per surface. A code is a fact about how you name
/// projects, not about a list: a sidebar that leaves the code off while the menu bar spells it out is
/// the app disagreeing with itself about what a project is called. So every place PM writes a project
/// name in its own chrome — sidebar, menu bar, quick bar, focus panel, window titles, notifications —
/// asks here.
///
/// What it deliberately doesn't touch: text that came out of a file, and tooltips. A `[[W-012 Website
/// Refresh]]` in a note is drawn as it's written, because an editor showing different text from the
/// file would be lying about the file; and a tooltip is where you go to find out exactly which folder
/// a row stands for, so it keeps the full name however names are written elsewhere.
enum ProjectCodes {
    /// The `UserDefaults` key. Bound as `@AppStorage` in views — which is what makes them re-render
    /// when it's toggled — and read straight from defaults by the controllers that compose text
    /// outside any view.
    static let defaultsKey = "PMShowProjectCode"

    /// The key this lived under while it was the sidebar's own preference.
    private static let legacyKey = "PMSidebarShowCode"

    /// Carry a value set under the old key across, once, at launch. Only when the new key is unset —
    /// a value written since the move is the current answer and the stale one mustn't overwrite it.
    static func migrateLegacyKey(in defaults: UserDefaults = .standard) {
        defer { defaults.removeObject(forKey: legacyKey) }
        guard defaults.object(forKey: defaultsKey) == nil,
              let legacy = defaults.object(forKey: legacyKey) as? Bool else { return }
        defaults.set(legacy, forKey: defaultsKey)
    }

    /// Whether names are written with their code. On unless it's been turned off — the codes are how
    /// the folders are actually named, so showing them is the honest default.
    ///
    /// Every switch in the app writes through here rather than straight to defaults, so that the two
    /// kinds of reader both hear about it: SwiftUI's `@AppStorage` observes the key itself, and the
    /// AppKit surfaces that compose text by hand observe `didChange`.
    static var areShown: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Posted when the preference is toggled, for the views that aren't SwiftUI's to invalidate.
    static let didChange = Notification.Name("PMProjectCodesDidChange")

    /// A folder name without its `CODE-NNN ` prefix. A name that doesn't carry one — an area's, say —
    /// comes back whole.
    ///
    /// PmLib's parser rather than a hand-rolled scan for the first hyphen: the prefix is a grammar
    /// (`^[A-Za-z]+-\d+\s+`), and "first hyphen wins" turns the area `Team - 1:1s` into `1:1s`. This
    /// is the same answer `ProjectIndex` records as a project's `shortName` while it scans, which is
    /// what lets the two be used interchangeably.
    static func shortName(of name: String) -> String {
        let short = projectTitle(fromFolderName: name)
        return short.isEmpty ? name : short
    }

    /// A project's folder name as this app has been told to write it.
    ///
    /// `short` is passed when the caller already has the name parsed — the project index splits the
    /// prefix off as it scans, and its answer is the authoritative one. `showing` is passed by views
    /// that hold the preference as `@AppStorage`, so the string they build is the one their own
    /// invalidation was scheduled for; everyone else takes the default and reads defaults here.
    static func display(_ full: String, short: String? = nil,
                        showing: Bool = ProjectCodes.areShown) -> String {
        showing ? full : (short ?? shortName(of: full))
    }
}
