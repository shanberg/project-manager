import AppKit
import PmLib
import SwiftUI

/// What the companion keeps that isn't the project's: which way it is drawn, and how it is dressed.
/// Set by `CanvasSatelliteCompanion`; the project itself is read straight off the store.
@MainActor
@Observable
final class CanvasCompanionState {
    /// Every anchor is blocked, so it rests as a pill (`CanvasCompanionPlacement.Choice.asPill`).
    var asPill = false
    /// A pill the pointer is over opens, and closes again when it leaves — unless you are typing in it.
    var pillOpen = false
    var showsAllTasks = false
    var title = ""
    var tint: Color?
    var icon: ProjectIcon?

    var showsPill: Bool { asPill && !pillOpen }
}

/// The session companion's content: the sitting you are in and the work that's open, beside the
/// satellite you are working in. See `CanvasSatelliteCompanion`.
///
/// **Built for its size, not cut down from the project card.** The card draws the whole notes
/// document, so it costs as much as the project is long; this reads a fixed amount whatever the
/// project — the current sitting's heading, the last three lines of its prose, the first five open
/// tasks and a count. The rest of the project is the project window's.
///
/// **No stepping in.** A card on a board takes a click before it takes edits, so panning across it is
/// safe; this is a thing you aim at, so a click on a box ticks it and a click in a field types.
struct CanvasCompanionView: View {
    let store: PMStore
    let state: CanvasCompanionState
    var onSize: (CGSize) -> Void = { _ in }
    /// The header (or the pill) dragged: the panel follows the pointer, and snaps to a corner on release.
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}
    /// The panel takes the keyboard only when a field here has a use for it. See `KeyablePanel`.
    var onNeedsKeyboard: () -> Void = {}
    /// Typing done: the keyboard goes back to the satellite.
    var onDoneTyping: () -> Void = {}
    var onOpenProject: () -> Void = {}

    static let noteLines = 3
    static let taskCount = 5

    private enum Field { case note, task }
    @FocusState private var field: Field?
    @State private var noteText = ""
    @State private var taskText = ""
    @State private var addingTask = false
    @State private var closing: Task<Void, Never>?

    var body: some View {
        Group {
            if state.showsPill { pill } else { panel }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onHover { inside in
            guard state.asPill else { return }
            closing?.cancel()
            if inside { state.pillOpen = true; return }
            closing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, field == nil else { return }
                state.pillOpen = false
            }
        }
    }

    // MARK: Parts

    private var session: Session? { store.notes?.sessions.first }

    private var sessionLine: String {
        guard let session else { return "No session yet" }
        let label = SessionLabel(parsing: session.label)
        let day = session.date == formatSessionDate() ? "Today" : session.date
        return [day, label.name.isEmpty ? label.time : label.name].compactMap { $0 }.joined(separator: " · ")
    }

    private var mark: some View {
        Group {
            if let icon = state.icon {
                ProjectIconMark(icon: icon, size: 14, tint: state.tint)
            } else {
                Circle().fill(state.tint ?? .secondary).frame(width: 9, height: 9)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var pill: some View {
        HStack(spacing: 7) {
            mark
            Text(sessionLine).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text("\(store.openTodos.count) open").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(height: 28)
        .background(CompanionGlass(tint: state.tint, cornerRadius: 14))
        .contentShape(Capsule())
        .gesture(moving)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            note
            Divider().opacity(0.5)
            tasks
        }
        .font(.system(size: 12))
        .frame(width: CanvasCompanionPlacement.width)
        .background(CompanionGlass(tint: state.tint, cornerRadius: 14))
    }

    /// Grabbing the panel. The pointer is read from the screen by the controller, since the window
    /// moves under the gesture and its own translation would chase itself.
    private var moving: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in onDragChanged() }
            .onEnded { _ in onDragEnded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                mark
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(sessionLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .gesture(moving)
            Spacer(minLength: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(moving)
            Button("New Session", systemImage: "plus") {
                store.openCurrentSession(forcingNew: true) { _ in }
            }
            .labelStyle(.iconOnly)
            .help("New Session")
            Button("Show Project", systemImage: "arrow.up.forward.app", action: onOpenProject)
                .labelStyle(.iconOnly)
                .help("Show the project's window")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var note: some View {
        let lines = session.map { CanvasCompanionPlacement.noteTail($0.body, count: Self.noteLines) } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            entry("Add to the note…", text: $noteText, field: .note) { text in
                store.appendSessionNote(text)
                noteText = ""
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var tasks: some View {
        let open = store.openTodos
        let shown = state.showsAllTasks ? open : Array(open.prefix(Self.taskCount))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Tasks").textCase(.uppercase).font(.system(size: 10)).kerning(0.6)
                Spacer()
                Text("\(open.count) open").font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
            if state.showsAllTasks {
                ScrollView { LazyVStack(alignment: .leading, spacing: 2) { rows(shown) } }
                    .frame(maxHeight: 320)
            } else {
                rows(shown)
            }
            if open.count > Self.taskCount {
                Button(state.showsAllTasks ? "Show fewer" : "\(open.count - Self.taskCount) more") {
                    state.showsAllTasks.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
            if addingTask {
                entry("New task", text: $taskText, field: .task) { text in
                    store.addTodo(text: text)
                    taskText = ""
                }
            } else {
                Button("Add Task", systemImage: "plus") {
                    addingTask = true
                    focus(.task)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func rows(_ todos: [Todo]) -> some View {
        ForEach(todos.map { (PMStore.key(for: $0), $0) }, id: \.0) { _, todo in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { store.toggle(todo) } label: { TaskStatusIcon(state: todo.state, size: 13) }
                    .buttonStyle(.plain)
                    .help("Complete")
                Text(todo.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let due = todo.dueDate ?? todo.effectiveDueDate {
                    Text(RelativeDue.short(due))
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(todo.dueDate != nil ? Color.orange : Color.secondary)
                }
            }
            .padding(.leading, CGFloat(todo.depth) * 12)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(todo.isFocused ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { store.focus(todo) }
        }
    }

    /// A one-line field that submits on Return and stays open for the next line; Escape gives the
    /// keyboard back. A click into it asks for the keyboard first, since the panel doesn't take it for
    /// being clicked.
    private func entry(_ prompt: String, text: Binding<String>, field which: Field,
                       submit: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .focused($field, equals: which)
            .onSubmit {
                let line = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { submit(line) }
                focus(which)
            }
            .onExitCommand { stopTyping() }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .simultaneousGesture(TapGesture().onEnded { focus(which) })
    }

    private func focus(_ which: Field) {
        onNeedsKeyboard()
        DispatchQueue.main.async { field = which }
    }

    private func stopTyping() {
        field = nil
        addingTask = false
        taskText = ""
        onDoneTyping()
    }
}

/// Liquid Glass, as the focus panel and the dock wear it, leaning toward the project's colour.
private struct CompanionGlass: NSViewRepresentable {
    var tint: Color?
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.cornerRadius = cornerRadius
        glass.tintColor = tint.map { NSColor($0).withAlphaComponent(0.18) }
    }
}
