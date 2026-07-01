import SwiftUI
import AppKit
import PmLib

/// The panel's SwiftUI content, reconstructing the retired Tauri panel: a collapsible "Project
/// details" section, a task list grouped by session, per-row focus / due editing / positional add,
/// an "incomplete only" filter, and Escape-to-dismiss. Binds to `PMStore`; mutations go straight
/// through it to `PmLib`. Reports its content height so the panel window can auto-fit.
struct PanelView: View {
    @ObservedObject var store: PMStore
    /// Shared chrome state (e.g. hide the scrollbar during a resize animation).
    @ObservedObject var chrome: PanelChrome
    /// Escape with no open editor asks the window to hide.
    var onDismiss: () -> Void = {}
    /// Measured content height, for the window's auto-fit.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    /// Off by default: the panel shows only incomplete tasks; toggling on reveals completed ones too.
    @State private var showAll = false
    /// The row (and editor kind) with an open inline editor, if any. Only one at a time.
    @State private var activeEditor: EditorTarget?
    /// Tracks the ⌥ key so the Open button can swap between Obsidian and Finder live, like the menu.
    @StateObject private var modifiers = ModifierMonitor()

    private var visibleTodos: [Todo] {
        showAll ? store.todos : store.todos.filter { !$0.checked }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if store.projectName == nil {
                    emptyState
                } else {
                    if hasDetails { ProjectDetailsView(notes: store.notes) }
                    tasksSection
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        // Hide the scrollbar while the window is animating its resize (it would otherwise flash as the
        // viewport and content briefly mismatch); it returns for genuine overflow past the max height.
        .scrollIndicators(chrome.isResizing ? .never : .automatic)
        .frame(width: 420)
        // Liquid Glass (macOS 26+) / vibrancy background, filling the content's layout.
        .background(PanelBackground())
        // The panel's titlebar is transparent and its content is meant to sit under it; without this
        // the hosting controller insets the content by the titlebar height, so the measured height is
        // ~one row short of what's shown and the window scrolls. Ignoring the top safe area makes the
        // measured height match the rendered height, so auto-fit is exact and no scrollbar appears.
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(ContentHeightKey.self) { onContentHeight($0) }
        .onExitCommand(perform: handleEscape)
        .onAppear { modifiers.start() }
        .onDisappear { modifiers.stop() }
    }

    private var hasDetails: Bool {
        guard let n = store.notes else { return false }
        return !n.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !n.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || n.goals.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !n.approach.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || n.links.contains { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
            || n.learnings.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func handleEscape() {
        if activeEditor != nil {
            activeEditor = nil
        } else {
            onDismiss()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
            let p = store.progress
            if p.total > 0 {
                Text("\(p.done)/\(p.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if store.projectPath != nil {
                HStack(spacing: 4) {
                    openButton
                    raycastButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Opens the focused project's view in Raycast (same deep link as the menu's "View Project").
    private var raycastButton: some View {
        Button {
            if let url = URL(string: "raycast://extensions/shanberg/project-manager/view-focused-project") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Group {
                if let icon = AppIcons.panelImage(.raycast) {
                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open project in Raycast")
    }

    /// Opens the project in Obsidian, or in Finder while ⌥ is held (icon swaps to match), mirroring
    /// the menubar's "Open in Obsidian / ⌥ Open in Finder" alternate.
    private var openButton: some View {
        let finder = modifiers.optionDown
        let appIcon = AppIcons.panelImage(finder ? .finder : .obsidian)
        return Button {
            openProject(inFinder: finder)
        } label: {
            Group {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 15, height: 15)
                } else {
                    Image(systemName: finder ? "folder" : "book.closed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(finder ? "Open in Finder" : "Open in Obsidian  (hold ⌥ for Finder)")
    }

    private func openProject(inFinder: Bool) {
        if inFinder {
            guard let path = store.projectPath else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let url = URL(string: "raycast://extensions/shanberg/project-manager/open-focused-in-obsidian") {
            NSWorkspace.shared.open(url)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(store.errorMessage ?? "No focused project")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Focus a project from Raycast or the menubar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Tasks

    /// Session indices in first-appearance order among the visible todos.
    private var sessionOrder: [Int] {
        var seen = Set<Int>()
        var order: [Int] = []
        for t in visibleTodos where !seen.contains(t.sessionIndex) {
            seen.insert(t.sessionIndex); order.append(t.sessionIndex)
        }
        return order
    }

    private func sessionContext(_ index: Int) -> String {
        guard let sessions = store.notes?.sessions, index < sessions.count else { return "" }
        let s = sessions[index]
        return s.label.isEmpty ? s.date : "\(s.date) · \(s.label)"
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tasks").font(.subheadline).bold()
                Spacer()
                Toggle(isOn: $showAll) { Text("Show all").font(.caption) }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if visibleTodos.isEmpty {
                Text(showAll ? "No tasks yet" : "All tasks complete 🎉")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(sessionOrder, id: \.self) { si in
                    let context = sessionContext(si)
                    if !context.isEmpty {
                        Text(context)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    ForEach(visibleTodos.filter { $0.sessionIndex == si }, id: \.rawLine) { todo in
                        TaskRow(
                            todo: todo,
                            store: store,
                            activeEditor: $activeEditor
                        )
                    }
                }
            }
        }
        .padding(.bottom, 8)
        // Animate rows entering/leaving — covers both completing a task and toggling "Show all",
        // since the visible set derives from both the todos and the filter.
        .animation(.snappy, value: visibleTodos)
    }
}

/// Identifies which row has an open inline editor, and which kind.
struct EditorTarget: Equatable {
    enum Kind { case add, due }
    let key: String       // "sessionIndex:lineIndex"
    let kind: Kind
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: Task row

private struct TaskRow: View {
    let todo: Todo
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?
    @State private var hovering = false

    private var key: String { PMStore.key(for: todo) }
    private var isAdding: Bool { activeEditor == EditorTarget(key: key, kind: .add) }
    private var isEditingDue: Bool { activeEditor == EditorTarget(key: key, kind: .due) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(action: { store.toggle(todo) }) {
                    Image(systemName: todo.checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.checked ? Color.accentColor : Color.secondary)
                        .symbolReplaceIfAvailable()
                        .bounceIfAvailable(todo.checked)
                }
                .buttonStyle(.plain)

                Text(todo.text)
                    .font(.system(size: 13, weight: todo.isFocused ? .semibold : .regular))
                    .strikethrough(todo.checked, color: .secondary)
                    .foregroundStyle(todo.checked ? .secondary : .primary)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(todo) }

                Spacer(minLength: 4)

                DueChip(todo: todo, isEditing: isEditingDue) { toggleEditor(.due) }

                Button(action: { toggleEditor(.add) }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add task here")
                .opacity(hovering || isAdding ? 1 : 0)
            }
            .padding(.leading, CGFloat(todo.depth) * 16)

            if isEditingDue {
                DueEditor(seed: dueSeed) { newDue in
                    store.setDue(todo, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.leading, CGFloat(todo.depth) * 16 + 22)
            }
            if isAdding {
                AddEditor { text, due, position in
                    store.addTodo(text: text, due: due, relativeTo: todo, position: position)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.leading, CGFloat(todo.depth) * 16 + 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }

    /// First 10 chars of own-or-inherited due, if they look like YYYY-MM-DD (for the date picker seed).
    private var dueSeed: String {
        let raw = todo.dueDate ?? todo.effectiveDueDate ?? ""
        return String(raw.prefix(10))
    }

    private func toggleEditor(_ kind: EditorTarget.Kind) {
        let target = EditorTarget(key: key, kind: kind)
        activeEditor = (activeEditor == target) ? nil : target
    }
}

// MARK: Due chip + editor

private struct DueChip: View {
    let todo: Todo
    let isEditing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if let own = todo.dueDate {
                chip(String(own.prefix(10)), color: .orange, dashed: false)
            } else if let eff = todo.effectiveDueDate {
                chip(String(eff.prefix(10)), color: .secondary, dashed: true)
            } else {
                chip("＋date", color: .secondary, dashed: true)
            }
        }
        .buttonStyle(.plain)
        .help(todo.dueDate != nil ? "Edit due date" :
              (todo.effectiveDueDate != nil ? "Inherited due — click to set this task's own" : "Set due date"))
    }

    private func chip(_ text: String, color: Color, dashed: Bool) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3] : []))
            )
            .foregroundStyle(color)
    }
}

private struct DueEditor: View {
    let seed: String
    let onSet: (String?) -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(seed: String, onSet: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.seed = seed
        self.onSet = onSet
        self.onCancel = onCancel
        _date = State(initialValue: DueFormat.parse(seed) ?? Date())
    }

    var body: some View {
        HStack(spacing: 6) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
            Button("Set") { onSet(DueFormat.string(date)) }
            Button("Clear") { onSet(nil) }
            Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

// MARK: Add editor (positional)

private struct AddEditor: View {
    let onAdd: (String, String?, TaskInsertPosition) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var position: TaskInsertPosition = .child
    @State private var useDue = false
    @State private var date = Date()
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $position) {
                Text("Before").tag(TaskInsertPosition.before)
                Text("Subtask").tag(TaskInsertPosition.child)
                Text("After").tag(TaskInsertPosition.after)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Task text", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit(submit)

            HStack(spacing: 6) {
                Toggle("Due", isOn: $useDue).toggleStyle(.checkbox)
                if useDue {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                }
                Spacer()
                Button("Add", action: submit).keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
            }
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        .onAppear { textFocused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, useDue ? DueFormat.string(date) : nil, position)
    }
}

// MARK: Project details

private struct ProjectDetailsView: View {
    let notes: ProjectNotes?
    @State private var expanded = false

    var body: some View {
        if let n = notes {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    textBlock("Summary", n.summary)
                    textBlock("Problem", n.problem)
                    numberedBlock("Goals", n.goals)
                    textBlock("Approach", n.approach)
                    LinksBlock(links: n.links)
                    bulletBlock("Learnings", n.learnings)
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Project details").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func textBlock(_ title: String, _ body: String) -> some View {
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).bold().foregroundStyle(.secondary)
                Text(body).font(.system(size: 12))
            }
        }
    }

    @ViewBuilder private func numberedBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).bold().foregroundStyle(.secondary)
                ForEach(nonEmpty, id: \.offset) { idx, item in
                    Text("\(idx + 1). \(item)").font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).bold().foregroundStyle(.secondary)
                ForEach(nonEmpty, id: \.self) { Text("• \($0)").font(.system(size: 12)) }
            }
        }
    }
}

private struct LinksBlock: View {
    let links: [LinkEntry]

    private var usable: [LinkEntry] {
        links.filter { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Links").font(.caption).bold().foregroundStyle(.secondary)
                ForEach(Array(usable.enumerated()), id: \.offset) { _, link in
                    linkRow(link)
                }
            }
        }
    }

    @ViewBuilder private func linkRow(_ link: LinkEntry) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        let urlStr = (link.url ?? "").trimmingCharacters(in: .whitespaces)
        if isSafeURL(urlStr), let url = URL(string: urlStr) {
            let pretty = prettyURL(urlStr)
            HStack(spacing: 6) {
                Link(label.isEmpty ? pretty : label, destination: url).font(.system(size: 12))
                if !label.isEmpty && pretty != label {
                    Text(pretty).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            let text = (!label.isEmpty && !urlStr.isEmpty) ? "\(label): \(urlStr)" : (label.isEmpty ? urlStr : label)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func isSafeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    private func prettyURL(_ s: String) -> String {
        var out = s
        for scheme in ["https://", "http://"] where out.lowercased().hasPrefix(scheme) {
            out = String(out.dropFirst(scheme.count)); break
        }
        if out.hasSuffix("/") { out = String(out.dropLast()) }
        return out
    }
}

// MARK: Helpers

/// `due:` values are stored/displayed as `YYYY-MM-DD`.
enum DueFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String) -> Date? { formatter.date(from: String(s.prefix(10))) }
    static func string(_ d: Date) -> String { formatter.string(from: d) }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// SF Symbol animation modifiers, applied only where available (macOS 14+); no-ops below.
private extension View {
    @ViewBuilder func symbolReplaceIfAvailable() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }
    @ViewBuilder func bounceIfAvailable<V: Equatable>(_ value: V) -> some View {
        if #available(macOS 14.0, *) { symbolEffect(.bounce, value: value) } else { self }
    }
}

/// The panel's translucent background: Liquid Glass (`NSGlassEffectView`) on macOS 26+, falling back
/// to `NSVisualEffectView` vibrancy below. Used as a SwiftUI `.background` so it fills the content's
/// layout and resizes with the auto-fit instead of fighting it.
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Publishes whether ⌥ is currently held, so a button can swap its icon/action live (as macOS menus
/// do for alternate items). Backed by a local `flagsChanged` monitor active while the panel is key.
final class ModifierMonitor: ObservableObject {
    @Published var optionDown = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionDown = event.modifierFlags.contains(.option)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        optionDown = false
    }
}
