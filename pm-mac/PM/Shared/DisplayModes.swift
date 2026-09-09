import SwiftUI

/// The app's appearance override — window-independent `@AppStorage`, read from the menu, the focus
/// panel, the quick bar and Settings.
///
/// It lived in the task column's file while that file was the project window, and outlived it.
///
/// **`TasksMode` used to sit beside it and does not any more.** It was moved out of the column's file
/// on the grounds that it "was never about the column" — a filter over any list of tasks. That was
/// wrong in the only way that mattered: the column was its one reader, so when the column went (§7f)
/// the enum was left being written to defaults by two menu items and read by nobody, which is how View
/// ▸ Incomplete/All went on ticking a checkmark and changing nothing while holding ⌘1 and ⌘2.

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
