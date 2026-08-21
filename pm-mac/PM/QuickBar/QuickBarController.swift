import AppKit
import PmLib
import SwiftUI

/// The quick bar's window: summon, place, dismiss.
///
/// A `KeyablePanel` like the focus panel, and for the same reason — it has to take the keyboard from
/// whatever app you were in without activating PM, so dismissing it leaves you back in that app with
/// your insertion point where you left it. Everything else is the opposite of the focus panel's
/// chrome: no snapping, no remembered position, no pinning. A bar you summon appears where you're
/// looking and leaves the moment you're done, so it's centred on the active screen every time.
@MainActor
final class QuickBarController: NSObject, NSWindowDelegate {
    static let shared = QuickBarController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<QuickBarView>?
    private let model = QuickBarModel()
    /// Whether the full project list is currently retained for the bar (its scan is gated).
    private var holdsProjectIndex = false

    private override init() {
        super.init()
        model.onRun = { [weak self] row, modifiers in self?.run(row, modifiers: modifiers) }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Presentation

    /// Summon in a mode. Summoning the mode that's already up dismisses it — a toggle, since the same
    /// key brought it here.
    func toggle(mode: QuickBarMode) {
        if isVisible, model.mode == mode { hide() } else { show(mode: mode) }
    }

    func show(mode: QuickBarMode) {
        seed(mode: mode)
        let panel = ensurePanel()
        rebuildContent()
        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
        // The bar is nothing but a text field; every path here is a request to type into it.
        panel.takeKey()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        releaseProjectIndex()
    }

    /// Fill in what the rows are built from, fresh each summon: the focused project may have moved and
    /// the project lists may have been rescanned since last time.
    private func seed(mode: QuickBarMode) {
        retainProjectIndex()
        let index = ProjectIndex.shared
        index.warmRecents()
        index.warmAllProjects()
        model.recents = index.recents
        model.allProjects = index.allProjects
        model.focusedProjectName = PMFiles.focusedProjectKey().flatMap { PMFiles.projectName(fromKey: $0) }
        model.reset(mode: mode)
    }

    /// The full-project scan runs only while something wants it. The bar wants it while it's up, and
    /// not a moment longer — this is the same retain the project sidebar uses.
    private func retainProjectIndex() {
        guard !holdsProjectIndex else { return }
        holdsProjectIndex = true
        ProjectIndex.shared.retain()
    }

    private func releaseProjectIndex() {
        guard holdsProjectIndex else { return }
        holdsProjectIndex = false
        ProjectIndex.shared.release()
    }

    // MARK: Running a row

    private func run(_ row: QuickBarRow, modifiers: EventModifiers) {
        switch row {
        case .addTask(let text, let due, _):
            guard let key = PMFiles.focusedProjectKey() else { return }
            // The focused project's store, which is the *same* store the menubar and any window on that
            // project are showing — so the task appears everywhere at once, with one undo history.
            let store = StoreRegistry.shared.acquire(key)
            store.addTodo(text: text, due: due)
            StoreRegistry.shared.release(key)
            Log.write("quick bar added task to \(key): \(text)\(due.map { " due:\($0)" } ?? "")")
            hide()

        case .project(let key, let name, _, _, _):
            PMStore.setGlobalFocus(key: key)
            Log.write("quick bar focused \(name)")
            hide()
            // ⌘⏎ points PM at the project without pulling you out of what you're doing; a plain ⏎ is a
            // request to go there, so it brings the window forward.
            if !modifiers.contains(.command) {
                WindowManager.shared.open(projectKey: key)
            }
        }
    }

    // MARK: Window

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickBarMetrics.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        // Above everything, and present on whichever Space you summon it from — a bar you can't reach
        // from a full-screen app is a bar you can't rely on.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        self.panel = panel
        return panel
    }

    private func rebuildContent() {
        let view = QuickBarView(model: model,
                                onContentHeight: { [weak self] height in self?.fit(to: height) })
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            panel?.contentViewController = hosting
            self.hosting = hosting
        }
    }

    /// Grow and shrink with the rows, keeping the field where it is rather than centring the whole
    /// panel again — a field that slides up the screen as you type is a field you have to chase.
    private func fit(to height: CGFloat) {
        guard let panel, height > 1 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        guard frame.size != panel.frame.size else { return }
        panel.setFrame(frame, display: true)
    }

    /// Centred horizontally, high on the screen — where a summoned bar goes, and above the middle so
    /// its rows drop into empty space rather than over the thing you're reading.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - visible.height * Self.topInsetFraction - size.height)
        panel.setFrameOrigin(origin)
    }

    /// How far down the screen the bar's top edge sits, as a fraction of the visible height.
    private static let topInsetFraction: CGFloat = 0.22

    // MARK: NSWindowDelegate

    /// Losing the keyboard means you've gone somewhere else, and a quick bar left behind on screen is
    /// clutter you have to dismiss by hand. Unlike the focus panel there's no pinned case: the bar has
    /// nothing to show once you're not typing into it.
    func windowDidResignKey(_ notification: Notification) {
        panel?.acceptsKey = false
        hide()
    }
}
