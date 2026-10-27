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
    /// A pill the pointer is over opens, and closes again when it leaves — unless you are working in it.
    var pillOpen = false
    var title = ""
    var tint: Color?
    var icon: ProjectIcon?
    /// The tallest the card gets before it scrolls — a share of the satellite's height, so the panel
    /// stays a thing beside the window rather than a second one.
    var cardCap: CGFloat = 420

    var showsPill: Bool { asPill && !pillOpen }

    /// The cap for a satellite this tall: over half of it, within reason.
    static func cardCap(forWindowHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.6, 220), 560)
    }
}

/// The session companion's content: the project card, under a header you move it by, beside the
/// satellite you are working in. See `CanvasSatelliteCompanion`.
///
/// **The project card, not a lookalike.** It drew its own short version — the note's last three lines,
/// five tasks, a tick and a field — and every list behaviour the card had learnt was missing from it:
/// no selection, no reordering, no editing a task, no dates. Now the panel is the card set to Current
/// (the latest sitting's note and every open task), with the card's own line for adding to the note,
/// and what you can do to a task here is what you can do to it anywhere.
///
/// **The header is the panel's.** It stays put while the card scrolls, it is what you drag the panel by,
/// and it holds the project's mark and the way to its window — so the card's own title is left off.
///
/// **No stepping in.** A card on a board takes a click before it takes edits, so panning across it is
/// safe; this is a thing you aim at, so it acts from the first click, as a tile does.
struct CanvasCompanionView: View {
    let store: PMStore
    let state: CanvasCompanionState
    let noteURL: URL
    let commands: CanvasProjectCardCommands
    let display: CanvasProjectCardDisplay
    let engagement: CanvasCardEngagement
    var onSize: (CGSize) -> Void = { _ in }
    /// The header (or the pill) dragged: the panel follows the pointer, and snaps to a corner on release.
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var onOpenProject: () -> Void = {}

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
                guard !Task.isCancelled, !engagement.isEngaged else { return }
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

    /// The card's height: what its content measures, up to the cap. A little to begin with, before the
    /// first measure lands, rather than the whole cap for a moment.
    private var cardHeight: CGFloat {
        min(display.contentHeight ?? 120, state.cardCap)
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
            CanvasProjectNote(store: store, engagement: engagement, noteURL: noteURL,
                              onOpenProject: { WindowManager.shared.open(named: $0) },
                              commands: commands, display: display)
                // A new project is a new card, with nothing of the last one's selection or editors.
                .id(ObjectIdentifier(commands))
                .frame(height: cardHeight)
        }
        .frame(width: CanvasCompanionPlacement.width)
        .background(CompanionGlass(tint: state.tint, cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
            // The card's two verbs, which its own title would have carried — asked of the card, so they
            // do here what they do on a board.
            Button("New Task", systemImage: "plus") { commands.requestNewTask() }
                .labelStyle(.iconOnly)
                .help("New Task")
            Button("New Session", systemImage: "calendar.badge.plus") {
                commands.requestNewSession(forcingNew: NSEvent.modifierFlags.contains(.option))
            }
            .labelStyle(.iconOnly)
            .help("New Session — hold ⌥ to start another, unless this one is still empty")
            Button("Show Project", systemImage: "arrow.up.forward.app", action: onOpenProject)
                .labelStyle(.iconOnly)
                .help("Show the project's window")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// The companion's hosting view, which holds the keyboard on the card's behalf while the panel is key —
/// the part a board plays for a card stepped into on it: the list's keys, ⌘A/⌘C/⌘V, ⌘Z, and the
/// project commands in the File menu all mean the card.
final class CanvasCompanionHostingView: NSHostingView<CanvasCompanionView>, ProjectCardKeyHolder, NSMenuItemValidation {
    var onEscape: () -> Void = {}

    var standingInCard: CanvasProjectCardCommands? { rootView.commands }
    private var store: PMStore { rootView.store }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if rootView.commands.takesListKey(event) { return }
        if event.charactersIgnoringModifiers == "\u{1b}" { return onEscape() }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    @objc override func selectAll(_ sender: Any?) { rootView.commands.requestSelectAllRows() }
    @objc func copy(_ sender: Any?) { rootView.commands.requestCopyRows() }
    @objc func paste(_ sender: Any?) { rootView.commands.requestPasteRows() }
    @objc func newTask(_ sender: Any?) { rootView.commands.requestNewTask() }
    @objc func newSession(_ sender: Any?) { rootView.commands.requestNewSession() }
    @objc func startNewSession(_ sender: Any?) { rootView.commands.requestNewSession(forcingNew: true) }
    @objc func editProjectDetails(_ sender: Any?) { rootView.commands.requestEditDetails() }
    @objc func undo(_ sender: Any?) { store.undo() }
    @objc func redo(_ sender: Any?) { store.redo() }

    /// Asked only for the actions above — AppKit asks the responder that answers an item.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return rootView.commands.selectedRows > 0
        case #selector(paste(_:)): return TaskPasteboard.hasTasksToPaste
        case #selector(undo(_:)): return store.canUndo
        case #selector(redo(_:)): return store.canRedo
        case #selector(selectAll(_:)), #selector(newTask(_:)), #selector(newSession(_:)),
             #selector(startNewSession(_:)), #selector(editProjectDetails(_:)):
            return store.projectName != nil
        default: return true
        }
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
