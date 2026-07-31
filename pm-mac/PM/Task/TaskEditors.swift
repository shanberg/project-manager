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
struct AddEditor: View {
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
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(seed: String = "", placeholder: String, submitLabel: String, leadingIcon: AnyView? = nil,
         allowsEmpty: Bool = false,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.leadingIcon = leadingIcon
        self.allowsEmpty = allowsEmpty
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
        guard allowsEmpty || !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: Editor identity + outside-click plumbing

/// Identifies which row has an open inline editor, and which kind. Task editors key on
/// "sessionIndex:lineIndex"; session editors key on "sess:<index>" (or "sess:new"), so the two
/// namespaces can't collide and only one editor is ever open at a time.
struct EditorTarget: Equatable {
    enum Kind { case add, due, edit, wrap, sessionLabel, sessionNote, sessionAddTask, sessionNew }
    let key: String
    let kind: Kind
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
            // Deferred: `viewDidMoveToWindow` runs mid-layout, and the callback writes SwiftUI state.
            let window = self.window
            DispatchQueue.main.async { [onResolve] in onResolve(window) }
        }
    }
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
