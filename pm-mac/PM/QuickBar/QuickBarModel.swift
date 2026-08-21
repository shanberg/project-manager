import PmLib
import SwiftUI

extension NSEvent.ModifierFlags {
    /// SwiftUI's vocabulary for the same keys. The quick bar reads its modifiers from `onKeyPress`,
    /// which reports them this way, so a click has to say the same thing a keystroke would.
    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        if contains(.shift) { out.insert(.shift) }
        return out
    }
}

/// What the quick bar is for at the moment it was summoned.
///
/// Two hotkeys, one panel. Capture and navigation want the same window and the same keyboard handling,
/// but they read a typed line in opposite ways — one as text to keep, the other as a query to throw
/// away — and a single field that guesses between them is the way to fill a project's notes with
/// half-typed project names. Which mode you're in is a decision you made before you started typing,
/// which is exactly what a hotkey records. Tab still switches, for when you reach for the wrong one.
enum QuickBarMode: CaseIterable {
    case capture
    case goToProject

    var placeholder: String {
        switch self {
        case .capture: return "Add a task…"
        case .goToProject: return "Go to project…"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "plus.circle"
        case .goToProject: return "magnifyingglass"
        }
    }

    var other: QuickBarMode { self == .capture ? .goToProject : .capture }
}

/// One row the quick bar can act on.
enum QuickBarRow: Identifiable, Equatable {
    /// The task that would be created, as parsed — so the due date it picked up is visible before ⏎.
    case addTask(text: String, due: String?, project: String)
    case project(key: String, name: String, shortName: String, domain: String, isArchived: Bool)

    var id: String {
        switch self {
        case .addTask(let text, let due, _): return "add:\(text):\(due ?? "")"
        case .project(let key, _, _, _, _): return "project:\(key)"
        }
    }
}

/// The quick bar's state and what its rows do.
///
/// Held apart from the view because the controller re-seeds it on every summon and because the row
/// building is the part worth testing: what a typed line resolves to shouldn't need a window on screen
/// to find out.
@MainActor
final class QuickBarModel: ObservableObject {
    @Published var mode: QuickBarMode = .capture { didSet { rebuild() } }
    @Published var query: String = "" { didSet { rebuild() } }
    @Published private(set) var rows: [QuickBarRow] = []
    /// Index into `rows`. Clamped on every rebuild, so it can't point past a shrinking list.
    @Published var selection: Int = 0

    /// The focused project's display name, or nil when there isn't one — capture has nowhere to go.
    @Published var focusedProjectName: String?

    /// Recent projects (empty query) and everything (a query), supplied by the controller so the model
    /// stays free of the scan.
    var recents: [ProjectIndex.Recent] = []
    var allProjects: [ProjectIndex.ProjectEntry] = []

    /// Runs a chosen row. Set by the controller, which owns what "go to a project" means.
    var onRun: (QuickBarRow, _ modifiers: EventModifiers) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}

    // MARK: Rows

    func reset(mode: QuickBarMode) {
        self.mode = mode
        query = ""
        selection = 0
        rebuild()
    }

    func rebuild() {
        rows = buildRows()
        selection = rows.isEmpty ? 0 : min(selection, rows.count - 1)
    }

    private func buildRows() -> [QuickBarRow] {
        switch mode {
        case .capture:
            guard let project = focusedProjectName else { return [] }
            let parsed = QuickCaptureParser.parse(query)
            guard !parsed.text.isEmpty else { return [] }
            return [.addTask(text: parsed.text, due: parsed.due, project: project)]

        case .goToProject:
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                return recents.prefix(Self.rowLimit).map {
                    .project(key: $0.projectKey, name: $0.name,
                             shortName: shortName(of: $0.name), domain: "", isArchived: false)
                }
            }
            let matches = ProjectSearch.rank(allProjects, query: query) { entry in
                ProjectSearch.Candidate(name: entry.name, shortName: entry.shortName,
                                        code: entry.code, isArchived: entry.isArchived)
            }
            return matches.prefix(Self.rowLimit).map {
                .project(key: $0.projectKey, name: $0.name, shortName: $0.shortName,
                         domain: $0.domain, isArchived: $0.isArchived)
            }
        }
    }

    /// How many rows the bar will show. Enough to choose from, few enough to read without scrolling —
    /// past this the answer is a better query, not a longer list.
    static let rowLimit = 7

    /// The recents list carries only the full folder name, so the title has to come off the front here.
    private func shortName(of name: String) -> String {
        guard let dash = name.firstIndex(of: "-"),
              let space = name[dash...].firstIndex(of: " ") else { return name }
        let rest = name[name.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func runSelection(modifiers: EventModifiers = []) {
        guard rows.indices.contains(selection) else { return }
        onRun(rows[selection], modifiers)
    }

    func switchMode() {
        mode = mode.other
        selection = 0
    }
}
