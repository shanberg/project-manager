import SwiftUI
import AppKit
import PmLib

/// The focus panel's content: which project you're in, the task you're on, and the one after it.
///
/// This is the app reduced to a single question — "what am I doing right now" — the way a media app's
/// mini player reduces to the track that's playing. It reads the globally focused project rather than
/// owning one, so it always agrees with the menubar item, the CLI and Raycast about what's current.
///
/// It is small on purpose. There's no task list, no project sidebar, no details brief and no session
/// notes: those are the project window's job, and the arrow in the top right is how you get there.
/// What it *does* carry is every action the task itself needs — complete, navigate, edit, add around
/// it, set a due date, delete — so working through a short run of tasks never needs the big window.
struct FocusPanelView: View {
    @ObservedObject var store: PMStore
    /// Escape with nothing left to unwind hides the panel.
    var onDismiss: () -> Void = {}
    /// Measured content height, for the window's auto-fit.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// Open (or focus) the full project window for whatever project is showing.
    var onOpenProject: () -> Void = {}
    /// Ask the panel for key focus, for the moments this content has the keyboard to use — an editor
    /// open, or a delete waiting on ⏎/Escape. The panel doesn't take key just for being clicked (see
    /// `KeyablePanel`), so without this an editor opened here would get no keystrokes.
    var onNeedsKeyboard: () -> Void = {}

    /// The open inline editor, if any. Only one at a time, exactly as in the task list.
    @State private var activeEditor: EditorTarget?
    /// Which position a freshly-opened add editor seeds to, set by the card's context-menu Add actions
    /// before the editor opens. There's one task on screen, so one value suffices — the task list has
    /// to track this per row.
    @State private var addPosition: TaskInsertPosition = .child
    /// Tasks awaiting the inline delete confirmation. Empty when no delete is pending.
    @State private var pendingDelete: [Todo] = []
    /// True while the "nothing focused" state has opened its add editor. Separate from `activeEditor`,
    /// which keys on a task — there isn't one here, which is the whole point of the state.
    @State private var addingTask = false
    /// Cancels an open editor when the user clicks outside it.
    @StateObject private var outsideClick = OutsideClickMonitor()

    /// Shared with the project window: the appearance override is an app-wide preference, not a
    /// per-surface one.
    @AppStorage("PMPanelColorMode") private var colorMode: AppColorMode = .system

    /// The task the card centers on: the truly focused todo if there is one, else the first open task
    /// so the panel still has something to show.
    private var hero: Todo? { store.focusedTodo ?? store.openTodos.first }

    private var isEditing: Bool { activeEditor != nil || addingTask }

    /// Whether the panel's content currently has a use for the keyboard: an open editor to type into,
    /// or a delete confirmation waiting on ⏎/Escape.
    private var needsKeyboard: Bool { isEditing || !pendingDelete.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectBar
            Divider()
            if store.projectName == nil {
                emptyState
            } else if let hero {
                card(hero)
            } else {
                nothingFocused
            }
            deleteConfirmation
        }
        .frame(width: ProjectWindow.focusPanelWidth, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.preference(key: FocusHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(FocusHeightKey.self) { onContentHeight($0) }
        .preferredColorScheme(colorMode.colorScheme)
        // The window is borderless, so this material *is* the panel's shape — it rounds its own corners
        // and the window's shadow follows from it.
        .background { GlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: ProjectWindow.cornerRadius, style: .continuous))
        // The content is meant to run to the window's own edges; without this the hosting controller
        // insets it below an absent titlebar and the measured height comes up short.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy, value: activeEditor)
        .animation(.snappy, value: addingTask)
        .animation(.snappy, value: pendingDelete.isEmpty)
        .onPreferenceChange(ActiveEditorFrameKey.self) { outsideClick.editorFrame = $0 }
        .background(WindowAccessor { outsideClick.window = $0 })
        .onExitCommand(perform: handleEscape)
        .background(shortcuts)
        // A different project's tasks are behind the same keys, so an open editor would point at the
        // wrong task once focus moves on.
        .onChange(of: store.projectKey) { _ in
            activeEditor = nil
            addingTask = false
            pendingDelete = []
        }
        // Only ever asks *for* the keyboard, never gives it back: the panel resigning key is the user
        // clicking into another window, and closing an editor here shouldn't move focus off the panel
        // they're still working in.
        .onChange(of: needsKeyboard) { if $0 { onNeedsKeyboard() } }
        .onChange(of: isEditing) { active in
            if active {
                outsideClick.onOutsideClick = {
                    activeEditor = nil
                    addingTask = false
                }
                outsideClick.start()
            } else {
                outsideClick.stop()
            }
        }
        .onDisappear { outsideClick.stop() }
    }

    // MARK: Project bar

    /// Which project this is, and the way out to the full window.
    ///
    /// It earns its place precisely *because* the panel follows the global focus: without a name, a
    /// panel that quietly re-pointed when you brought another project's window forward would be showing
    /// you a task with no way to tell whose it is.
    private var projectBar: some View {
        HStack(spacing: 6) {
            let p = store.progress
            Image(nsImage: MenubarRing.image(fraction: p.total > 0 ? Double(p.done) / Double(p.total) : 0,
                                             hasProject: p.total > 0, tint: nil))
                .renderingMode(.template)
                .foregroundStyle(.secondary)
            projectSwitcher
            Spacer(minLength: 4)
            if p.total > 0 {
                Text("\(p.done)/\(p.total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button(action: onOpenProject) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the project window")
            .background(WindowDragExcluder())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The project name, with the recents menu behind it. Switching here sets the app's focused project
    /// — which is the honest way to change what a focus-following panel shows.
    private var projectSwitcher: some View {
        Menu {
            if store.recents.isEmpty {
                Text("No other projects")
            } else {
                ForEach(store.recents, id: \.projectKey) { recent in
                    Button {
                        store.setFocusedProject(key: recent.projectKey)
                    } label: {
                        // Native menus render a single line, so the focused task rides after the name.
                        Text(recent.name)
                            + Text(recent.focusedText.map { "  —  \($0.truncated(40))" } ?? "")
                    }
                }
            }
        } label: {
            Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(WindowDragExcluder())
        .help("Switch project")
    }

    // MARK: The card

    /// The focused task: its ancestor breadcrumb, the completable line itself, and a dim tappable
    /// "Next". Right-clicking anywhere in it opens the same menu a task row offers, and the
    /// input-driven actions open inline editors in place around the task, so the panel is fully
    /// actionable rather than a read-only readout.
    private func card(_ hero: Todo) -> some View {
        let key = PMStore.key(for: hero)
        let isEditingText = activeEditor == EditorTarget(key: key, kind: .edit)
        let isEditingDue = activeEditor == EditorTarget(key: key, kind: .due)
        let isAdding = activeEditor == EditorTarget(key: key, kind: .add)
        let isWrapping = activeEditor == EditorTarget(key: key, kind: .wrap)

        return VStack(alignment: .leading, spacing: 12) {
            // Editors whose new row lands ABOVE the task: wrap (the new parent) and Add Before.
            if isWrapping {
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap",
                                 leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text in
                    store.wrap(hero, parentText: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && addPosition == .before {
                addEditor(hero)
            }

            // The display (breadcrumb + task line) — or, while editing its text, an in-place editor.
            // The display carries the movement animation: keyed by the task's identity + text, it
            // transitions whenever the store reports a classified move, so navigating tasks slides
            // directionally and an in-place edit wipes.
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

            // Editors whose row/edit lands BELOW: due edit, Add After (sibling), Add Subtask.
            if isEditingDue {
                DueEditor(seed: String((hero.dueDate ?? hero.effectiveDueDate ?? "").prefix(10)),
                          leadingIcon: AnyView(TaskStatusIcon(checked: hero.checked, size: heroIconSize))) { newDue in
                    store.setDue(hero, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && (addPosition == .after || addPosition == .child) {
                addEditor(hero)
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
                .background(WindowDragExcluder())
                .help("Focus this task")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // Drive the transition off the store's move token: only a real, classified change animates
        // (incidental reloads leave the token untouched), and the direction/curve match it.
        .animation(heroAnimation(for: store.focusMove), value: store.focusMoveToken)
        // Contain the sliding task within the card so a directional push doesn't bleed into the
        // project bar or the Next line.
        .clipped()
        // The whole card represents the active task, so a right-click anywhere in it — not just on the
        // task line — opens the task menu. Inline editors still show the field's own menu.
        .contentShape(Rectangle())
        .contextMenu {
            TaskMenu(todo: hero, store: store,
                     openEditor: { openEditor($0, for: hero) },
                     openAdd: { openAdd($0, for: hero) },
                     onDelete: { requestDelete($0) })
        }
    }

    /// The task's checkbox size, shared with its inline editors so the status glyph keeps the same
    /// identity in view and edit modes.
    private var heroIconSize: CGFloat { 18 }

    /// The static presentation — breadcrumb above the completable line — as one unit, so a movement
    /// transition slides the whole identity (context included), not just the text.
    private func heroDisplay(_ hero: Todo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let crumb = store.breadcrumb(for: hero) {
                Text(crumb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            heroLine(hero)
        }
    }

    /// The completable line: a large checkbox, the task's text, and (when dated) a read-only due chip.
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
            .background(WindowDragExcluder())

            VStack(alignment: .leading, spacing: 6) {
                Text(hero.text)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(hero.checked, color: .secondary)
                    .foregroundStyle(hero.checked ? .secondary : .primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if hero.dueDate != nil || hero.effectiveDueDate != nil {
                    staticDueChip(hero)
                }
            }
        }
    }

    /// Identity for the transition: the task key plus its text, so both navigating to a different task
    /// (key changes) and editing the current one in place (text changes) swap identity and animate,
    /// while incidental changes (due, indent) update in place.
    private func heroSignature(_ hero: Todo) -> String { "\(PMStore.key(for: hero))|\(hero.text)" }

    /// The transition for a change: a directional push whose incoming edge matches the direction of
    /// travel, or an in-place wipe for a text edit.
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

    /// The curve for a change — a quick snappy slide for spatial moves, a smooth ease for a wipe.
    private func heroAnimation(for move: FocusMove) -> Animation {
        move == .wipe ? .easeInOut(duration: 0.3) : .snappy(duration: 0.32)
    }

    /// Read-only due-date chip (editing goes through the context menu's Set Due Date). Own dates read
    /// solid orange; an inherited date reads dashed and secondary, matching the task list's chip.
    private func staticDueChip(_ todo: Todo) -> some View {
        let own = todo.dueDate
        let raw = own ?? todo.effectiveDueDate ?? ""
        let color: Color = own != nil ? .orange : .secondary
        return Text(RelativeDue.short(raw))
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: own != nil ? [] : [3]))
            )
            .foregroundStyle(color)
            // The exact date the badge stands for. Read-only here, so the tooltip is the only place
            // it's available at all.
            .help(own != nil ? "Due \(RelativeDue.full(raw))"
                             : "Inherited due \(RelativeDue.full(raw))")
    }

    // MARK: Editors

    /// The positional add editor. Its slot (above/below) is chosen by the caller from `addPosition`.
    private func addEditor(_ hero: Todo) -> some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text, due in
            store.addTodo(text: text, due: due, relativeTo: hero, position: addPosition)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
            .reportEditorFrame()
    }

    /// Open (never toggle) the given editor kind on the focused task.
    private func openEditor(_ kind: EditorTarget.Kind, for hero: Todo) {
        activeEditor = EditorTarget(key: PMStore.key(for: hero), kind: kind)
    }

    /// Seed the add position, then open the add editor.
    private func openAdd(_ position: TaskInsertPosition, for hero: Todo) {
        addPosition = position
        openEditor(.add, for: hero)
    }

    // MARK: Delete

    private func requestDelete(_ todos: [Todo]) {
        guard !todos.isEmpty else { return }
        activeEditor = nil
        pendingDelete = todos
    }

    /// The inline delete confirmation. It lives inside the panel rather than in an alert: a separate
    /// modal window would take key focus away from a panel that's deliberately non-activating, and the
    /// subtasks that ride along with a delete are the part you can't see from the one task on screen.
    /// Return deletes, Escape cancels.
    @ViewBuilder private var deleteConfirmation: some View {
        if !pendingDelete.isEmpty {
            let summary = store.deletionSummary(pendingDelete)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.tasks == 1 && !pendingDelete.isEmpty
                         ? "Delete “\(pendingDelete[0].text.truncated(48))”?"
                         : "Delete \(summary.tasks) tasks?")
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.descendants > 0 {
                        Text("Also deletes \(summary.descendants) subtask\(summary.descendants == 1 ? "" : "s").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { pendingDelete = [] }
                    Button("Delete", role: .destructive) {
                        store.deleteTasks(pendingDelete)
                        pendingDelete = []
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .background(WindowDragExcluder())
        }
    }

    // MARK: Empty states

    /// Everything in this project is done. Rather than a dead end, this is the one moment where the
    /// obvious next move is to add something — so the panel offers it here instead of sending you to
    /// the project window for a one-line task.
    @ViewBuilder private var nothingFocused: some View {
        if addingTask {
            AddEditor(leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text, due in
                // No anchor: with nothing focused there's nothing to position against, so this appends
                // to the project's current session the way the menubar's Add does.
                store.addTodo(text: text, due: due)
                addingTask = false
            } onCancel: { addingTask = false }
                .reportEditorFrame()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .center, spacing: 8) {
                VStack(spacing: 3) {
                    Text("Nothing focused").font(.subheadline).foregroundStyle(.secondary)
                    Text("All tasks complete").font(.caption).foregroundStyle(.tertiary)
                }
                Button { addingTask = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .controlSize(.small)
                .background(WindowDragExcluder())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(store.errorMessage ?? "No focused project").font(.subheadline).foregroundStyle(.secondary)
            Text("Pick one from the menu above").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: Keyboard

    /// The panel's shortcuts, as hidden zero-size buttons so they bind only while it's key.
    ///
    /// ⏎ completes the task — the one keystroke this surface exists for. ⌃⌥P puts the panel up and
    /// makes it key, so "show me what I'm on, tick it off, get out of the way" is three keys without
    /// ever reaching for the mouse.
    private var shortcuts: some View {
        Group {
            Button("Complete") { if let hero { store.complete(hero) } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(hero == nil || isEditing || !pendingDelete.isEmpty)
            Button("Dive In", action: store.diveIn)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.nextTodo == nil || isEditing)
            Button("Undo", action: store.undo)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button("Redo", action: store.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
            Button("Copy") {
                if let hero { TaskPasteboard.copy(markdown: store.markdown(for: [hero])) }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(hero == nil || isEditing)
        }
        .hidden()
    }

    /// Escape unwinds one layer at a time — the pending delete, then an open editor — and only hides
    /// the panel once there's nothing left to back out of.
    private func handleEscape() {
        if !pendingDelete.isEmpty {
            pendingDelete = []
        } else if addingTask {
            addingTask = false
        } else if activeEditor != nil {
            activeEditor = nil
        } else {
            onDismiss()
        }
    }
}

/// The panel's natural content height, which the window auto-fits to.
private struct FocusHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
