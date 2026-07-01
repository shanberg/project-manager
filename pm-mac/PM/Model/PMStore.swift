import Foundation
import Combine
import AppKit
import PmLib

/// Single source of truth for the focused project, shared by the menubar item and the panel.
///
/// Calls `PmLib` directly (no `pm` subprocess, no Rust bridge). All notes IO runs on a serial
/// background queue so concurrent mutations can't interleave writes; published state is updated on
/// the main actor. `reload()` re-reads `focused.json` and `pm notes show` for the focused project;
/// mutations perform their `NotesService` call and then reload.
@MainActor
final class PMStore: ObservableObject {
    @Published private(set) var projectKey: String?
    @Published private(set) var projectName: String?
    /// Resolved project folder path, captured during reload (for Open in Finder etc.).
    @Published private(set) var projectPath: String?
    /// Resolved path to the focused project's notes file, captured during reload so the app can watch
    /// it without re-scanning the (protected) project directory on every UI update.
    @Published private(set) var notesPath: String?
    @Published private(set) var notes: ProjectNotes?
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var focusedKey: String?
    @Published private(set) var errorMessage: String?
    /// True once the first successful load has painted; used to keep the last-good render across
    /// transient (cloud-sync) read failures instead of flashing to empty.
    @Published private(set) var hasLoaded = false

    /// Serial queue for all `PmLib` notes IO (reads and writes) — prevents interleaved writes.
    private let io = DispatchQueue(label: "com.stuarthanberg.pm.notes-io")

    // MARK: Derived state for the UI

    /// The currently focused todo, if any.
    var focusedTodo: Todo? { todos.first { $0.isFocused } }

    /// Open (unchecked) todos in document order.
    var openTodos: [Todo] { todos.filter { !$0.checked } }

    /// Completion progress as (done, total). Total counts all parsed todos.
    var progress: (done: Int, total: Int) {
        let total = todos.count
        let done = todos.filter { $0.checked }.count
        return (done, total)
    }

    /// A stable key for a todo, matching `focusedKey` format ("sessionIndex:lineIndex").
    static func key(for todo: Todo) -> String { "\(todo.sessionIndex):\(todo.lineIndex)" }

    // MARK: Loading

    /// Re-read the focused project and its notes. Safe to call frequently (e.g. from the watcher).
    func reload() {
        let key = PMFiles.focusedProjectKey()
        guard let key, let name = PMFiles.projectName(fromKey: key) else {
            projectKey = nil
            projectName = nil
            projectPath = nil
            notesPath = nil
            notes = nil
            todos = []
            focusedKey = nil
            errorMessage = key == nil ? nil : "Invalid focused project."
            hasLoaded = true
            return
        }
        io.async { [weak self] in
            // Resolve the project directory once (this is the protected-folder access), then reuse
            // the handle for both the notes read and the cached notes path.
            Log.write("reload start: name=\(name)")
            let result = Result { () -> (NotesShowOutput, String, String) in
                let cfg = try? loadConfig()
                Log.write("config: useObsidianCLI=\(cfg?.useObsidianCLI ?? false)")
                let handle = try resolveNotesHandle(project: name)
                Log.write("resolved: notesPath=\(handle.notesPath) io=\(type(of: handle.io))")
                let output = try notesShow(handle: handle)
                Log.write("notesShow ok: todos=\(output.todos.count)")
                return (output, handle.notesPath, handle.projectPath)
            }
            if case .failure(let error) = result {
                let ns = error as NSError
                Log.write("reload FAILED: \(error) [domain=\(ns.domain) code=\(ns.code)]")
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let (output, path, projectPath)):
                    self.projectKey = key
                    self.projectName = name
                    self.notesPath = path
                    self.projectPath = projectPath
                    self.notes = output.notes
                    self.todos = output.todos
                    self.focusedKey = output.focusedKey
                    self.errorMessage = nil
                    self.hasLoaded = true
                case .failure(let error):
                    // Keep the last-good render on transient failures; only surface the error text.
                    self.errorMessage = String(describing: error)
                    self.hasLoaded = true
                }
            }
        }
    }

    /// Switch the focused project (updates focused.json + recent list) and reload.
    func setFocusedProject(key: String) {
        guard let name = PMFiles.projectName(fromKey: key) else { return }
        io.async { [weak self] in
            try? PMFiles.setFocusedProjectKey(key)
            PMFiles.recordRecent(projectKey: key, name: name)
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: Mutations (each performs the NotesService call, then reloads)

    private func mutate(_ work: @escaping (String) throws -> Void) {
        guard let name = projectName else { return }
        io.async { [weak self] in
            do {
                try work(name)
            } catch {
                Task { @MainActor in self?.errorMessage = String(describing: error) }
            }
            Task { @MainActor in self?.reload() }
        }
    }

    /// Key of the most recently completed task this session, for the menubar's ⌥ Undo alternate.
    @Published private(set) var lastCompletedKey: String?

    func complete(_ todo: Todo, advanceFocus: Bool = true) {
        lastCompletedKey = Self.key(for: todo)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        mutate { try completeTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, advanceFocus: advanceFocus) }
    }

    /// Undo the most recent completion (re-open it and move focus back onto it).
    func undoLast() {
        guard let key = lastCompletedKey else { return }
        let parts = key.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        lastCompletedKey = nil
        mutate { try undoTodo(project: $0, sessionIndex: parts[0], lineIndex: parts[1]) }
    }

    func toggle(_ todo: Todo) {
        if todo.checked {
            undo(todo)
        } else {
            complete(todo, advanceFocus: true)
        }
    }

    func focus(_ todo: Todo) {
        mutate { try focusTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex) }
    }

    func undo(_ todo: Todo) {
        mutate { try undoTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex) }
    }

    func setDue(_ todo: Todo, due: String?) {
        mutate { try setDueOnTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, due: due) }
    }

    /// Replace a task's text in place (checkbox, due, focus, and indent preserved).
    func editText(_ todo: Todo, text: String) {
        mutate { try setTodoText(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, text: text) }
    }

    /// Wrap a task in a new parent task, nesting the task (and its subtree) under it; focus stays put.
    func wrap(_ todo: Todo, parentText: String) {
        mutate { try wrapTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, text: parentText) }
    }

    /// The task focus should advance to: the first open leaf under the focused task, else the next
    /// open leaf anywhere in document order. Always excludes the currently focused task itself.
    /// Drives both "Dive in" and the focused-mode "Next" hint so the two can't diverge.
    var nextTodo: Todo? {
        let list = todos
        guard !list.isEmpty else { return nil }
        func isLeaf(_ i: Int) -> Bool {
            let next = i + 1
            return next >= list.count
                || list[next].sessionIndex != list[i].sessionIndex
                || list[next].depth <= list[i].depth
        }
        if let fi = list.firstIndex(where: { $0.isFocused }) {
            let fd = list[fi].depth
            var j = fi + 1
            while j < list.count, list[j].sessionIndex == list[fi].sessionIndex, list[j].depth > fd {
                if !list[j].checked && isLeaf(j) { return list[j] }
                j += 1
            }
            // No open leaf beneath: first open leaf elsewhere, skipping the focused task itself.
            for i in list.indices where i != fi && !list[i].checked && isLeaf(i) { return list[i] }
            return nil
        }
        // Nothing focused: first open (unchecked) leaf anywhere.
        for i in list.indices where !list[i].checked && isLeaf(i) { return list[i] }
        return nil
    }

    /// "Dive in": move focus to the next open leaf. Mirrors the Raycast Dive In command.
    func diveIn() {
        if let next = nextTodo { focus(next) }
    }

    /// Persist an edit to the project's detail fields (summary, problem, goals, approach, learnings).
    /// The transform runs against freshly-parsed notes on the IO queue, so tasks/sessions are read
    /// from disk and preserved. Reloads afterward like every other mutation.
    func saveDetails(_ transform: @escaping (ProjectNotes) -> ProjectNotes) {
        mutate { try editDetails(project: $0, transform) }
    }

    func addTodo(text: String, due: String? = nil, relativeTo anchor: Todo? = nil, position: TaskInsertPosition? = nil) {
        let placement: (kind: TaskInsertPosition, sessionIndex: Int, lineIndex: Int)?
        if let anchor, let position {
            placement = (position, anchor.sessionIndex, anchor.lineIndex)
        } else {
            placement = nil
        }
        mutate { try PmLib.addTodo(project: $0, text: text, due: due, position: placement) }
    }
}
