import AppKit
import PmLib
import SwiftUI

/// The height of a whole header bar — header plus its rule and padding, not just the text — so content
/// underneath can be inset by exactly as much as the bar covers.
private struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// `max`, not the `value = nextValue()` of the keys above. Those are read where exactly one subtree
    /// sets them; this one is read across a stack where the bar sets a height and the editor beside it
    /// sets nothing and so contributes the default. Last-writer-wins then comes down to which of the two
    /// reduces last, and when it was the editor the answer was 0 — the bar's height never reached the
    /// editor at all, and the note's first lines sat underneath it.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A soft top edge for a scroll area that AppKit, not SwiftUI, owns.
///
/// The task column gets this from the system — `scrollEdgeEffectStyle(.soft, for: .top)` on a SwiftUI
/// `ScrollView` (see `SoftScrollEdges`). The note takeover can't: its content is an `NSTextView` in an
/// `NSScrollView`, and AppKit's form of the effect (`NSScrollEdgeEffectStyle`) is offered only to
/// titlebar and split-view accessories, never to a scroll view you hold yourself.
///
/// So: the window's own background, faded out down the strip. Nothing more. This started as
/// `TitlebarMaterial` under the same fade, which was wrong twice over — the material is *lighter* than
/// the window background, so instead of disappearing it painted a pale band across the top of the
/// takeover, and the pills standing on it put a second material inside the first. Window background is
/// exactly what's behind the prose (the text view draws none of its own), so this is invisible at rest
/// and does its only job — hiding text that scrolls up into the header — without announcing itself.
///
/// The far stop is the same colour at zero alpha rather than `.clear`, which in a gradient interpolates
/// through transparent *black* and leaves a dark bloom halfway down.
///
/// Sized by the header, and so measured by it: the strip this fills is exactly `barHeight`, which is
/// what the editor takes as its text-container inset. The fade happens inside that height rather than
/// hanging below it, or the prose would start further down than the chrome actually reaches.
private struct SoftHeaderScrim: View {
    private var ground: Color { Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: ground, location: 0),
                .init(color: ground, location: 0.55),
                .init(color: ground.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }
}

/// The full-column, focused editor for a session's prose note. The column is taken over by a header
/// (Back button + the project name over the session's date and label) and a rich `MarkdownTextEditor`
/// with live syntax highlighting and ⌘B/⌘I/⌘K shortcuts. There are no Save/Cancel buttons: the note
/// **auto-saves** whenever you leave — Back, Escape, an outside click (all remove the view →
/// `onDisappear`), or the window losing key focus (`didResignKey`). `store.setSessionNote` is
/// byte-idempotent, so a repeated commit with no changes is a free no-op and yields no extra undo entry.
///
/// The label is edited here, in the header, rather than behind a gesture out in the list. This is where
/// you already are when you're working on a session, it's the one place the label is shown next to the
/// date it decorates, and it means the list doesn't need a second double-click meaning of its own.
/// The clearance a takeover's header needs where it is standing — see `SessionNoteTakeover.Placement`.
///
/// A modifier rather than a branch in the header itself, so the two hosts differ in one named place
/// instead of putting an `if` through the middle of a view that is otherwise identical in both.
private struct SessionNoteHeaderInset: ViewModifier {
    let placement: SessionNoteTakeover.Placement

    @ViewBuilder func body(content: Content) -> some View {
        switch placement {
        case .titlebar(let state):
            content.modifier(TitlebarClearance(state: state, bottom: 8))
        case .card:
            // The card's own gutter, and the same 8pt below the header the window leaves — this stands
            // over the editor rather than above it either way, so the gap is the editor's top inset.
            content.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        }
    }
}

/// **Not private, because a project card hosts it too.** A board is a place you work, so writing a note
/// happens where you are rather than in the window you would have had to go to — and a card that grew
/// its own editor would be a lookalike of this one, drifting from it a fix at a time. The two couplings
/// to a window are parameters instead: where the header stands, and what opens a `[[project]]`.
struct SessionNoteTakeover: View {
    /// Where this takeover is standing, which is the only thing that differs between the two hosts.
    ///
    /// In a window the header shares the titlebar strip with the task column's, under the same traffic
    /// lights, and insets itself from the same measurements. A card has no titlebar and no buttons to
    /// clear, so there the header is simply a header.
    enum Placement {
        case titlebar(ProjectWindowState)
        case card
    }

    let index: Int
    let session: Session
    let projectName: String
    @ObservedObject var store: PMStore
    let placement: Placement
    /// Follows a `[[Project]]` out of the note — the window's sidebar in one host, the board's
    /// open-project in the other.
    let onOpenProject: (String) -> Void
    let onBack: () -> Void

    @State private var text: String
    /// The prose this takeover opened with, and the identity of the session it opened *on*.
    ///
    /// Both are `@State` captured at init, deliberately, because `session` is not: SwiftUI rebuilds
    /// this struct from the store on every change, so by the time the editor closes `session` is
    /// whatever now sits at `index` — which is not necessarily what was being edited. A note written
    /// from the quick bar can start a new session and insert it above this one, and then `index` names
    /// a different sitting than it did a moment ago.
    ///
    /// That is not hypothetical: it silently destroyed a note. The takeover auto-saves on the way out,
    /// the way out fired after a quick-bar note had inserted a new session at index 0, and this view
    /// wrote its untouched copy of the *previous* session's prose over the note that had just been
    /// written into the new one.
    @State private var seed: String
    @State private var seedLabel: String
    /// Which session this was opened on, by `SessionRef` rather than by `index`.
    @State private var ref: SessionRef
    /// The session's label, as typed. Committed on Return and on the way out, beside the prose.
    @State private var label: String
    /// Whether the pointer is over the label field, which is how a plain-looking line of header text
    /// says it's editable.
    @State private var labelHovering = false
    /// The window this takeover is in, so the save-on-blur only fires for *this* window losing key.
    @State private var hostWindow: NSWindow?
    /// The bar's measured height, fed to the editor as its text-container top inset.
    @State private var barHeight: CGFloat = 0
    /// Whether the pointer is in the header strip, and whether this window is the active one — the two
    /// inputs to `HeaderChrome`, exactly as in the task column's header.
    @State private var headerHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    init(index: Int, session: Session, projectName: String, store: PMStore,
         placement: Placement, onOpenProject: @escaping (String) -> Void,
         onBack: @escaping () -> Void) {
        self.index = index
        self.session = session
        self.projectName = projectName
        self.store = store
        self.placement = placement
        self.onOpenProject = onOpenProject
        self.onBack = onBack
        _text = State(initialValue: sessionNoteBody(body: session.body))
        _label = State(initialValue: session.label)
        _seed = State(initialValue: sessionNoteBody(body: session.body))
        _seedLabel = State(initialValue: session.label)
        _ref = State(initialValue: store.sessionRef(at: index)
            ?? SessionRef(index: index, digest: sessionDigest(session.label)))
    }

    var body: some View {
        // The header stands over the editor rather than stacking above it, and the editor takes its
        // height as a text-container inset. That's the same arrangement the task list gets from
        // `safeAreaInset`, reached differently because this content is an `NSTextView` in an
        // `NSScrollView` rather than a SwiftUI `ScrollView`. Stacked, the prose stopped at the divider
        // and the material had nothing but window background behind it — a bar in name only.
        //
        // A `ZStack` and not `.overlay`, because the header's measured height has to reach the editor
        // and siblings in a stack propagate their preferences to the stack's parent beyond any doubt.
        // Read off an overlay it never arrived, leaving `barHeight` at zero and the first lines of the
        // note underneath the bar.
        ZStack(alignment: .top) {
            // ⌘↩ → auto-saves. The note's own file goes in so a dropped file can be linked relative to
            // it and a relative link can be followed back out of it.
            MarkdownTextEditor(onOpenProject: onOpenProject,
                               text: $text, onSubmit: onBack,
                               placeholder: "Write a note…",
                               noteURL: store.notesPath.map { URL(fileURLWithPath: $0) },
                               opensAtStart: true,
                               topInset: barHeight)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                // Prose wants the readable cap as much as the task rows do; it used to inherit it from
                // a frame around the whole column. Its own cap rather than the general one: a note is
                // set in a fixed-advance face, so its comfortable width is a character count and can be
                // stated as one. See `MarkdownTextEditor.measureWidth`.
                .modifier(ReadableWidth(cap: MarkdownTextEditor.measureWidth))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Same chrome as the task list's header — this stands in the same titlebar strip, so it
            // floats the same way: a back button and an identity pill in glass, over a scrim that
            // fades out rather than a bar that ends in a rule. Cap inside the scrim, as there: the
            // title stays at the width of the prose it heads, the scrim spans the pane.
            header
                .modifier(ReadableWidth(cap: MarkdownTextEditor.measureWidth))
                .background(SoftHeaderScrim())
                .background(GeometryReader { geo in
                    Color.clear.preference(key: BarHeightKey.self, value: geo.size.height)
                })
        }
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fill the window. The takeover used to negotiate a height with a window that sized itself to
        // its content; a real window's height is the user's, so the editor takes what it's given.
        .frame(maxHeight: .infinity)
        // Cover the whole takeover as the "active editor" region so in-window clicks count as inside it.
        .reportEditorFrame()
        // Auto-save on every way out: Back / Escape / outside-click remove the view (onDisappear); a
        // blur-hide leaves the view mounted but resigns key.
        .onDisappear { commit() }
        .background(WindowAccessor { hostWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let hostWindow, (note.object as? NSWindow) === hostWindow { commit() }
        }
    }

    /// The takeover's header: a back button in its own glass circle, then the identity pill — the
    /// project's name over the session it belongs to.
    ///
    /// This is the closest thing in the app to the Messages conversation header it's modelled on, and
    /// it's where the two-line "name over detail" pill finally earns its second line: out in the task
    /// column the project's name stands alone, but here the note needs saying *which* session it is,
    /// and the date is the only thing that answers that.
    private var header: some View {
        HStack(spacing: 8) {
            backButton
            identityPill
            Spacer(minLength: 12)
        }
        .opacity(chrome.contentOpacity)
        .modifier(SessionNoteHeaderInset(placement: placement))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { headerHovering = hovering }
        }
        .animation(.easeOut(duration: 0.18), value: controlActiveState)
    }

    /// What this header's glass is doing right now — the same three states the task column uses.
    private var chrome: HeaderChrome {
        HeaderChrome(active: controlActiveState, hovering: headerHovering)
    }

    /// Back to the task list. Its own circle of glass at the leading edge, separate from the pill, the
    /// way Messages keeps its leading button apart from the name it sits beside — this is an action,
    /// and the pill is a label.
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .headerBacking(chrome, in: Circle())
        .background(WindowDragExcluder())
        .help("Back to tasks")
    }

    /// The project's name over the session's date and label.
    ///
    /// No gesture of its own, because it holds a text field: the label is edited in place here. A
    /// pill that responded to a press would be promising one to something whose actual job is to take
    /// a caret.
    private var identityPill: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(projectName.isEmpty ? "Note" : projectName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            sessionLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .headerBacking(chrome, in: Capsule())
        .background(WindowDragExcluder())
    }

    /// The session's identity line under the project name: its date, fixed, and its label, editable in
    /// place. The field is plain until the pointer is over it — a bordered box in a titlebar strip would
    /// read as a form where this is a title.
    private var sessionLine: some View {
        HStack(spacing: 4) {
            Text(session.date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            labelField
        }
    }

    /// The label field, sized to its own text rather than to whatever width is going spare.
    ///
    /// A `TextField` takes every point it is offered. Inside a pill whose whole job is to hug its
    /// contents that meant the pill stretched most of the way across the window — the field's old
    /// `maxWidth: 240` was a cap on the damage, not a fix, because a flexible frame still claims the
    /// width it's proposed. The hidden `Text` behind it is a width template instead: the label when
    /// there is one, the placeholder when there isn't. The stack sizes to the template, which is
    /// ordinary text and asks for exactly what it needs, and the field fills it — so the field is as
    /// wide as what it's showing and grows a character at a time as you type.
    ///
    /// The trailing padding is caret room. Sized to the glyphs alone, the insertion point at the end
    /// of the text sits on the field's last pixel.
    ///
    /// `.overlay`, not a `ZStack`. A stack sizes to its largest child and the field is still a child,
    /// so it claimed the full proposal and took the stack with it — the template was along for the ride
    /// rather than setting the width. Overlay content doesn't participate in layout at all: the hidden
    /// `Text` alone decides the size, and the field is handed exactly that.
    private var labelField: some View {
        Text(label.isEmpty ? "Add a label" : label)
            .font(.caption)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                TextField("Add a label", text: $label)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1)
                    // Return in the label field renames the session it was opened on, resolved the
                    // same way the note's own save resolves it.
                    .onSubmit { commitLabel() }
            }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(labelHovering ? 0.07 : 0)))
        .onHover { labelHovering = $0 }
        .help("Session label")
        .background(WindowDragExcluder())
    }

    /// Write the current text back to the session's note — the whole body, so a checkbox typed between
    /// two paragraphs is saved between them. The store sanitizes it (headings clamp to within-session
    /// levels, which is all that's left to defend), so we adopt the same cleaned text locally and
    /// repeated commits (this fires from several exit paths) stay byte-idempotent.
    ///
    /// Through `SessionNoteMerge`, because what this write can destroy grew. While a note was the lines
    /// above a session's first task, a save couldn't touch its tasks — everything from the first
    /// checkbox down was preserved byte-for-byte, so a task added from the quick bar or another window
    /// while the editor sat open survived it. The body write has no such floor: last-write-wins here
    /// means the whole sitting. So the same resolver the live note surface uses decides — untouched
    /// text at the front of ours means their version plus our additions, and only a real divergence
    /// falls back to overwriting, which is logged.
    ///
    /// The label rides along: it's edited in the same view and leaves by the same exits, and the store's
    /// serial IO queue keeps the two writes in order — the heading rewrite preserves the body and the
    /// body rewrite preserves the heading, so neither can land on top of the other.
    /// Save on the way out — but only what was actually changed, and only into the session this was
    /// opened on.
    ///
    /// Both guards matter, and neither substitutes for the other. Writing nothing when nothing was
    /// typed is what stops an editor that was merely opened and closed from overwriting whatever
    /// arrived while it was up; the idempotence this used to lean on only holds while the document
    /// underneath is unchanged, which is exactly the case that goes wrong. And `ref` names the sitting
    /// by date and label rather than by the index it had on the way in, so a real edit can't land in a
    /// session that has since moved into that position. A reference that can no longer be resolved
    /// refuses the write rather than guessing — see `resolveSessionRef`.
    ///
    /// The note goes first and the label second, deliberately: the reference asserts the label it was
    /// made with, so renaming before writing would invalidate it for the write that follows.
    private func commit() {
        if text != seed {
            switch SessionNoteMerge.resolve(edited: text, onDisk: currentBody(), seed: seed) {
            case .unchanged:
                seed = text
            case .replace(let body):
                write(body)
            case .merged(let body):
                Log.write("session note merged an edit made elsewhere while it was open")
                write(body)
            case .overwrote(let body):
                Log.write("session note overwrote an edit made elsewhere while it was open")
                write(body)
            }
        }
        commitLabel()
    }

    /// The session's body as the store has it now, found through `ref` rather than the `index` this
    /// editor opened on — the index may name a different sitting by the time we save, which is the
    /// whole reason the reference exists.
    ///
    /// A reference that won't resolve answers `seed`, which makes the merge a plain replace and leaves
    /// the refusal to the write itself: `setSessionNote` resolves the same reference against the bytes
    /// it is about to rewrite, and declines rather than guessing. Answering `""` here would instead
    /// look like somebody had emptied the note.
    private func currentBody() -> String {
        guard let notes = store.notes,
              let resolved = try? resolveSessionRef(ref, notes: notes),
              resolved.index < notes.sessions.count else { return seed }
        return sessionNoteBody(body: notes.sessions[resolved.index].body)
    }

    /// Send a body to the store and adopt what it will have written.
    ///
    /// The local text is set to the *sanitized* form, not the one handed over: the seed has to be what
    /// the editor is now holding, or the next commit sees a difference that is only this one's own
    /// tidying.
    private func write(_ body: String) {
        let cleaned = sanitizeSessionNoteBody(body)
        store.setSessionNote(ref, body: body)
        if cleaned != text { text = cleaned }
        seed = cleaned
    }

    private func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Against the label this opened with, not `session`'s — see `seed` for why the two differ.
        guard trimmed != seedLabel else { return }
        store.renameSession(ref, label: trimmed)
        seedLabel = trimmed
        // The reference asserted the old label; after the rename it has to describe the session as it
        // now is, or a second commit from this same editor would be refused as stale.
        ref.digest = sessionDigest(trimmed)
    }
}

/// Insets a header that runs up under the window's (hidden, transparent) titlebar so it clears the
/// traffic lights and sits level with them.
///
/// Every header this column can show wears this — the task list's and the session-note takeover's —
/// because they occupy the same strip and swap places. Hard-coding the padding in one of them is how
/// the takeover's title ended up under the buttons on macOS 26, where the unified titlebar sits them
/// lower than the compact one this app started against.
private struct TitlebarClearance: ViewModifier {
    @ObservedObject var state: ProjectWindowState
    /// The gap below the header. The task list's is fenced off by a rule, the takeover's by a divider
    /// tight to the editor, so they don't want the same one.
    var bottom: CGFloat = 14

    /// The column's own offset within its pane — zero until the width cap starts centring it in a wide
    /// window.
    @State private var columnOffsetInPane: CGFloat = 0

    /// The header's measured height. Seeded at one `.title3` line, which is the task list's header, so
    /// the first frame lands where it will settle rather than jumping.
    @State private var contentHeight: CGFloat = 22

    /// How much of the window's traffic lights this column sits under.
    private var overhang: CGFloat {
        guard !state.sidebarVisible else { return 0 }
        return max(0, state.leadingTitlebarInset - columnOffsetInPane)
    }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, 14)
            // Start past the traffic lights, but only by however much they actually overhang this
            // column.
            //
            // Two things decide that. The sidebar, when it's showing, holds the buttons over *itself*,
            // so the column needs no inset at all. And once the window is wide enough that the width
            // cap has centred the column, it may already begin clear of them — so a fixed inset would
            // shove the title 60-odd points further right for no reason.
            //
            // The inset is animated because the sidebar's collapse is: the flag flips in one frame
            // while the pane takes a quarter second to slide, and an unanimated jump in the middle of
            // that is the reflow this used to show on every toggle.
            .padding(.leading, 14 + overhang)
            // Measured *outside* the padding above, so it reports the column's own leading edge within
            // its pane and can't feed back into the value it produces. Pane-local is all that's
            // available — each pane's SwiftUI content is its own coordinate root — but pane-local is
            // also all that's needed, given the sidebar case is settled by the flag.
            .background(GeometryReader { geo in
                Color.clear
                    .preference(key: HeaderOriginKey.self, value: geo.frame(in: .global).minX)
                    // Height is measured here too, and this is the right place for it: horizontal
                    // padding doesn't change it, and the vertical padding that consumes it is applied
                    // below, so it can't feed back either.
                    .preference(key: HeaderHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(HeaderOriginKey.self) { if let x = $0 { columnOffsetInPane = x } }
            .onPreferenceChange(HeaderHeightKey.self) { if let h = $0, h > 0 { contentHeight = h } }
            .animation(.easeInOut(duration: 0.25), value: overhang)
            // Centre the header on the traffic lights, wherever the system has put them — the unified
            // titlebar this window uses sits them twice as far down as a compact one would, and
            // hard-coding either number means the header is level in one and adrift in the other.
            //
            // Centred on the header's *measured* height, not on half a title line. Both headers that
            // wear this are laid out by it, and they aren't the same height: the task list's is one
            // `.title3` line, while the note takeover's is a two-line stack (project name over the
            // session's date). A fixed half-line centres whichever one it was written for and hangs the
            // other below the buttons — which is what the takeover's header was doing.
            // Floored at zero, not at 8. The floor used to be 8pt of guaranteed top margin, which
            // quietly stopped being a floor and started being the answer: the note takeover's header is
            // a two-line pill, tall enough that centring it on the buttons wants about 4pt of top
            // padding, so the clamp held it ~4pt below the traffic lights it was supposed to be level
            // with. A header taller than twice the button drop is *meant* to reach further up — that's
            // what centring on a line means — and zero is the only floor that says so.
            .padding(.top, max(0, state.titlebarButtonCenterY - contentHeight / 2))
            .padding(.bottom, bottom)
    }
}

/// The content column's leading edge in window space, so the header can tell how much of the window's
/// traffic lights it actually sits under.
/// Optional, and reduced by "first one that actually reported", for the reason spelled out on
/// `BarHeightKey`: these are read across a view and its `.background`, so one of the two subtrees sets
/// a real measurement and the other sets nothing. With a plain value and `value = nextValue()`, the
/// subtree that reduces last wins — and when that was the non-reporting one, the answer was the
/// default. `nil` for "didn't measure" makes non-reporters skippable, so the single real measurement
/// wins regardless of order.
private struct HeaderOriginKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// The header's own height, so its top padding can centre it on the traffic lights whatever it holds.
///
/// This one was silently broken by the reduction above: it defaulted to 22 — one `.title3` line — which
/// is the task list header's height, so that header looked right and the note takeover's two-line header
/// went on being centred as if it were one line, which is the bug measuring it was meant to fix.
private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}
