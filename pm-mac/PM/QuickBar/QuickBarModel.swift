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

/// Where a line typed into the quick bar goes.
///
/// One field, several destinations, chosen from a list rather than by a modifier — because the app has
/// more than two of them and a bar you summon from another app is the wrong place to be recalling which
/// chord meant which. The order is the menubar's Add ▸ order so both surfaces teach the same thing, and
/// narrowing leads because that's the app's primary action: a new task nested under the one in hand,
/// which is what you're usually typing when you summon this mid-task. Adding at the end of today's
/// session is the other thing — a task that belongs to the project but not to the task in hand — and
/// it's one ↓ away.
enum CapturePlacement: String, CaseIterable {
    case narrow
    case after
    case sessionEnd
    case sessionNote

    /// Whether this placement is relative to a task, and so needs there to be one.
    var needsAnchor: Bool { self == .narrow || self == .after }

    /// The row's glyph. It flips with the label under ⌥, so the arrow never points the opposite way
    /// from the words next to it.
    func symbol(optionDown: Bool) -> String {
        switch self {
        case .narrow: return "arrow.turn.down.right"
        case .after: return optionDown ? "arrow.up" : "arrow.down"
        case .sessionEnd: return "plus"
        case .sessionNote: return "note.text"
        }
    }

    /// What ⏎ on this row will do, spelled out. `optionDown` flips the sibling row to "before" — the
    /// same alternate the menubar's Add ▸ offers under the same key, live, so holding ⌥ shows you what
    /// you're about to get rather than asking you to trust it.
    func title(anchor: String?, optionDown: Bool) -> String {
        switch self {
        case .narrow: return "Narrow under \(quoted(anchor))"
        case .after: return optionDown ? "Add before \(quoted(anchor))" : "Add after \(quoted(anchor))"
        case .sessionEnd: return "Add to end of today's session"
        case .sessionNote: return "New session note"
        }
    }

    private func quoted(_ anchor: String?) -> String {
        guard let anchor, !anchor.isEmpty else { return "the focused task" }
        return "“\(QuickBarModel.truncate(anchor, 38))”"
    }
}

/// One row the quick bar can act on.
enum QuickBarRow: Identifiable, Equatable {
    /// A destination for the line being typed, as parsed — so the due date it picked up is visible
    /// before ⏎, and so is which task it would land under.
    case capture(placement: CapturePlacement, text: String, due: String?, anchor: String?)
    case project(key: String, name: String, shortName: String, domain: String, isArchived: Bool)

    /// Identity is what the row *is*, never what's been typed into it.
    ///
    /// The rows rebuild on every keystroke, and an id carrying the typed text would hand every row a
    /// new identity each character. `ForEach` would tear down and re-create the views, which re-runs
    /// `.onHover` — so a mouse resting anywhere over the list would take the selection back from the
    /// arrow keys on every letter typed.
    var id: String {
        switch self {
        case .capture(let placement, _, _, _): return "capture:\(placement.rawValue)"
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

    /// The task a captured line would be placed relative to, for the rows to name. Nil when the project
    /// has no open tasks, which is what takes the two anchored placements off the list.
    @Published var focusedTaskText: String?

    /// Whether ⌥ is held right now, published by the controller's flags monitor. Only the labels want
    /// it — running a row reads the modifiers off the keystroke that ran it.
    @Published var optionDown = false

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
        optionDown = false
        rebuild()
    }

    func rebuild() {
        rows = buildRows()
        selection = rows.isEmpty ? 0 : min(selection, rows.count - 1)
    }

    private func buildRows() -> [QuickBarRow] {
        switch mode {
        case .capture:
            guard focusedProjectName != nil else { return [] }
            let parsed = QuickCaptureParser.parse(query)
            guard !parsed.text.isEmpty else { return [] }
            return CapturePlacement.allCases
                .filter { placement in
                    if placement.needsAnchor { return focusedTaskText != nil }
                    // A dated line is a task by definition, so the note row stands down rather than
                    // offering to write a due date into prose that can't carry one.
                    if placement == .sessionNote { return parsed.due == nil }
                    return true
                }
                .map { .capture(placement: $0, text: parsed.text, due: parsed.due, anchor: focusedTaskText) }

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

    /// Shorten a task's text to fit in a row's title, on a word boundary where there is one.
    nonisolated static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let trimmed = cut.contains(" ") ? cut[cut.startIndex..<cut.lastIndex(of: " ")!] : cut
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
    }

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

    /// The selected row, for the hint line to describe.
    var selectedRow: QuickBarRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// The due date the typed line parsed to, spelled out — "Sat, Aug 22" — or nil when it carries no
    /// date. Written in full where a task's own badge would say "in 1w": a badge on an existing task
    /// tells you how much time is left, while this confirms that the "friday" you just typed landed on
    /// the day you meant.
    var parsedDueLabel: String? {
        guard case .capture(_, _, let due, _)? = rows.first, let due else { return nil }
        return RelativeDue.parse(due).map { Self.dueFormatter.string(from: $0) }
    }

    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}
