import SwiftUI

/// The two display modes the app remembers for you, both of them window-independent `@AppStorage`
/// values read from the menu, the focus panel, the quick bar and Settings.
///
/// They lived in the task column's file while that file was the project window. Neither was ever
/// about the column — one is a filter over any list of tasks, the other is the app's appearance — so
/// they outlived it.

/// How the project window's tasks area presents itself. Raw values persist via `@AppStorage`.
///
/// A `focused` case used to sit alongside these, collapsing the window to a single task. That view is
/// the focus panel now — a separate always-on-top window — so this is back to being what it reads as: a
/// filter over the list. A stored `"focused"` no longer decodes, and `@AppStorage` falls back to the
/// default, which is the right landing place for anyone upgrading mid-mode.
enum TasksMode: String {
    case incomplete, all
}

/// The app color-scheme override. Raw values persist via `@AppStorage`; `.system` maps to `nil`
/// so SwiftUI falls back to the OS appearance.
enum AppColorMode: String {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
