import PmLib
import SwiftUI

/// One editor the focus panel should open on its focused task, asked for from outside the panel.
///
/// `id` is what makes a repeat land: asking for "Edit Task" twice in a row is two requests, and
/// without a distinguishing value the second would be equal to the first and the panel's `onChange`
/// would never see it.
struct FocusEditorRequest: Equatable {
    let kind: EditorTarget.Kind
    let position: TaskInsertPosition
    let id: Int
}

/// The channel the menu bar item uses to open one of the focus panel's editors.
///
/// The panel's editors are `@State` inside a SwiftUI view that the controller rebuilds wholesale, so
/// there's nothing outside to call. An observable request the view watches is the way in — the same
/// shape as `ProjectViewState`'s counters, and for the same reason.
@MainActor
final class FocusPanelRequests: ObservableObject {
    static let shared = FocusPanelRequests()

    @Published private(set) var pending: FocusEditorRequest?

    private var nextID = 1

    private init() {}

    func open(_ kind: EditorTarget.Kind, position: TaskInsertPosition = .child) {
        pending = FocusEditorRequest(kind: kind, position: position, id: nextID)
        nextID += 1
    }
}
