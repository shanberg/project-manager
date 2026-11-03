import AppKit
import PmLib
import SwiftUI

/// The project card in the dock's flyout: the companion's view — its header, and the card set to
/// Current — at the shape of a tarot card, so a project reads as where it stands rather than as a list
/// of its windows. See `CanvasSatelliteDock`.
///
/// **The companion's card, not a summary of it.** The flyout said the focused task and the session in
/// two rows, which was less than the panel beside a satellite already says. It is that panel's view now,
/// with the focused task pinned first, the note's last three lines, and five of the open tasks before
/// "N more" — the same card, so what you can do to a task here is what you can do to it anywhere.
///
/// **One shape for every project**: 320 by 553, eleven to nineteen. The card scrolls inside it, and the
/// window rows sit at its foot.
///
/// **The keyboard only when the card asks**, as in the companion: a row picked, an editor or the note's
/// line opened. While it has it the flyout stays up wherever the pointer goes; it goes when the keyboard
/// goes elsewhere.
@MainActor
final class CanvasDockCard {
    static let size = NSSize(width: CanvasCompanionPlacement.width, height: (CanvasCompanionPlacement.width * 19 / 11).rounded())

    /// The flyout's panel, which the card takes the keyboard into.
    weak var panel: KeyablePanel?
    /// Escape with nothing open to close.
    var onDismiss: () -> Void = {}

    private(set) var hosting: CanvasCompanionHostingView?
    private let state = CanvasCompanionState()
    private var commands = CanvasProjectCardCommands()
    private var display = CanvasProjectCardDisplay()
    private var engagement = CanvasCardEngagement()
    private var store: PMStore?
    private var noteURL: URL?
    private var onShow: () -> Void = {}
    /// The Folio window that had the keyboard before the card took it, given it back on Escape.
    private weak var previousKey: NSWindow?

    var isEngaged: Bool { engagement.isEngaged }

    /// The card for `project`, whose board is the canvas at `canvas`, at `height` — the flyout's, less
    /// the window rows under it.
    func view(project key: String, canvas: URL, title: String, color: NSColor?, icon: ProjectIcon?,
              height: CGFloat, show: @escaping () -> Void) -> NSView {
        onShow = show
        if store?.boundKey != key {
            let previous = store
            store = StoreRegistry.shared.acquire(key)
            if let previous { StoreRegistry.shared.release(previous.boundKey) }
            noteURL = CanvasProjectNoteCard.notes(forCanvasAt: canvas)
            makeCard()
            hosting?.rootView = makeView()
        }
        state.title = title
        state.tint = color.map(Color.init(nsColor:))
        state.icon = icon
        state.fixedHeight = height
        let hosting = self.hosting ?? makeHosting()
        hosting.frame = NSRect(x: 0, y: 0, width: Self.size.width, height: height)
        return hosting
    }

    /// Put away with the flyout: the store let go, and nothing of this project's card kept for the next.
    func release() {
        engagement.isEngaged = false
        guard let store else { return }
        StoreRegistry.shared.release(store.boundKey)
        self.store = nil
    }

    // MARK: Keyboard

    /// The card has a use for keys: take them, unless a field already has them.
    private func takeKeyboard() {
        guard let panel, let hosting else { return }
        if !panel.isKeyWindow {
            previousKey = NSApp.keyWindow
            panel.takeKey()
        }
        if !(panel.firstResponder is NSText) { panel.makeFirstResponder(hosting) }
    }

    /// Back to the window you were in, if it was Folio's; otherwise the flyout goes, which gives the
    /// keyboard back to whichever app has it.
    private func giveKeyboardBack() {
        guard let panel, panel.isKeyWindow else { return onDismiss() }
        if let previous = previousKey, previous.isVisible, previous !== panel {
            previous.makeKey()
        } else {
            onDismiss()
        }
    }

    func becameKey() { engagement.isEngaged = true }

    func resignedKey() {
        panel?.acceptsKey = false
        engagement.isEngaged = false
    }

    // MARK: Construction

    /// Current — the latest sitting's note and every open task — with the focused task first, the note
    /// cut to its last three lines and the open tasks to five, and the line for adding to the note.
    private func makeCard() {
        commands = CanvasProjectCardCommands()
        commands.wantsKeyboard = { [weak self] in self?.takeKeyboard() }
        commands.releasesKeyboard = { [weak self] in self?.giveKeyboardBack() }
        display = CanvasProjectCardDisplay()
        display.shows = .current
        display.showsTitle = false
        display.appendsToNote = true
        display.lineWidth = .full
        display.pinsFocus = true
        display.proseTail = 3
        display.pileCap = 5
        display.showsOrigins = false
        engagement = CanvasCardEngagement()
        engagement.isTiled = true
        engagement.isEngaged = panel?.isKeyWindow ?? false
    }

    private func makeHosting() -> CanvasCompanionHostingView {
        state.drawsGlass = false
        state.openTitle = "Show Window"
        state.openHelp = "Show Window"
        let hosting = CanvasCompanionHostingView(rootView: makeView())
        hosting.sizingOptions = []
        hosting.onEscape = { [weak self] in self?.giveKeyboardBack() }
        hosting.translatesAutoresizingMaskIntoConstraints = true
        self.hosting = hosting
        return hosting
    }

    private func makeView() -> CanvasCompanionView {
        CanvasCompanionView(
            store: store ?? StoreRegistry.shared.emptyStore,
            state: state,
            noteURL: noteURL ?? URL(fileURLWithPath: "/"),
            commands: commands,
            display: display,
            engagement: engagement,
            onOpenProject: { [weak self] in self?.onShow() }
        )
    }
}
