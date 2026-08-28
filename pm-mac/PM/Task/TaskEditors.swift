import PmLib
import SwiftUI

/// The inline editors a task is created and modified through, plus the status glyph that keeps a task
/// looking like itself while it's being edited.
///
/// Every one of these is opened from two places now — a row in the project window's task list, and the
/// focus panel's card — so they live here rather than inside either surface. They're deliberately
/// closure-driven and hold no store reference: the caller decides what a submission means, which is what
/// lets the same editor serve "edit this task", "name a new parent" and "label this session".

// MARK: Status glyph

/// A task's leading status glyph — an open circle, or a filled check when done. The inline editors
/// (edit / add / wrap / due) render it alongside their input so a task keeps the same visual identity
/// while it's being modified or created that it has as a normal row. `size` matches the surrounding
/// context (nil = the list row's default body size; the focus card passes its larger 18pt). A
/// brand-new task (add / wrap) reads as an empty circle, since it isn't complete yet.
struct TaskStatusIcon: View {
    var checked: Bool = false
    var size: CGFloat? = nil

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(size.map { Font.system(size: $0) } ?? .body)
            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            .symbolReplaceIfAvailable()
    }
}

// MARK: Due date

/// The relative answers a due-date menu offers before it offers a calendar.
///
/// Badges read "tomorrow" and "in 2w" (see `RelativeDue`), so an editor that demanded 08/25/2026 left
/// the user converting in both directions: the list says how far away, the editor asked which day.
/// These are the same language pointed the other way — the dates people actually pick, named the way
/// they'd say them, each carrying the day it resolves to so the name is never a guess.
///
/// The names and the days are `PmLib.duePresets`, shared with the parser that reads them back out of
/// a typed line. What's here is what a menu needs and a contract doesn't: an identity for the row and
/// the date spelled out beside the name.
enum DueSuggestion {
    struct Option: Identifiable {
        let id: String
        let title: String
        let date: Date

        /// "Wed, Aug 20" — what the title works out to, shown beside it.
        var hint: String { Option.hintFormatter.string(from: date) }

        private static let hintFormatter: DateFormatter = {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEE MMM d")
            return f
        }()
    }

    /// The menu's presets, in the order they're offered.
    static func options(now: Date = Date(), calendar: Calendar = .current) -> [Option] {
        duePresets(now: now, calendar: calendar).map {
            Option(id: $0.title, title: $0.title, date: $0.date)
        }
    }

}

/// The precise date picker — the "Pick a Date…" branch of the due menu, for an answer the presets
/// haven't got.
///
/// A calendar, not the `.field` stepper this used to be. The field was the only way to set a date at
/// all, so it had to serve both "next Tuesday" and "the 23rd"; now that the common answers are one
/// menu item away, the thing left over is browsing to a specific day, which is what a calendar is for.
struct DueEditor: View {
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
        HStack(alignment: .top, spacing: 6) {
            if let leadingIcon { leadingIcon }
            VStack(alignment: .leading, spacing: 6) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    // A graphical picker takes every point it's offered; left to itself it stretches
                    // the calendar across the whole column.
                    .fixedSize()
                HStack(spacing: 6) {
                    Button("Set") { onSet(DueFormat.string(date)) }
                        .keyboardShortcut(.defaultAction)
                    Button("Clear") { onSet(nil) }
                    Button("Cancel", action: onCancel)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Add editor

/// Text (+ optional due) entry for a new task. The insert position is chosen by the caller (via the
/// context menu / plus button) and previewed by where this form is placed in the row layout, so the
/// form no longer carries a position picker of its own.
struct AddEditor: View {
    /// Optional leading status glyph (an empty circle for the not-yet-created task), so the new task
    /// reads with the same visual identity as a real row while it's being typed.
    var leadingIcon: AnyView? = nil
    /// Open the project a `[[…]]` in the field names. Nil where the surface has nowhere to go.
    var onOpenProject: ((String) -> Void)?
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
                // The completing field, not a plain one: `@` names a project and `/` opens what a task
                // line can carry, exactly as in the note editor. This is where most tasks are actually
                // written, so it's the surface that most needs them.
                CompletingTextField(text: $text, placeholder: "Task text",
                                    onSubmit: submit, onCancel: onCancel,
                                    onOpenProject: onOpenProject)
                    .frame(height: 21)

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
        // Next runloop turn, not this one: an editor appears *during* the update that reveals it, and
        // a focus request made from inside that update is resolved against a view that isn't in the
        // responder chain yet — so it lands on nothing and the field opens without a caret.
        .onAppear { afterCurrentUpdate { textFocused = true } }
    }

    /// Commit one task and reset for the next one.
    ///
    /// The editor doesn't close itself — the caller decides whether there's a next task and where it
    /// goes, and closes the editor by clearing its own `activeEditor` if there isn't. So this resets
    /// unconditionally: if the caller *has* closed it, this runs on a view that's already leaving and
    /// costs nothing.
    ///
    /// The due date resets with the text. Carrying it forward would make a date set once stick to every
    /// task typed after it, and the loudest version of that bug is silent — a list of tasks that all
    /// quietly acquired Friday. One preset from the badge's menu puts it back.
    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, useDue ? DueFormat.string(date) : nil)
        text = ""
        useDue = false
        textFocused = true
    }
}

// MARK: Single-field inline editor (edit text / wrap)

/// A one-line text editor used for the row's "Edit Task" (seeded with the current text) and "Wrap
/// Task" (empty, for the new parent) actions. Auto-focuses, submits on Return, cancels on Escape via
/// the host surface's escape handling. Matches the styling of `AddEditor`/`DueEditor`.
struct InlineTextEditor: View {
    let placeholder: String
    let submitLabel: String
    /// Optional leading status glyph, so the task keeps its identity while its text is edited (the
    /// existing task's own checkbox state) or a wrap parent is named (an empty circle).
    let leadingIcon: AnyView?
    /// When true, an empty (blank) value is a valid submission — used by the session-label editor,
    /// where clearing the field removes the label. Task text editors leave this false so a blank
    /// submit is a no-op.
    let allowsEmpty: Bool
    /// Open the project a `[[…]]` in the field names.
    var onOpenProject: ((String) -> Void)?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(seed: String = "", placeholder: String, submitLabel: String, leadingIcon: AnyView? = nil,
         allowsEmpty: Bool = false, onOpenProject: ((String) -> Void)? = nil,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.leadingIcon = leadingIcon
        self.allowsEmpty = allowsEmpty
        self.onOpenProject = onOpenProject
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon { leadingIcon }
            CompletingTextField(text: $text, placeholder: placeholder,
                                onSubmit: submit, onCancel: onCancel,
                                onOpenProject: onOpenProject)
                .frame(height: 21)
            Button(submitLabel, action: submit).keyboardShortcut(.defaultAction)
            Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        // Deferred for the reason spelled out on `AddEditor`: focus requested from inside the update
        // that inserts the field has nothing to land on.
        .onAppear { afterCurrentUpdate { focused = true } }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmpty || !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: Editor identity + outside-click plumbing

/// Identifies which row has an open inline editor, and which kind. Task editors key on
/// "sessionIndex:lineIndex" and session editors on "sess:<index>", so the two namespaces can't
/// collide; the unanchored quick add belongs to no row and takes its own kind. Only one editor is
/// ever open at a time.
struct EditorTarget: Equatable {
    enum Kind { case add, due, waiting, edit, wrap, quickAdd, sessionLabel, sessionNote, sessionAddTask }
    let key: String
    let kind: Kind
    /// For a session editor: which session it was opened on, named the way `SessionRef` names one —
    /// by date, ordinal and a digest of its label — rather than by the index inside `key`.
    ///
    /// An editor is open for as long as someone is typing into it, and a session index does not survive
    /// that reliably: a note written from the quick bar starts a sitting, splices it in at the top, and
    /// every index below it means a different session than it did a moment ago. Captured here when the
    /// editor opens, the reference still names what the person was looking at when they commit.
    var session: SessionRef? = nil

    /// Identity is `key` and `kind` alone: the reference is what a target *carries*, not what it *is*.
    /// Every `activeEditor == EditorTarget(key:kind:)` test in the view asks "is this editor the open
    /// one", and would start answering no if it had to match a reference the asker has no reason to
    /// reconstruct.
    static func == (a: EditorTarget, b: EditorTarget) -> Bool { a.key == b.key && a.kind == b.kind }
}

/// The active inline editor reports its window-space frame so a mouse-down monitor can tell an
/// outside click (which cancels the editor) from a click within it. Only one editor is open at a
/// time, so the first non-nil frame wins.
struct ActiveEditorFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

extension View {
    /// Publish this editor's frame (SwiftUI global / window space) for the outside-click monitor.
    func reportEditorFrame() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ActiveEditorFrameKey.self, value: geo.frame(in: .global))
        })
    }
}

/// Watches for left mouse-downs in its own window while an editor is open and cancels the editor when
/// the click lands outside its reported frame (swallowing that click so it only dismisses).
///
/// Scoped to one window: the app can have several project windows open plus the focus panel, each with
/// its own editor, and a click in one of them must not dismiss another's.
final class OutsideClickMonitor: ObservableObject {
    var editorFrame: CGRect?
    var onOutsideClick: (() -> Void)?
    /// The window this monitor belongs to; clicks anywhere else are left alone.
    weak var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window === self.window
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

/// Reports the `NSWindow` a SwiftUI subtree ended up in. Several behaviors here are per-window — the
/// outside-click monitor, the note editor's save-on-blur — and with more than one window open they need
/// to know *which* window they're in, which SwiftUI doesn't otherwise say on macOS 13.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(onResolve: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let onResolve: (NSWindow?) -> Void
        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // `viewDidMoveToWindow` runs mid-layout and the callback writes SwiftUI state.
            let window = self.window
            MainActor.assumeIsolated {
                afterCurrentUpdate { [onResolve] in onResolve(window) }
            }
        }
    }
}

/// Run `work` after the update currently in progress has finished.
///
/// SwiftUI is re-entrant in ways AppKit is not. Taking first responder, or writing view state, from
/// inside `updateNSView` or `viewDidMoveToWindow` lands in the middle of the update that called it —
/// which SwiftUI either warns about ("Modifying state during view update") or resolves by dropping the
/// change on the floor. A hop to the next runloop turn is the way out, and there is no API that avoids
/// it: the AppKit callbacks these sit in have no "and now layout is done" counterpart.
///
/// This exists so those hops are one named thing with the reason attached, rather than a scattering of
/// bare `DispatchQueue.main.async` calls that read like someone was papering over a race. If you are
/// reaching for it for any *other* reason — waiting for an animation, letting a value settle — it is
/// the wrong tool and the thing you want is a real completion handler.
@MainActor
func afterCurrentUpdate(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async(execute: work)
}

/// A backing AppKit view that opts its region out of a borderless window's
/// `isMovableByWindowBackground`, so a mouse-drag that begins on it starts a SwiftUI `.onDrag` (item
/// reorder) or registers a click, instead of being claimed by AppKit as a window move.
struct WindowDragExcluder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ExcluderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ExcluderView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
