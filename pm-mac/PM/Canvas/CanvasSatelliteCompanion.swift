import AppKit
import PmLib
import SwiftUI

/// The session companion: a small panel beside the satellite you are working in — the sitting you're
/// in, a line to add to its note, and the open tasks.
///
/// **For a big screen with every tile in a window of its own.** Pop Out puts the project window away,
/// so the project card goes with it; this is how the session stays a glance away from whichever window
/// has the keyboard, without a tile to give up for it.
///
/// **One panel for the app**, as the dock is, re-pointed whenever a satellite of a project's board
/// becomes key, and put away when anything else does — another Folio window, or another app.
///
/// **Any satellite, not only a popped-out workspace's.** It was gated on every tile being out, and Pop
/// Out can leave a tile behind (a card with nothing to lend stays on the board), which kept the panel
/// away from exactly the windows it was for.
///
/// **A child window of the satellite**, so it moves with it live, in the window server, with nothing of
/// ours running per frame. Where it sits is `CanvasCompanionPlacement`'s question, asked again when the
/// window moves or resizes or the panel changes height.
///
/// **Drag it to another corner** and it snaps to the nearest one with room and stays there for that
/// window, across launches; while that corner has no room it follows the auto order, and goes back
/// when there's room again. See `CanvasCompanionSpots`.
///
/// **Non-activating**, like the focus panel: ticking a task off leaves the keyboard in the satellite.
/// It takes the keyboard only when you click into one of its fields, and gives it back on Escape.
@MainActor
final class CanvasSatelliteCompanion: NSObject, NSWindowDelegate {
    static let shared = CanvasSatelliteCompanion()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<CanvasCompanionView>?
    private let state = CanvasCompanionState()
    private weak var satellite: CanvasSatelliteWindow?
    private var store: PMStore?
    private var satelliteWatches: [NSObjectProtocol] = []
    private var appWatches: [NSObjectProtocol] = []

    /// The content's measured size, and the open panel's height — the size placement decides with, so
    /// a pill opening never changes corner.
    private var contentSize = NSSize(width: CanvasCompanionPlacement.width, height: 200)
    private var openHeight: CGFloat = 320

    /// Where a drag of the header began: the pointer and the panel's origin, both on the screen.
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    private var releaseWatch: Timer?
    /// The drop preview, two of them: a new corner fades one in while the other fades out where it was.
    /// `SnapGhostWindow` glides one window between anchors, which across a satellite's width read as the
    /// preview warping over the screen.
    private lazy var ghosts = [SnapGhostWindow(), SnapGhostWindow()]
    private var ghostShown = 0
    private var ghostAnchor: CanvasCompanionPlacement.Anchor?
    /// The corner it is at, so a change of corner glides rather than jumps.
    private var anchor: CanvasCompanionPlacement.Anchor?
    /// Bumped by every show and hide, so a fade-out that finishes after the panel was shown again
    /// doesn't put it away.
    private var fadeGeneration = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        appWatches = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
    }

    /// From a satellite becoming key — the first of which is what brings this into being.
    func satelliteBecameKey(_ satellite: CanvasSatelliteWindow) {
        show(beside: satellite)
    }

    /// Show beside the key window if it is a satellite, else put away.
    ///
    /// **No key window is not a reason to go.** Clicking a satellite while Folio is in the background
    /// makes it key a moment before the app says it is active, and between windows there is an instant
    /// with no key window at all; reading either as "something else is in front" hid the panel the
    /// moment it appeared, and sometimes nothing brought it back. Another app coming forward is
    /// `didResignActive`'s to say.
    func refresh() {
        guard let key = NSApp.keyWindow else { return }
        if key === panel { return }   // typing here: stay beside the satellite you came from
        guard let satellite = key.windowController as? CanvasSatelliteWindow else {
            return hide("key window is not a satellite: \(key.title)")
        }
        show(beside: satellite)
    }

    private func show(beside satellite: CanvasSatelliteWindow) {
        guard let board = satellite.board else { return hide("satellite has no board") }
        guard let project = board.boardProject else { return hide("board has no project: \(board.store.url.path)") }
        guard let window = satellite.window, window.isVisible else { return hide("satellite window not visible") }
        let panel = ensurePanel()
        let alreadyShown = self.satellite === satellite && panel.isVisible && panel.alphaValue > 0
        if self.satellite !== satellite {
            detach()
            self.satellite = satellite
            watch(window)
        }
        if store?.boundKey != project.key {
            let previous = store
            store = StoreRegistry.shared.acquire(project.key)
            if let previous { StoreRegistry.shared.release(previous.boundKey) }
            state.showsAllTasks = false
            hosting?.rootView = makeView()
        }
        state.title = project.title
        state.tint = satellite.projectColor.map(Color.init(nsColor:))
        state.icon = satellite.projectMarkIcon
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        hosting?.layoutSubtreeIfNeeded()
        if alreadyShown { return place(animated: false) }
        anchor = nil
        place(animated: false)
        appear()
        Log.write("companion shown beside \(window.title) for \(project.key): frame=\(panel.frame) visible=\(panel.isVisible)")
    }

    func hide(_ reason: String = "") {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        Log.write("companion hidden: \(reason)")
        endDrag(snapping: false)
        detach()
        disappear()
    }

    // MARK: Motion

    /// Where it comes from and goes back to: a few points toward the window it belongs to — in from the
    /// window's side for an outside corner, up from its bottom edge for an inside one.
    private func tuckedIn(_ frame: NSRect) -> NSRect {
        guard !reduceMotion, let anchor else { return frame }
        let distance: CGFloat = 8
        switch anchor {
        case .outsideTopLeft: return frame.offsetBy(dx: distance, dy: 0)
        case .outsideTopRight: return frame.offsetBy(dx: -distance, dy: 0)
        case .insideBottomLeft, .insideBottomRight: return frame.offsetBy(dx: 0, dy: -distance)
        }
    }

    /// Out of the window it belongs to: a short fade, travelling the last few points into place.
    private func appear() {
        guard let panel else { return }
        fadeGeneration += 1
        let final = panel.frame
        panel.alphaValue = 0
        panel.setFrame(tuckedIn(final), display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.settled() }
        }
    }

    /// Back toward the window, quicker than it came.
    private func disappear() {
        guard let panel else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(tuckedIn(panel.frame), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func detach() {
        satelliteWatches.forEach(NotificationCenter.default.removeObserver)
        satelliteWatches = []
        if let panel { panel.parent?.removeChildWindow(panel) }
        satellite = nil
    }

    private func watch(_ window: NSWindow) {
        let center = NotificationCenter.default
        let replace: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.place(animated: false) } }
        satelliteWatches = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: replace),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: replace),
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: replace),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                    if let store = self?.store { StoreRegistry.shared.release(store.boundKey) }
                    self?.store = nil
                }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            },
        ]
    }

    // MARK: Placement

    private var spotKey: CanvasCompanionSpots.Key? {
        guard let satellite, let first = satellite.cardIDs.first else { return nil }
        return .init(canvas: satellite.canvas, workspace: satellite.workspace, window: first)
    }

    private func geometry() -> (window: NSRect, screen: NSRect)? {
        guard let window = satellite?.window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        return (window.frame, screen)
    }

    private var openSize: NSSize { NSSize(width: CanvasCompanionPlacement.width, height: openHeight) }

    private func place(animated: Bool) {
        guard let panel, dragStart == nil, let geo = geometry() else { return }
        let (window, screen) = geo
        let choice = CanvasCompanionPlacement.choose(spot: spotKey.flatMap(CanvasCompanionSpots.spot), size: openSize,
                                                     window: window, screen: screen,
                                                     header: CanvasSatelliteWindow.headerHeight)
        if state.asPill != choice.asPill {
            state.asPill = choice.asPill
            state.pillOpen = false
            return   // the content measures itself again, and that places it
        }
        // A new corner glides there. While the window is being dragged or resized the panel keeps the
        // corner it has and rides along with the window, and glides over once the button comes up —
        // switching mid-drag was an instant jump, with the glide skipped and nothing left to glide by the
        // time the drag ended.
        let changing = anchor != nil && anchor != choice.anchor
        if changing, !animated, !reduceMotion, NSEvent.pressedMouseButtons & 0x1 != 0, let held = anchor {
            waitForRelease()
            let frame = CanvasCompanionPlacement.frame(at: held, size: contentSize, window: window, screen: screen)
            if frame != panel.frame { panel.setFrame(frame, display: true) }
            return
        }
        let frame = CanvasCompanionPlacement.frame(at: choice.anchor, size: contentSize, window: window, screen: screen)
        let glides = animated || (changing && !reduceMotion)
        anchor = choice.anchor
        guard frame != panel.frame else { return }
        if glides {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.settled() }
            }
        } else {
            panel.setFrame(frame, display: true)
            settled()
        }
    }

    /// Polls for the button coming up — the window's drag is the window server's, and its mouse-up
    /// never reaches the app — then places again, which glides to the corner it held off from. Runs
    /// only while a change of corner is waiting.
    private func waitForRelease() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                timer.invalidate()
                self?.releaseWatch = nil
                self?.place(animated: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private func settled() {
        panel?.invalidateShadow()
    }

    private func contentMeasured(_ size: CGSize) {
        let size = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if !state.showsPill { openHeight = size.height }
        place(animated: false)
    }

    // MARK: Dragging to another corner

    /// The header follows the pointer, moved here rather than by AppKit.
    ///
    /// **Not `isMovableByWindowBackground`.** That drag moves the panel while it is still the satellite's
    /// child, which keeps re-applying its offset from the window, and its end can only be found by
    /// polling the mouse — together a visibly juddering drag. Moving the frame on each drag event, with
    /// the panel let go of its satellite until the drop, is exactly as smooth as the events are.
    func dragChanged() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (pointer, panel.frame.origin)
            panel.parent?.removeChildWindow(panel)
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                     y: start.origin.y + pointer.y - start.pointer.y))
        guard let geo = geometry(),
              let anchor = CanvasCompanionPlacement.nearest(to: panel.frame, size: openSize, window: geo.window,
                                                            screen: geo.screen, header: CanvasSatelliteWindow.headerHeight)
        else { return hideGhost() }
        guard anchor != ghostAnchor else { return }
        hideGhost()
        ghostAnchor = anchor
        ghostShown = 1 - ghostShown
        let (window, screen) = geo
        let target = CanvasCompanionPlacement.frame(at: anchor, size: contentSize, window: window, screen: screen)
        let toCentre = CGVector(dx: screen.midX - target.midX, dy: screen.midY - target.midY)
        let length = max(hypot(toCentre.dx, toCentre.dy), 0.0001)
        ghosts[ghostShown].show(at: target, fadingToward: CGVector(dx: toCentre.dx / length, dy: toCentre.dy / length),
                                below: panel)
    }

    private func hideGhost() {
        if ghostAnchor != nil { ghosts[ghostShown].hide() }
        ghostAnchor = nil
    }

    /// Let go: the nearest corner with room becomes this window's spot, and the panel glides into it.
    func dragEnded() { endDrag(snapping: true) }

    private func endDrag(snapping: Bool) {
        guard dragStart != nil else { return }
        dragStart = nil
        hideGhost()
        guard let panel, let window = satellite?.window else { return }
        if snapping, let key = spotKey, let geo = geometry(),
           let anchor = CanvasCompanionPlacement.nearest(to: panel.frame, size: openSize, window: geo.window,
                                                         screen: geo.screen, header: CanvasSatelliteWindow.headerHeight) {
            CanvasCompanionSpots.setSpot(anchor, for: key)
        }
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        place(animated: true)
    }

    // MARK: Keyboard

    func windowDidResignKey(_ notification: Notification) {
        panel?.acceptsKey = false
    }

    private func giveKeyboardBack() {
        satellite?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Construction

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: contentSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false   // hidden, and taken off its satellite, by `hide`
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        panel.delegate = self
        let hosting = NSHostingView(rootView: makeView())
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func makeView() -> CanvasCompanionView {
        CanvasCompanionView(
            store: store ?? StoreRegistry.shared.emptyStore,
            state: state,
            onSize: { [weak self] size in self?.contentMeasured(size) },
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() },
            onNeedsKeyboard: { [weak self] in self?.panel?.takeKey() },
            onDoneTyping: { [weak self] in self?.giveKeyboardBack() },
            onOpenProject: { [weak self] in WindowManager.shared.open(projectKey: self?.store?.boundKey) }
        )
    }

    static let windowIdentifier = "PMSatelliteCompanion"
}

/// The corner you dragged the companion to, per satellite window, across launches. In user defaults
/// beside `CanvasSatellites`, keyed the way it keys a window: canvas, workspace, and the window's first
/// card.
enum CanvasCompanionSpots {
    static let defaultsKey = "PMCompanionSpots"

    struct Key: Equatable {
        var canvas: URL
        var workspace: String
        var window: String

        var string: String { [canvas.standardizedFileURL.path, workspace, window].joined(separator: "\u{1}") }
    }

    static func spot(_ key: Key) -> CanvasCompanionPlacement.Anchor? {
        spot(key, in: .standard)
    }

    static func spot(_ key: Key, in defaults: UserDefaults) -> CanvasCompanionPlacement.Anchor? {
        (defaults.dictionary(forKey: defaultsKey)?[key.string] as? String).flatMap(CanvasCompanionPlacement.Anchor.init)
    }

    static func setSpot(_ anchor: CanvasCompanionPlacement.Anchor, for key: Key, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: defaultsKey) ?? [:]
        all[key.string] = anchor.rawValue
        defaults.set(all, forKey: defaultsKey)
    }
}
