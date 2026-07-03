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
    /// Which position a freshly-opened add editor should seed to in focused mode (set by the focused
    /// card's context-menu Add actions before opening the editor). The task list tracks this per-row.
    @State private var focusedAddPosition: TaskInsertPosition = .child
    /// True while the empty-project CTA has revealed its inline add editor (for the very first task).
    @State private var addingFirstTask = false
    /// Tracks the ⌥ key so the Open button can swap between Obsidian and Finder live, like the menu.
    @StateObject private var modifiers = ModifierMonitor()
    /// Cancels an open editor when the user clicks outside it (see `OutsideClickMonitor`).
    @StateObject private var outsideClick = OutsideClickMonitor()

    /// True whenever some inline editor (a task row's, or the project-details form) is open.
    private var isAnyEditorActive: Bool { activeEditor != nil || editingDetails }

    /// True while the project-details section is rendered directly below the header. Drives the
    /// header/divider spacing so the details read as a continuation of the title, not a fenced pane.
    private var detailsShowing: Bool { store.projectName != nil && detailsExpanded }

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
                    if detailsExpanded {
                        ProjectDetailsView(notes: store.notes, store: store, isEditing: $editingDetails)
                    }
                    // While editing details, hide everything below so the form stands alone.
                    if !editingDetails {
                        // A project with no tasks at all gets a plain, emoji-free empty state with an
                        // add CTA — the "all complete 🎉" copy would be wrong (nothing was completed)
                        // and neither section has an obvious way to add the first task.
                        if store.todos.isEmpty {
                            emptyProjectTasks
                        } else if tasksMode == .focused {
                            focusedSection
                        } else {
                            tasksSection
                        }
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
        .onChange(of: store.projectName) { _ in editingDetails = false; addingFirstTask = false }
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
            // Title (double-click toggles the details brief) with the switcher arrow tucked after it.
            HStack(spacing: 4) {
                projectTitle
                projectSwitcherMenu
            }
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
        // Double-click empty header space (or the title) toggles the details brief. On a background
        // layer *behind* the controls so the switcher / view-options / open buttons in front consume
        // their own clicks and are excluded; `simultaneousGesture` so it still coexists with
        // drag-by-window-background.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if store.projectName != nil { detailsExpanded.toggle() }
                })
        )
        // Right-clicking anywhere in the header opens the same view settings as the slider button.
        .contextMenu { viewOptionsMenuContent }
    }

    /// The project title. Plain text — the details-toggle double-click lives on the header background
    /// behind it, and the switcher lives on the adjacent arrow, so the title itself carries no gesture.
    private var projectTitle: some View {
        Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project")
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The project switcher: a subtle chevron after the title (the macOS navigation-title / document-
    /// title idiom). Opening it lists the recent projects — each with the same completion ring the
    /// menubar draws — then "All projects…" to Raycast's searchable list for anything beyond recents.
    /// Present even with no focused project, so you can switch in from the empty state. Reads
    /// `store.recents`, warmed off-thread and shared with the menubar's switcher.
    private var projectSwitcherMenu: some View {
        Menu {
            if store.recents.isEmpty {
                Text("No recent projects").font(.caption)
            } else {
                ForEach(store.recents) { recent in
                    Button {
                        store.setFocusedProject(key: recent.projectKey)
                    } label: {
                        Label {
                            // Native menus render a single line, so the focused task rides after the
                            // name as a dimmed fragment rather than a true second line.
                            Text(recent.name)
                                + Text(recent.focusedText.map { "  —  \($0.truncated(48))" } ?? "")
                                    .foregroundColor(.secondary)
                        } icon: {
                            Image(nsImage: MenubarRing.image(fraction: recent.fraction,
                                                             hasProject: recent.total > 0, tint: nil))
                        }
                    }
                }
            }
            Divider()
            Button {
                if let url = URL(string: "raycast://extensions/shanberg/project-manager/list-projects") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("All projects…", systemImage: "magnifyingglass")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch project")
    }

    /// Whether the view is in any non-default state (mode other than incomplete, or details showing),
    /// used to tint the view-options icon so there's a subtle "customized" cue.
    private var isViewCustomized: Bool {
        tasksMode != .incomplete || detailsExpanded || colorMode != .system
    }

    /// Single header menu holding all view state: the tasks-mode picker (Focused / Incomplete / All)
    /// and a "Show details" toggle (always available, so details can be added to a project that has
    /// none). Replaces the old "Details" text button and the tasks-list "Show all" checkbox,
    /// consolidating both axes in one HIG-native place.
    private var viewOptionsMenu: some View {
        Menu {
            viewOptionsMenuContent
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

    /// The view-options items — the tasks-mode picker, the "Show details" toggle, and the appearance
    /// picker. Shared by the header's slider button and the header's right-click menu, so right-clicking
    /// anywhere in the header surfaces the same view settings.
    @ViewBuilder private var viewOptionsMenuContent: some View {
        Picker("Tasks", selection: $tasksMode) {
            Label("Focused", systemImage: "scope").tag(TasksMode.focused)
            Label("Incomplete", systemImage: "circle").tag(TasksMode.incomplete)
            Label("All", systemImage: "list.bullet").tag(TasksMode.all)
        }
        .pickerStyle(.inline)
        Divider()
        Toggle(isOn: $detailsExpanded) { Label("Show details", systemImage: "info.circle") }
        Divider()
        Picker("Appearance", selection: $colorMode) {
            Label("System", systemImage: "circle.lefthalf.filled").tag(PanelColorMode.system)
            Label("Light", systemImage: "sun.max").tag(PanelColorMode.light)
            Label("Dark", systemImage: "moon").tag(PanelColorMode.dark)
        }
        .pickerStyle(.inline)
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
    /// the menubar's "Open in Obsidian / ⌥ Open in Finder" alternate. The ⌥ swap is suppressed while a
    /// text editor is open, where ⌥ is used for typing and the flicker is just distracting.
    private var openButton: some View {
        let finder = modifiers.optionDown && !isAnyEditorActive
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

    /// Shown when the focused project has no tasks at all. Deliberately emoji-free (unlike the
    /// "all complete" states, which imply work was finished) and centered on a single add CTA that
    /// reveals an inline editor for the very first task.
    @ViewBuilder private var emptyProjectTasks: some View {
        VStack(spacing: 10) {
            if addingFirstTask {
                AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
                    store.addTodo(text: text, due: due)
                    addingFirstTask = false
                } onCancel: { addingFirstTask = false }
                    .padding(.horizontal, 12)
            } else {
                Text("No tasks yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    addingFirstTask = true
                } label: {
                    Label("Add a task", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .animation(.snappy, value: addingFirstTask)
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
                Text(tasksMode == .all ? "No tasks yet" : "All tasks complete")
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
            focusedCard(hero)
        } else {
            VStack(alignment: .center, spacing: 6) {
                Text("Nothing focused").font(.subheadline).foregroundStyle(.secondary)
                Text("All tasks complete").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// The focused hero card. Right-clicking the hero opens the same `TaskMenu` as a list row; the
    /// input-driven actions (edit / add / wrap / due) open inline editors in place around the hero,
    /// mirroring the task list's per-row editing so focused mode is fully actionable, not read-only.
    private func focusedCard(_ hero: Todo) -> some View {
        let key = PMStore.key(for: hero)
        let isEditingText = activeEditor == EditorTarget(key: key, kind: .edit)
        let isEditingDue = activeEditor == EditorTarget(key: key, kind: .due)
        let isAdding = activeEditor == EditorTarget(key: key, kind: .add)
        let isWrapping = activeEditor == EditorTarget(key: key, kind: .wrap)

        return VStack(alignment: .leading, spacing: 12) {
            // Editors whose new row lands ABOVE the hero: wrap (the new parent) and Add Before.
            if isWrapping {
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap",
                                 leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text in
                    store.wrap(hero, parentText: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && focusedAddPosition == .before {
                focusedAddEditor(hero)
            }

            // The hero display (breadcrumb + task line) — or, while editing its text, an in-place
            // editor. The display carries the movement animation: keyed by the task's identity + text,
            // it transitions whenever the store reports a classified move (see `.animation` below), so
            // navigating tasks slides directionally and an in-place edit wipes.
            if isEditingText {
                InlineTextEditor(seed: hero.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: hero.checked, size: heroIconSize))) { text in
                    store.editText(hero, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            } else {
                heroDisplay(hero)
                    .id(heroSignature(hero))
                    .transition(heroTransition(for: store.focusMove))
            }

            // Editors whose row/edit lands BELOW the hero: due edit, Add After (sibling), Add Subtask.
            if isEditingDue {
                DueEditor(seed: String((hero.dueDate ?? hero.effectiveDueDate ?? "").prefix(10)),
                          leadingIcon: AnyView(TaskStatusIcon(checked: hero.checked, size: heroIconSize))) { newDue in
                    store.setDue(hero, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && (focusedAddPosition == .after || focusedAddPosition == .child) {
                focusedAddEditor(hero)
            }

            // The dim "Next" line, hidden while editing so the card stays calm in edit mode.
            if activeEditor == nil, let next = store.nextTodo, next != hero {
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
        // Drive the hero transition off the store's move token: only a real, classified change
        // animates (incidental reloads leave the token untouched), and the direction/curve match it.
        .animation(heroAnimation(for: store.focusMove), value: store.focusMoveToken)
        // Contain the sliding hero within the card so a directional push doesn't bleed into the header
        // or the Next line.
        .clipped()
        // The whole focused card represents the active task, so a right-click anywhere in it — not
        // just on the hero line — opens the task menu. `contentShape` makes the padding/empty area
        // hit-testable too. Inline editors still show the field's own copy/paste menu on right-click.
        .contentShape(Rectangle())
        .contextMenu {
            TaskMenu(todo: hero, store: store,
                     openEditor: { openFocusedEditor($0, for: hero) },
                     openAdd: { openFocusedAdd($0, for: hero) })
        }
        .animation(.snappy, value: activeEditor)
    }

    /// The focused hero's checkbox size, shared with its inline editors so the status glyph keeps the
    /// same identity in view and edit modes.
    private var heroIconSize: CGFloat { 18 }

    /// The hero's static presentation — the ancestor breadcrumb above its completable line — as one
    /// unit, so a movement transition slides the whole identity (context included), not just the text.
    private func heroDisplay(_ hero: Todo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let crumb = breadcrumb(for: hero) {
                Text(crumb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            heroLine(hero)
        }
    }

    /// Identity for the hero display's transition: the task key plus its text, so both navigating to a
    /// different task (key changes) and editing the current one in place (text changes) swap identity
    /// and animate, while incidental changes (due, indent) update in place.
    private func heroSignature(_ hero: Todo) -> String { "\(PMStore.key(for: hero))|\(hero.text)" }

    /// The transition for a hero change: a directional push whose incoming edge matches the direction
    /// of travel, or an in-place wipe for a text edit.
    private func heroTransition(for move: FocusMove) -> AnyTransition {
        switch move {
        case .right: return .cornerPush(horizontal: .trailing, vertical: .bottom)  // dove into a subtask → down-right
        case .left:  return .cornerPush(horizontal: .leading,  vertical: .top)     // bubbled up to an ancestor → up-left
        case .down:  return .cornerPush(horizontal: nil,       vertical: .bottom)  // next → rises up from below
        case .up:    return .cornerPush(horizontal: nil,       vertical: .top)     // previous → drops down from above
        case .wipe:  return .wipe
        case .none:  return .identity
        }
    }

    /// The curve for a hero change — a quick snappy slide for spatial moves, a smooth ease for a wipe.
    private func heroAnimation(for move: FocusMove) -> Animation {
        move == .wipe ? .easeInOut(duration: 0.3) : .snappy(duration: 0.32)
    }

    /// The hero's completable line: a large checkbox, its text, and (when dated) a read-only due chip.
    private func heroLine(_ hero: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: { store.toggle(hero) }) {
                Image(systemName: hero.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: heroIconSize))
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
    }

    /// The positional add editor for the focused card. Its slot (above/below) is chosen by the caller
    /// from `focusedAddPosition`, matching the task list's previewed insert position.
    private func focusedAddEditor(_ hero: Todo) -> some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text, due in
            store.addTodo(text: text, due: due, relativeTo: hero, position: focusedAddPosition)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
            .reportEditorFrame()
    }

    /// Open (never toggle) the given editor kind on the focused hero — used by its context menu.
    private func openFocusedEditor(_ kind: EditorTarget.Kind, for hero: Todo) {
        activeEditor = EditorTarget(key: PMStore.key(for: hero), kind: kind)
    }

    /// Seed the focused add position, then open the add editor on the hero.
    private func openFocusedAdd(_ position: TaskInsertPosition, for hero: Todo) {
        focusedAddPosition = position
        openFocusedEditor(.add, for: hero)
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

// MARK: Hero edit transition (in-place wipe)

/// A soft, feathered mask reveal used when a task's text is edited in place. Editing isn't a spatial
/// event, so this deliberately avoids the directional slide of a navigation: a gently feathered edge
/// sweeps the new text in while it also crossfades (see `AnyTransition.wipe`), reading as the text
/// refreshing/shimmering in place rather than moving. Alpha-only, so it's correct in light and dark.
struct WipeModifier: ViewModifier, Animatable {
    /// 0 = fully masked (hidden), 1 = fully revealed.
    var animatableData: CGFloat

    /// Width of the soft reveal edge, as a fraction of the content — wide enough to read as a shimmer
    /// rather than a hard wipe line.
    private let feather: CGFloat = 0.35

    func body(content: Content) -> some View {
        let p = animatableData
        content.mask(
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: p),
                        .init(color: .clear, location: min(1, p + feather)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
    }
}

extension AnyTransition {
    /// The in-place edit transition: a feathered mask wipe crossfaded with opacity, so an edit dissolves
    /// and shimmers in place instead of sliding like a move.
    static var wipe: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .modifier(
                active: WipeModifier(animatableData: 0),
                identity: WipeModifier(animatableData: 1))),
            removal: .opacity
        )
    }

    /// A `push`-style slide that can travel diagonally. The built-in `.push(from:)` only moves along a
    /// single edge, but task-focus moves are usually diagonal: diving into a subtask travels
    /// down-and-right (the child is both deeper and further down the outline), and a completion bubbling
    /// up to a sibling-less ancestor travels up-and-left. `horizontal` and `vertical` name the edges the
    /// *incoming* content enters from (either may be nil for a purely vertical or horizontal move); the
    /// outgoing content leaves toward the opposite corner. Crossfaded so it reads like `.push`, and
    /// size-proportional (built from `.move`), so it scales to whatever it animates.
    static func cornerPush(horizontal: Edge?, vertical: Edge?) -> AnyTransition {
        func opposite(_ e: Edge) -> Edge {
            switch e {
            case .leading:  return .trailing
            case .trailing: return .leading
            case .top:      return .bottom
            case .bottom:   return .top
            }
        }
        var insertion: AnyTransition = .opacity
        var removal: AnyTransition = .opacity
        for edge in [horizontal, vertical].compactMap({ $0 }) {
            insertion = insertion.combined(with: .move(edge: edge))
            removal = removal.combined(with: .move(edge: opposite(edge)))
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }
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
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap",
                                 leadingIcon: AnyView(TaskStatusIcon())) { text in
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
                InlineTextEditor(seed: todo.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked))) { text in
                    store.editText(todo, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            } else {
                taskLine
                    .padding(.leading, indent(todo.depth + ancestorWrapBoost + (isWrapping ? 1 : 0)))
                    .contextMenu { TaskMenu(todo: todo, store: store, openEditor: openEditor, openAdd: openAdd) }
            }

            // Forms whose row/edit lands BELOW this one: due edit, Add After (sibling), Add Subtask
            // (one level deeper).
            if isEditingDue {
                DueEditor(seed: dueSeed, leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked))) { newDue in
                    store.setDue(todo, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
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
        AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
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
}

/// Right-click actions for a task, mirroring the hover controls plus completion/focus. Idiomatic
/// macOS per-task affordance: keyboard- and VoiceOver-accessible, and keeps the surface visually
/// clean. Shared by the task list rows and the focused-mode hero card so both offer the same menu.
/// Wording follows the rest of the app: the add positions match `AddEditor`'s Before/Subtask/After
/// picker (and Raycast's "Add Before"/"Add After"), due wording matches Raycast's "Set Due Date"/
/// "Remove Due Date", and an ellipsis marks actions that open a further input editor (as the
/// menubar does).
private struct TaskMenu: View {
    let todo: Todo
    @ObservedObject var store: PMStore
    /// Open (never toggle) the given editor kind on this task.
    let openEditor: (EditorTarget.Kind) -> Void
    /// Seed the add position, then open the add editor.
    let openAdd: (TaskInsertPosition) -> Void

    var body: some View {
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
        // Only a parent can be dissolved — an immediate action (no further input), so no ellipsis.
        if store.hasChildren(todo) {
            Button { store.unwrap(todo) } label: {
                Label("Unwrap", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        Divider()
        Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
        if todo.dueDate != nil {
            Button { store.setDue(todo, due: nil) } label: { Label("Remove Due Date", systemImage: "calendar.badge.minus") }
        }
    }
}

// MARK: Task status icon

/// A task's leading status glyph — an open circle, or a filled check when done. The inline editors
/// (edit / add / wrap / due) render it alongside their input so a task keeps the same visual identity
/// while it's being modified or created that it has as a normal row. `size` matches the surrounding
/// context (nil = the list row's default body size; the focused hero passes its larger 18pt). A
/// brand-new task (add / wrap) reads as an empty circle, since it isn't complete yet.
private struct TaskStatusIcon: View {
    var checked: Bool = false
    var size: CGFloat? = nil

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(size.map { Font.system(size: $0) } ?? .body)
            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            .symbolReplaceIfAvailable()
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
        // Always laid out so hovering only toggles opacity, never the row's height. A real own/
        // inherited date is content (always visible); the empty-state "＋date" is a control that
        // fades in on hover/edit but keeps reserving its space.
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
        .opacity(hasDate || reveal || isEditing ? 1 : 0)
        .allowsHitTesting(hasDate || reveal || isEditing)
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
    /// Optional leading status glyph, so the task keeps its identity while its due date is edited.
    let leadingIcon: AnyView?
    let onSet: (String?) -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(seed: String, leadingIcon: AnyView? = nil,
         onSet: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.seed = seed
        self.leadingIcon = leadingIcon
        self.onSet = onSet
        self.onCancel = onCancel
        _date = State(initialValue: DueFormat.parse(seed) ?? Date())
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon { leadingIcon }
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
    /// Optional leading status glyph (an empty circle for the not-yet-created task), so the new task
    /// reads with the same visual identity as a real row while it's being typed.
    var leadingIcon: AnyView? = nil
    let onAdd: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var useDue = false
    @State private var date = Date()
    @FocusState private var textFocused: Bool

    var body: some View {
        // Icon leads the whole form, aligned to the text-field row; the controls below indent under
        // the field so the icon column stays clear, mirroring a task row's icon + text layout.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let leadingIcon { leadingIcon }
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
    /// Optional leading status glyph, so the task keeps its identity while its text is edited (the
    /// existing task's own checkbox state) or a wrap parent is named (an empty circle).
    let leadingIcon: AnyView?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(seed: String = "", placeholder: String, submitLabel: String, leadingIcon: AnyView? = nil,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.leadingIcon = leadingIcon
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon { leadingIcon }
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
                        // Merge the edited detail fields (including links) onto freshly-parsed notes,
                        // leaving title and sessions untouched.
                        store.saveDetails { fresh in
                            var out = fresh
                            out.summary = edited.summary
                            out.problem = edited.problem
                            out.goals = edited.goals
                            out.approach = edited.approach
                            out.links = edited.links
                            out.learnings = edited.learnings
                            return out
                        }
                        isEditing = false
                    } onCancel: {
                        isEditing = false
                    }
                    .reportEditorFrame()
                } else {
                    Group {
                        if hasAnyDetail(n) {
                            readContent(n)
                        } else {
                            placeholderContent
                        }
                    }
                    // Double-click anywhere in the details content switches to edit mode — including the
                    // empty placeholders, so a project with no details yet can gain them right here.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { isEditing = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// True when any detail block would render. When false (and not editing), the section shows empty
    /// placeholders instead of nothing, so a project with no details can still be given them here.
    private func hasAnyDetail(_ n: ProjectNotes) -> Bool {
        !n.summary.isBlank || !n.problem.isBlank
            || n.goals.contains { !$0.isBlank }
            || !n.approach.isBlank
            || n.links.contains { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
            || n.learnings.contains { !$0.isBlank }
    }

    /// The empty state: one quiet placeholder per editable section, so opening details on a project
    /// with none reveals what a brief can hold and gives the double-click-to-edit gesture a target.
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(["Summary", "Problem", "Goals", "Approach", "Links", "Learnings"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(title)
                    Text("Add \(title.lowercased())…")
                        .font(Self.bodyFont)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// The editable detail fields, gathered on Save. Title and sessions are intentionally left out — the
/// store re-merges these onto freshly-parsed notes so they're preserved untouched. Links are edited
/// here as a flat label/URL list; any nested link groups are preserved verbatim (see `DetailsEditor`).
private struct EditedDetails {
    var summary: String
    var problem: String
    var goals: [String]
    var approach: String
    var links: [LinkEntry]
    var learnings: [String]
}

/// One editable link row (label + URL). Backed by a stable `id` so add/remove keep field focus and
/// SwiftUI diffs the list correctly; converted to/from `LinkEntry` at the editor's edges.
private struct EditableLink: Identifiable {
    let id = UUID()
    var label: String
    var url: String
}

/// Inline edit form for the project-details section. Shows every editable section (Summary, Problem,
/// Goals×3, Approach, Links, Learnings) regardless of whether it currently has content. Seeded from
/// the notes on appear; local `@State` so Cancel is a no-op.
private struct DetailsEditor: View {
    let onSave: (EditedDetails) -> Void
    let onCancel: () -> Void

    @State private var summary: String
    @State private var problem: String
    @State private var goals: [String]        // exactly 3 slots
    @State private var approach: String
    @State private var links: [EditableLink]  // flat label/URL rows (grouped links preserved separately)
    @State private var learningsText: String  // one learning per line
    /// Nested link groups (a label with child URLs) aren't expressible in this compact flat form, so
    /// they're held aside verbatim and re-appended on save — the panel never destroys them.
    private let preservedGroups: [LinkEntry]

    init(notes: ProjectNotes, onSave: @escaping (EditedDetails) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        // Split the stored links: grouped entries are set aside; flat entries seed the editable rows
        // (dropping the empty placeholder entry the model carries when there are no real links).
        self.preservedGroups = notes.links.filter { !($0.children ?? []).isEmpty }
        _links = State(initialValue: notes.links
            .filter { ($0.children ?? []).isEmpty }
            .compactMap { entry in
                let label = (entry.label ?? "").trimmingCharacters(in: .whitespaces)
                let url = (entry.url ?? "").trimmingCharacters(in: .whitespaces)
                return (label.isEmpty && url.isEmpty) ? nil
                    : EditableLink(label: entry.label ?? "", url: entry.url ?? "")
            })
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
            field("Links") { linksEditor }
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

    /// The link rows plus an "Add link" affordance. A short Label field leads a wider URL field, with a
    /// trailing remove control per row — mirroring the Links read view's "label — url" shape.
    private var linksEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($links) { $link in
                HStack(spacing: 4) {
                    TextField("Label", text: $link.label).frame(width: 90)
                    TextField("URL", text: $link.url)
                    Button {
                        links.removeAll { $0.id == link.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove link")
                }
            }
            Button {
                links.append(EditableLink(label: "", url: ""))
            } label: {
                Label("Add link", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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
        // Drop blank rows, normalize each into a LinkEntry, then re-append the preserved groups. If the
        // result is empty, fall back to the model's single empty entry (matching a linkless project).
        let flatLinks: [LinkEntry] = links.compactMap { row in
            let label = row.label.trimmingCharacters(in: .whitespaces)
            let url = row.url.trimmingCharacters(in: .whitespaces)
            if label.isEmpty && url.isEmpty { return nil }
            return LinkEntry(label: label.isEmpty ? nil : label, url: url.isEmpty ? nil : url)
        }
        let mergedLinks = flatLinks + preservedGroups
        onSave(EditedDetails(
            summary: summary,
            problem: problem,
            goals: goals,
            approach: approach,
            links: mergedLinks.isEmpty ? [LinkEntry()] : mergedLinks,
            learnings: learnings.isEmpty ? [""] : learnings
        ))
    }
}

private struct LinksBlock: View {
    let links: [LinkEntry]

    private var usable: [LinkEntry] {
        links.filter {
            ($0.label ?? "").isEmpty == false
                || ($0.url ?? "").isEmpty == false
                || !($0.children ?? []).isEmpty
        }
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Links")
                ForEach(Array(usable.enumerated()), id: \.offset) { _, link in
                    if let children = link.children, !children.isEmpty {
                        linkGroup(link, children: children)
                    } else {
                        linkRow(link)
                    }
                }
            }
        }
    }

    /// A nested link group: its label as a quiet heading, then its child URLs as an indented list of
    /// clickable links. Editing groups isn't supported in the panel (they round-trip untouched).
    @ViewBuilder private func linkGroup(_ link: LinkEntry, children: [LinkEntry]) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                linkRow(child).padding(.leading, 10)
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
    func truncated(_ n: Int) -> String { count <= n ? self : String(prefix(n - 1)) + "…" }
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
