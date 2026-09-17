import AppKit
import Foundation
import PmLib

// MARK: - The tier only a running app can serve
//
// Split out of `PMContract` rather than sitting beside it, because the split is the contract's own:
// mutations and queries are pure domain and mean the same thing headless, while an affordance is a
// *request to a running app* — open a window, reveal a folder — which `pm api` and `pm mcp` list and
// refuse. The two tiers have different dependencies as well as different meanings. Everything above
// needs PmLib and nothing else; this needs four window controllers, and keeping them in the same file
// meant the adapter could not be compiled without the whole app around it — which is why `PMStore`,
// the code that writes your notes, had no tests.

extension PMContract {
    // MARK: Affordances
    //
    // The tier the headless adapters can't serve. Same names as the manifest publishes, so the
    // vocabulary is one vocabulary even where only this adapter can act on it.

    /// Takes a `PMAction` like the dispatcher does, so the two tiers are addressed in one vocabulary
    /// and neither can be misspelled. An action from the other tiers answers false rather than being
    /// unrepresentable: the switch is over every case the contract publishes, and a mutation arriving
    /// here is a routing mistake to report, not a state to make impossible.
    @MainActor
    @discardableResult
    static func performAffordance(_ action: PMAction, store: PMStore? = nil) -> Bool {
        switch action {
        case .appOpenWindow:
            WindowManager.shared.openFocusedProject()
        case .appOpenInFinder:
            guard let path = store?.projectPath else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .appOpenInObsidian:
            guard let store else { return false }
            ObsidianLink.open(store: store)
        case .appShowPanel:
            FocusPanelController.shared.toggle()
        case .appSettings:
            SettingsWindowController.shared.show()
        case .appOpenPageAsNewCard:
            // The front project window's board: the one a person means when they ask from Raycast with a
            // page up in front of them. Nothing to act on — no window, no page — is false, not a guess.
            let front = NSApp.orderedWindows.lazy
                .compactMap { $0.windowController as? ProjectWindowController }.first
            return front?.canvasPane?.openPageAsNewCard() ?? false
        default:
            return false
        }
        return true
    }
}
