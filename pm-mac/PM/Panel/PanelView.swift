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

    /// How the tasks area presents itself, persisted across panel sessions. `.incomplete` (open tasks
    /// only) is the default; `.all` also reveals completed tasks; `.focused` collapses to a single
    /// focused-task card with an ancestor breadcrumb and a dim "next" line.
    @AppStorage("PMPanelTasksMode") private var tasksMode: TasksMode = .incomplete
    /// The panel's color-scheme override, persisted across sessions. `.system` follows the OS setting;
    /// `.light`/`.dark` pin the appearance (of both the content and the glass/vibrancy material).
    @AppStorage("PMPanelColorMode") private var colorMode: PanelColorMode = .system
    /// Whether the collapsible project-details section is open. Toggled from the header's view-options
    /// menu; the content renders inline below the header when true, in any tasks mode. Persisted across
    /// panel sessions like `tasksMode`, so reopening the panel restores the last-chosen state.
    @AppStorage("PMPanelDetailsExpanded") private var detailsExpanded = false
    /// Whether the project-details section is in inline-edit mode (entered by double-clicking its
    /// content). Reset when the section collapses, the project changes, or Escape is pressed.
    @State private var editingDetails = false
    /// The row (and editor kind) with an open inline editor, if any. Only one at a time.
    @State private var activeEditor: EditorTarget?
    /// Tracks the ⌥ key so the Open button can swap between Obsidian and Finder live, like the menu.
    @StateObject private var modifiers = ModifierMonitor()
    /// Cancels an open editor when the user clicks outside it (see `OutsideClickMonitor`).
    @StateObject private var outsideClick = OutsideClickMonitor()

    /// True whenever some inline editor (a task row's, or the project-details form) is open.
    private var isAnyEditorActive: Bool { activeEditor != nil || editingDetails }

    /// True while the project-details section is rendered directly below the header. Drives the
    /// header/divider spacing so the details read as a continuation of the title, not a fenced pane.
    private var detailsShowing: Bool { store.projectName != nil && hasDetails && detailsExpanded }

    private var visibleTodos: [Todo] {
        tasksMode == .all ? store.todos : store.todos.filter { !$0.checked }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                // With details open they sit directly under the title as one continuous brief; the
                // rule stays only to fence the title off from the task list.
                if !detailsShowing { Divider() }
                if store.projectName == nil {
                    emptyState
                } else {
                    if hasDetails && detailsExpanded {
                        ProjectDetailsView(notes: store.notes, store: store, isEditing: $editingDetails)
                    }
                    // While editing details, hide everything below so the form stands alone.
                    if !editingDetails {
                        if tasksMode == .focused { focusedSection } else { tasksSection }
                    }
                }
            }
            .animation(.snappy, value: detailsExpanded)
            .animation(.snappy, value: tasksMode)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        // Hide the scrollbar while the window is animating its resize (it would otherwise flash as the
        // viewport and content briefly mismatch); it returns for genuine overflow past the max height.
        .scrollIndicators(chrome.isResizing ? .never : .automatic)
        .frame(width: 420)
        // Pin the appearance when the user overrides it; `.system` (nil) follows the OS. Applied above
        // the background so the glass/vibrancy material (a child NSView) inherits the same scheme.
        .preferredColorScheme(colorMode.colorScheme)
        // Liquid Glass (macOS 26+) / vibrancy background, filling the content's layout.
        .background(PanelBackground())
        // The panel's titlebar is transparent and its content is meant to sit under it; without this
        // the hosting controller insets the content by the titlebar height, so the measured height is
        // ~one row short of what's shown and the window scrolls. Ignoring the top safe area makes the
        // measured height match the rendered height, so auto-fit is exact and no scrollbar appears.
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(ContentHeightKey.self) { onContentHeight($0) }
        .onPreferenceChange(ActiveEditorFrameKey.self) { outsideClick.editorFrame = $0 }
        .onExitCommand(perform: handleEscape)
        .onChange(of: store.projectName) { _ in editingDetails = false }
        // Collapsing details (from the menu) also leaves any details-edit form.
        .onChange(of: detailsExpanded) { expanded in if !expanded { editingDetails = false } }
        // Start/stop the outside-click monitor with edit mode; an outside click cancels any editor.
        .onChange(of: isAnyEditorActive) { active in
            if active {
                outsideClick.onOutsideClick = {
                    activeEditor = nil
                    editingDetails = false
                }
                outsideClick.start()
            } else {
                outsideClick.stop()
            }
        }
        .onAppear { modifiers.start() }
        .onDisappear { modifiers.stop(); outsideClick.stop() }
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
        if editingDetails {
            editingDetails = false
        } else if activeEditor != nil {
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
                .contentShape(Rectangle())
                // Double-click the title to toggle the details brief (mirrors the view-menu toggle).
                // `simultaneousGesture` so it coexists with window-drag-by-background on the header.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if hasDetails { detailsExpanded.toggle() }
                })
            Spacer()
            let p = store.progress
            if p.total > 0 {
                Text("\(p.done)/\(p.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if store.projectName != nil { viewOptionsMenu }
            if store.projectPath != nil {
                HStack(spacing: 4) {
                    openButton
                    raycastButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        // Pull the details up snug under the title when they're open; keep breathing room above the
        // divider otherwise.
        .padding(.bottom, detailsShowing ? 2 : 10)
    }

    /// Whether the view is in any non-default state (mode other than incomplete, or details showing),
    /// used to tint the view-options icon so there's a subtle "customized" cue.
    private var isViewCustomized: Bool {
        tasksMode != .incomplete || detailsExpanded || colorMode != .system
    }

    /// Single header menu holding all view state: the tasks-mode picker (Focused / Incomplete / All)
    /// and, when the project has any, a "Show details" toggle. Replaces the old "Details" text button
    /// and the tasks-list "Show all" checkbox, consolidating both axes in one HIG-native place.
    private var viewOptionsMenu: some View {
        Menu {
            Picker("Tasks", selection: $tasksMode) {
                Label("Focused", systemImage: "scope").tag(TasksMode.focused)
                Label("Incomplete", systemImage: "circle").tag(TasksMode.incomplete)
                Label("All", systemImage: "list.bullet").tag(TasksMode.all)
            }
            .pickerStyle(.inline)
            if hasDetails {
                Divider()
                Toggle(isOn: $detailsExpanded) { Label("Show details", systemImage: "info.circle") }
            }
            Divider()
            Picker("Appearance", selection: $colorMode) {
                Label("System", systemImage: "circle.lefthalf.filled").tag(PanelColorMode.system)
                Label("Light", systemImage: "sun.max").tag(PanelColorMode.light)
                Label("Dark", systemImage: "moon").tag(PanelColorMode.dark)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isViewCustomized ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View options")
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

    /// While a task is being wrapped it slides one level deeper (nesting under the parent-to-be); its
    /// whole subtree must cascade with it. These are the keys of that subtree — the contiguous run of
    /// deeper todos right after the wrap target — so their rows get the same +1 indent boost.
    private var wrapDescendantKeys: Set<String> {
        guard let ed = activeEditor, ed.kind == .wrap,
              let wIdx = store.todos.firstIndex(where: { PMStore.key(for: $0) == ed.key }) else { return [] }
        let wDepth = store.todos[wIdx].depth
        var keys: Set<String> = []
        var j = wIdx + 1
        while j < store.todos.count, store.todos[j].depth > wDepth {
            keys.insert(PMStore.key(for: store.todos[j]))
            j += 1
        }
        return keys
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tasks").font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if visibleTodos.isEmpty {
                Text(tasksMode == .all ? "No tasks yet" : "All tasks complete 🎉")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let wrapDescendants = wrapDescendantKeys
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
                            activeEditor: $activeEditor,
                            ancestorWrapBoost: wrapDescendants.contains(PMStore.key(for: todo)) ? 1 : 0
                        )
                    }
                }
            }
        }
        .padding(.bottom, 8)
        // Animate rows entering/leaving — covers both completing a task and switching the tasks mode,
        // since the visible set derives from both the todos and the mode.
        .animation(.snappy, value: visibleTodos)
    }

    // MARK: Focused mode

    /// The task the focused card centers on: the truly focused todo if there is one, else the first
    /// open task so the card still has something to show.
    private var focusedHero: Todo? { store.focusedTodo ?? store.openTodos.first }

    /// Compact "what am I doing right now" card: an ancestor breadcrumb, the hero task (completable,
    /// with its due date), and a dim tappable "Next" line. Falls back to a gentle empty state when
    /// there's nothing open to focus.
    @ViewBuilder private var focusedSection: some View {
        if let hero = focusedHero {
            VStack(alignment: .leading, spacing: 12) {
                if let crumb = breadcrumb(for: hero) {
                    Text(crumb)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button(action: { store.toggle(hero) }) {
                        Image(systemName: hero.checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(hero.checked ? Color.accentColor : Color.secondary)
                            .symbolReplaceIfAvailable()
                            .bounceIfAvailable(hero.checked)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(hero.text)
                            .font(.system(size: 17, weight: .semibold))
                            .strikethrough(hero.checked, color: .secondary)
                            .foregroundStyle(hero.checked ? .secondary : .primary)
                            .lineLimit(3)
                        if hero.dueDate != nil || hero.effectiveDueDate != nil {
                            staticDueChip(hero)
                        }
                    }
                }

                if let next = store.nextTodo, next != hero {
                    Divider()
                    HStack(spacing: 6) {
                        Text("Next").font(.caption2).foregroundStyle(.tertiary)
                        Text(next.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.focus(next) }
                    .help("Focus this task")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        } else {
            VStack(alignment: .center, spacing: 6) {
                Text("Nothing focused").font(.subheadline).foregroundStyle(.secondary)
                Text("All tasks complete 🎉").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// The chain of ancestor task texts above `todo`, joined with chevrons, or nil if it's a root task.
    /// Walks the flat todo list backward, picking up one task at each shallower depth within the same
    /// session — the same structure the list indentation reflects.
    private func breadcrumb(for todo: Todo) -> String? {
        let list = store.todos
        guard let idx = list.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return nil }
        var ancestors: [String] = []
        var wantDepth = todo.depth - 1
        var i = idx - 1
        while i >= 0, wantDepth >= 0 {
            let t = list[i]
            if t.sessionIndex == todo.sessionIndex, t.depth == wantDepth {
                ancestors.insert(t.text, at: 0)
                wantDepth -= 1
            }
            i -= 1
        }
        return ancestors.isEmpty ? nil : ancestors.joined(separator: "  ›  ")
    }

    /// Read-only due-date chip for the focused card (editing stays in list mode). Own dates read solid
    /// orange; an inherited date reads dashed and secondary, matching the list's `DueChip`.
    private func staticDueChip(_ todo: Todo) -> some View {
        let own = todo.dueDate
        let text = String((own ?? todo.effectiveDueDate ?? "").prefix(10))
        let color: Color = own != nil ? .orange : .secondary
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: own != nil ? [] : [3]))
            )
            .foregroundStyle(color)
    }
}

/// How the panel's tasks area presents itself. Raw values persist via `@AppStorage`.
enum TasksMode: String {
    case focused, incomplete, all
}

/// The panel's color-scheme override. Raw values persist via `@AppStorage`; `.system` maps to `nil`
/// so SwiftUI falls back to the OS appearance.
enum PanelColorMode: String {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Identifies which row has an open inline editor, and which kind.
struct EditorTarget: Equatable {
    enum Kind { case add, due, edit, wrap }
    let key: String       // "sessionIndex:lineIndex"
    let kind: Kind
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: Outside-click dismissal

/// The active inline editor reports its window-space frame so a mouse-down monitor can tell an
/// outside click (which cancels the editor) from a click within it. Only one editor is open at a
/// time, so the first non-nil frame wins.
private struct ActiveEditorFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

private extension View {
    /// Publish this editor's frame (SwiftUI global / window space) for the outside-click monitor.
    func reportEditorFrame() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ActiveEditorFrameKey.self, value: geo.frame(in: .global))
        })
    }
}

/// Watches for left mouse-downs in the panel window while an editor is open and cancels the editor
/// when the click lands outside its reported frame (swallowing that click so it only dismisses).
/// Scoped to the panel window by identifier, so clicks in other windows are left untouched.
final class OutsideClickMonitor: ObservableObject {
    var editorFrame: CGRect?
    var onOutsideClick: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window.identifier?.rawValue == PanelController.windowIdentifier
            else { return event }
            // SwiftUI's global space is top-left origin; AppKit's locationInWindow is bottom-left.
            guard let frame = self.editorFrame else { return event }
            let flipped = CGRect(x: frame.minX, y: window.frame.height - frame.maxY,
                                 width: frame.width, height: frame.height)
            if flipped.contains(event.locationInWindow) { return event }
            self.onOutsideClick?()
            return nil   // consume: an outside click only dismisses, it doesn't also act
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editorFrame = nil
    }
}

// MARK: Task row

private struct TaskRow: View {
    let todo: Todo
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?
    /// Extra indent levels applied because an ancestor is being wrapped and this row is in its
    /// cascading subtree. 0 for the wrap target itself (it uses `isWrapping`) and for unrelated rows.
    var ancestorWrapBoost: Int = 0
    @State private var hovering = false
    /// Which position a freshly-opened add editor should seed to (set by the plus button and the
    /// context menu's Add actions before opening the editor).
    @State private var pendingAddPosition: TaskInsertPosition = .child

    private var key: String { PMStore.key(for: todo) }
    private var isAdding: Bool { activeEditor == EditorTarget(key: key, kind: .add) }
    private var isEditingDue: Bool { activeEditor == EditorTarget(key: key, kind: .due) }
    private var isEditingText: Bool { activeEditor == EditorTarget(key: key, kind: .edit) }
    private var isWrapping: Bool { activeEditor == EditorTarget(key: key, kind: .wrap) }
    /// Hover-revealed controls (plus, "＋date") are suppressed while any editor is open, so the panel
    /// stays calm in edit mode instead of flashing affordances as the pointer crosses rows.
    private var revealControls: Bool { hovering && activeEditor == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Forms whose new row lands ABOVE this one: wrap (the new parent) and Add Before.
            if isWrapping {
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap") { text in
                    store.wrap(todo, parentText: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            }
            if isAdding && pendingAddPosition == .before {
                addEditor.padding(.leading, indent(todo.depth))
            }

            // The task line itself — or, while editing its text, an in-place editor. Wrapping nudges
            // the row one level deeper so it visibly nests under the parent-to-be above it.
            if isEditingText {
                InlineTextEditor(seed: todo.text, placeholder: "Task text", submitLabel: "Save") { text in
                    store.editText(todo, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            } else {
                taskLine
                    .padding(.leading, indent(todo.depth + ancestorWrapBoost + (isWrapping ? 1 : 0)))
                    .contextMenu { rowMenu }
            }

            // Forms whose row/edit lands BELOW this one: due edit, Add After (sibling), Add Subtask
            // (one level deeper).
            if isEditingDue {
                DueEditor(seed: dueSeed) { newDue in
                    store.setDue(todo, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth) + 22)
            }
            if isAdding && (pendingAddPosition == .after || pendingAddPosition == .child) {
                addEditor.padding(.leading, indent(todo.depth + (pendingAddPosition == .child ? 1 : 0)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
        .animation(.snappy, value: localEditorKind)
        .animation(.snappy, value: ancestorWrapBoost)
    }

    /// Leading inset for a row at the given nesting depth (matches the task line's own indent step).
    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 16 }

    /// This row's open-editor kind, if the active editor belongs to it — drives the layout animation.
    private var localEditorKind: EditorTarget.Kind? {
        activeEditor?.key == key ? activeEditor?.kind : nil
    }

    private var taskLine: some View {
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

            DueChip(todo: todo, isEditing: isEditingDue, reveal: revealControls) { toggleEditor(.due) }

            Button {
                pendingAddPosition = .child
                toggleEditor(.add)
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add subtask")
            .opacity(revealControls || isAdding ? 1 : 0)
        }
    }

    /// The positional add editor. Its slot and indent are chosen by the caller (above/below, depth)
    /// from `pendingAddPosition`, so the form previews exactly where the new task will land.
    private var addEditor: some View {
        AddEditor { text, due in
            store.addTodo(text: text, due: due, relativeTo: todo, position: pendingAddPosition)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
            .reportEditorFrame()
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

    /// Open (never toggle) a given editor on this row — used by the context menu.
    private func openEditor(_ kind: EditorTarget.Kind) {
        activeEditor = EditorTarget(key: key, kind: kind)
    }

    /// Seed the add position, then open the add editor.
    private func openAdd(_ position: TaskInsertPosition) {
        pendingAddPosition = position
        openEditor(.add)
    }

    /// Right-click actions mirroring the hover controls, plus completion/focus. Idiomatic macOS
    /// per-row affordance: keyboard- and VoiceOver-accessible, and keeps the row visually clean.
    /// Wording follows the rest of the app: the add positions match `AddEditor`'s Before/Subtask/After
    /// picker (and Raycast's "Add Before"/"Add After"), due wording matches Raycast's "Set Due Date"/
    /// "Remove Due Date", and an ellipsis marks actions that open a further input editor (as the
    /// menubar does).
    @ViewBuilder private var rowMenu: some View {
        if todo.checked {
            Button { store.toggle(todo) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        } else {
            Button { store.toggle(todo) } label: { Label("Complete", systemImage: "checkmark.circle") }
        }
        if !todo.checked && !todo.isFocused {
            Button { store.focus(todo) } label: { Label("Focus", systemImage: "arrow.right.circle") }
        }
        Button { openEditor(.edit) } label: { Label("Edit Task…", systemImage: "pencil") }
        Divider()
        // Add-position symbols match the menubar's Add submenu (Before ↑, Subtask ↳, After ↓).
        Button { openAdd(.before) } label: { Label("Add Before…", systemImage: "arrow.up") }
        Button { openAdd(.child) } label: { Label("Add Subtask…", systemImage: "arrow.turn.down.right") }
        Button { openAdd(.after) } label: { Label("Add After…", systemImage: "arrow.down") }
        Button { openEditor(.wrap) } label: {
            Label("Wrap Task…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
        }
        Divider()
        Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
        if todo.dueDate != nil {
            Button { store.setDue(todo, due: nil) } label: { Label("Remove Due Date", systemImage: "calendar.badge.minus") }
        }
    }
}

// MARK: Due chip + editor

private struct DueChip: View {
    let todo: Todo
    let isEditing: Bool
    /// Reveal the empty-state "＋date" affordance (true while hovering the row). A real own/inherited
    /// date is content, not a control, so it stays visible regardless.
    let reveal: Bool
    let onTap: () -> Void

    private var hasDate: Bool { todo.dueDate != nil || todo.effectiveDueDate != nil }

    var body: some View {
        if hasDate || reveal || isEditing {
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

// MARK: Add editor

/// Text (+ optional due) entry for a new task. The insert position is chosen by the caller (via the
/// context menu / plus button) and previewed by where this form is placed in the row layout, so the
/// form no longer carries a position picker of its own.
private struct AddEditor: View {
    let onAdd: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var useDue = false
    @State private var date = Date()
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        onAdd(trimmed, useDue ? DueFormat.string(date) : nil)
    }
}

// MARK: Single-field inline editor (edit text / wrap)

/// A one-line text editor used for the row's "Edit Task" (seeded with the current text) and "Wrap
/// Task" (empty, for the new parent) actions. Auto-focuses, submits on Return, cancels on Escape via
/// the panel's `handleEscape`. Matches the styling of `AddEditor`/`DueEditor`.
private struct InlineTextEditor: View {
    let placeholder: String
    let submitLabel: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(seed: String = "", placeholder: String, submitLabel: String,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            Button(submitLabel, action: submit).keyboardShortcut(.defaultAction)
            Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: Project details

private struct ProjectDetailsView: View {
    let notes: ProjectNotes?
    @ObservedObject var store: PMStore
    @Binding var isEditing: Bool

    var body: some View {
        if let n = notes {
            Group {
                if isEditing {
                    DetailsEditor(notes: n) { edited in
                        // Merge only the edited detail fields onto freshly-parsed notes, leaving
                        // links, title, and sessions untouched.
                        store.saveDetails { fresh in
                            var out = fresh
                            out.summary = edited.summary
                            out.problem = edited.problem
                            out.goals = edited.goals
                            out.approach = edited.approach
                            out.learnings = edited.learnings
                            return out
                        }
                        isEditing = false
                    } onCancel: {
                        isEditing = false
                    }
                    .reportEditorFrame()
                } else {
                    readContent(n)
                        // Double-click anywhere in the details content switches to edit mode.
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { isEditing = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // A typographic treatment: the details read like a printed project brief — a serif lead
    // paragraph for the summary, uppercase tracked "eyebrow" labels, and serif body copy — so the
    // persistent project content is visually a different medium from the sans-serif task UI below.

    /// Serif reading face for detail body copy, distinguishing document content from the task UI.
    private static let bodyFont = Font.system(size: 13, design: .serif)

    private func readContent(_ n: ProjectNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The summary is the lede: no label, set larger, it opens the brief.
            if !n.summary.isBlank {
                Text(n.summary)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            proseBlock("Problem", n.problem)
            numberedBlock("Goals", n.goals)
            proseBlock("Approach", n.approach)
            LinksBlock(links: n.links)
            bulletBlock("Learnings", n.learnings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func proseBlock(_ title: String, _ body: String) -> some View {
        if !body.isBlank {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                Text(body)
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func numberedBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.enumerated().filter { !$0.element.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.offset) { idx, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Hanging figure: numerals in a fixed-width gutter so the copy aligns.
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .serif))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 14, alignment: .trailing)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.filter { !$0.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("—").font(Self.bodyFont).foregroundStyle(.tertiary)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// An editorial section label: uppercase, letter-spaced, tertiary — a quiet "eyebrow" above detail
/// copy. Shared by the read view, the Links block, and the details editor so all three read alike.
private struct Eyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(.tertiary)
    }
}

/// The editable detail fields, gathered on Save. Links, title, and sessions are intentionally left
/// out — the store re-merges these onto freshly-parsed notes so they're preserved untouched.
private struct EditedDetails {
    var summary: String
    var problem: String
    var goals: [String]
    var approach: String
    var learnings: [String]
}

/// Inline edit form for the project-details section. Shows every editable section (Summary, Problem,
/// Goals×3, Approach, Learnings) regardless of whether it currently has content, plus the read-only
/// Links block for context. Seeded from the notes on appear; local `@State` so Cancel is a no-op.
private struct DetailsEditor: View {
    let onSave: (EditedDetails) -> Void
    let onCancel: () -> Void

    @State private var summary: String
    @State private var problem: String
    @State private var goals: [String]        // exactly 3 slots
    @State private var approach: String
    @State private var learningsText: String  // one learning per line
    private let links: [LinkEntry]

    init(notes: ProjectNotes, onSave: @escaping (EditedDetails) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.links = notes.links
        _summary = State(initialValue: notes.summary)
        _problem = State(initialValue: notes.problem)
        _goals = State(initialValue: Array((notes.goals + ["", "", ""]).prefix(3)))
        _approach = State(initialValue: notes.approach)
        _learningsText = State(initialValue: notes.learnings
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Summary") { TextField("", text: $summary, axis: .vertical).lineLimit(1...5) }
            field("Problem") { TextField("", text: $problem, axis: .vertical).lineLimit(1...5) }
            field("Goals") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        TextField("Goal \(i + 1)", text: $goals[i])
                    }
                }
            }
            field("Approach") { TextField("", text: $approach, axis: .vertical).lineLimit(1...5) }
            LinksBlock(links: links)
            field("Learnings") {
                TextField("One per line", text: $learningsText, axis: .vertical).lineLimit(2...8)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(title)
            content()
        }
    }

    private func save() {
        let learnings = learningsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(EditedDetails(
            summary: summary,
            problem: problem,
            goals: goals,
            approach: approach,
            learnings: learnings.isEmpty ? [""] : learnings
        ))
    }
}

private struct LinksBlock: View {
    let links: [LinkEntry]

    private var usable: [LinkEntry] {
        links.filter { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Links")
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
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
