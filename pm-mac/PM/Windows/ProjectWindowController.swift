import AppKit
import SwiftUI

/// One project window: a real Mac window with a hidden titlebar and a full-size content view. The
/// traffic lights float over the sidebar, the content runs to the top of the frame, and the title is
/// still set (invisible) so window tabs, the Window menu and ⌘` all name the project properly.
///
/// This used to have a second chrome — the app's original borderless HUD, offered as a window-style
/// setting. That chrome now belongs to the focus panel, which is the surface it was always describing,
/// so a project window is unconditionally a window.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The project this window shows. Changing it is `retarget(to:)`, not a write.
    private(set) var projectKey: String?
    private(set) var store: PMStore

    let state = ProjectViewState()
    private let split: ProjectSplitViewController

    /// Called when the window has closed, so `WindowManager` can drop it.
    var onClose: ((ProjectWindowController) -> Void)?
    /// Asks to open a project — in this window or a new one. Supplied by `WindowManager`.
    var onOpenProject: ((String, Bool) -> Void)?

    init(projectKey: String?, store: PMStore, startsWithSidebar: Bool, remembersFrame: Bool) {
        self.projectKey = projectKey
        self.store = store

        split = ProjectSplitViewController(store: store, state: state,
                                           startsWithSidebar: startsWithSidebar)

        let window = TextFocusWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: ProjectWindow.minContentWidth + ProjectWindow.sidebarWidth,
                                height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Things' chrome: no toolbar, no visible title, content running under the titlebar. The title
        // is still *set* below — `titleVisibility` only hides it from the titlebar, while tabs, the
        // Window menu and ⌘` all keep reading it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: ProjectWindow.minContentWidth,
                                       height: ProjectWindow.minWindowHeight)
        // A ceiling on width, none on height. A task list gains from every extra row it can show and
        // nothing from being stretched sideways across a large display, so the window stops widening
        // where the content stops benefiting — see `ProjectWindow.maxWindowContentWidth`.
        window.contentMaxSize = NSSize(width: ProjectWindow.maxWindowContentWidth,
                                       height: .greatestFiniteMagnitude)
        // No full screen, because there's nothing for it to do: a window that can't pass 1120pt wide
        // would sit pinned at that width in the middle of an otherwise empty display. With
        // `.fullScreenNone` the green button reverts to plain zoom — grow to the maximum — which is the
        // honest affordance for a window with a maximum. (Full-height is still free: only width is
        // capped, so zoom takes the whole screen vertically.)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingIdentifier = ProjectWindow.tabbingIdentifier
        window.tabbingMode = .automatic
        // An empty toolbar, purely for its geometry. A window with one gets the taller unified titlebar
        // and the lower, further-inset traffic lights that go with it — the proportions every current
        // Mac app has. Without a toolbar you get the compact titlebar, with the buttons tucked hard
        // into the corner.
        //
        // It has no delegate and therefore no items, `titlebarAppearsTransparent` keeps it from drawing
        // a background, and the split items' `titlebarSeparatorStyle = .none` keeps it from drawing a
        // line. So it costs nothing visually and is not a toolbar in the UI sense.
        //
        // A titlebar accessory is the obvious-looking alternative and doesn't work: an accessory with
        // `layoutAttribute = .top` adds a strip *below* the titlebar (Safari's bookmarks bar) without
        // making the titlebar itself taller or moving the window buttons. The unified toolbar is the
        // supported route to these metrics, so this is the intended API rather than a trick — the only
        // oddity is having no items in it. Nothing exposes it to the user: customization is off and the
        // app's hand-built menus offer no Show/Hide Toolbar, so it can't be toggled out from under the
        // header. And if it ever were, `measureTitlebarButtons` re-runs on the resize and the header
        // follows the new geometry rather than holding the old one.
        let toolbar = NSToolbar(identifier: "PMProjectTitlebar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)

        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(ProjectWindow.windowIdentifier)

        // Wire the content's callbacks now that `self` exists.
        state.openProject = { [weak self] key, inNewWindow in
            self?.onOpenProject?(key, inNewWindow)
        }
        state.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        // Publish "a field has the keyboard" into the shared state, which is what stands the window's
        // own ⌘A / ⌘C / ⌘Z / ⌘⌫ down while you're typing — see `ProjectViewState.isEditingText`.
        // Deferred by a turn of the run loop because AppKit changes the first responder from inside
        // SwiftUI's own focus update, and publishing into an `ObservableObject` from there is a write
        // during a view update. A turn is far quicker than the next keystroke.
        window.onTextFocusChange = { [weak self] editing in
            afterCurrentUpdate {
                guard let self, self.state.isEditingText != editing else { return }
                self.state.isEditingText = editing
            }
        }

        // One remembered frame for project windows, not one per project. A window is a window: it has
        // the size and place you last left it at, and pointing it at a different project doesn't move
        // or resize it. It used to autosave under `PMProject:<key>`, which meant every project carried
        // its own geometry — so the same window jumped and resized as you switched projects in it, and
        // each project's first window opened somewhere unrelated to where you were working.
        //
        // Only the window that opens with nothing else already up claims that frame. Later windows are
        // cascaded off it by `WindowManager` and deliberately don't write back, or every "Open in New
        // Window" would walk the remembered frame further down the screen.
        //
        // `setFrameAutosaveName` has to come after the window exists and before it's shown. Placement is
        // decided here rather than left to `NSWindowController`'s own cascade, which interacts with a
        // frame autosave name in ways that differ between the first window and later ones: centred by
        // default, the remembered frame instead when there is one, and `WindowManager` steps any
        // additional window off the one in front.
        shouldCascadeWindows = false
        window.center()
        if remembersFrame {
            window.setFrameAutosaveName("PMProject")
            window.setFrameUsingName("PMProject")
            // A frame saved before the cap existed — or under a taller titlebar — can be wider than
            // the cap allows. `setFrameUsingName` restores it verbatim rather than constraining it, so
            // the first window after an upgrade would open wider than the user could ever drag it.
            let capped = window.frameRect(forContentRect:
                NSRect(x: 0, y: 0, width: ProjectWindow.maxWindowContentWidth, height: 100)).width
            if window.frame.width > capped {
                var frame = window.frame
                frame.size.width = capped
                window.setFrame(frame, display: false)
            }
        }

        applyTitle()
        applyWindowSettings()

        // Measure before the first frame is drawn, not after the window is ordered in. The defaults in
        // `ProjectViewState` are only starting guesses — 92pt of traffic lights and a compact
        // titlebar's 13pt drop — so measuring in `show()` meant the header was laid out against the
        // guess and then visibly settled onto the real numbers as the window opened. `layoutIfNeeded`
        // forces the theme frame to place its buttons, which is what makes them measurable this early.
        window.layoutIfNeeded()
        measureTitlebarButtons()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Presentation

    func show() {
        showWindow(nil)
        // Already measured in the initialiser; this catches a window restored to a frame (or a screen)
        // that changes the chrome between construction and appearing.
        measureTitlebarButtons()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Publish where the window's traffic lights actually sit, so the leftmost pane's header can start
    /// past them and sit level with them.
    ///
    /// Re-run on everything that can move them, not once on open. A window's chrome is not a constant:
    /// full screen takes the titlebar away entirely, joining a tab group adds a bar that moves the
    /// content area, and a resize can bring either about. Measured only in `show()`, a window that went
    /// full screen kept a titlebar-sized gap above a header with no titlebar over it, and the same
    /// stale-constant problem the measurement exists to avoid came back by another route.
    private func measureTitlebarButtons() {
        guard let window, let content = window.contentView else { return }
        // Full screen has no titlebar over the content and no traffic lights sitting in it, so the
        // header wants neither the leading inset nor the vertical drop. Asking the buttons where they
        // are here answers for the auto-hiding bar, which is not where the content is.
        guard !window.styleMask.contains(.fullScreen) else {
            publishTitlebarMetrics(inset: 0, centerY: 0)
            return
        }
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return }
        // Measured in the content view's own space, not the window's. The header is laid out from the
        // top of the content view, and that is not reliably the top of the window frame — a tab bar
        // moves one and not the other, and a window-frame-relative drop puts the header the height of
        // the tab bar out of true.
        //
        // AppKit's coordinates are bottom-left and the views' are top-down, hence the flip through the
        // content view's height for "how far down from the top are these buttons centred".
        let inset = content.convert(zoom.bounds, from: zoom).maxX + 12
        let box = content.convert(close.bounds, from: close)
        publishTitlebarMetrics(inset: inset, centerY: content.bounds.height - box.midY)
    }

    /// Write measurements through to the view state, ignoring sub-point noise so a live resize doesn't
    /// republish (and re-lay-out the whole column) on every frame for a value that hasn't moved.
    private func publishTitlebarMetrics(inset: CGFloat, centerY: CGFloat) {
        if inset >= 0, abs(state.leadingTitlebarInset - inset) > 0.5 {
            state.leadingTitlebarInset = inset
        }
        if centerY >= 0, abs(state.titlebarButtonCenterY - centerY) > 0.5 {
            state.titlebarButtonCenterY = centerY
        }
    }

    // MARK: Retargeting

    /// Show a different project in this window. The store is swapped (stores are shared per project),
    /// the title follows, and the new project becomes the global focus since this window is the one in
    /// front. The window itself doesn't move: what it's showing changed, not which window it is.
    func retarget(to newStore: PMStore, projectKey newKey: String?) {
        guard newKey != projectKey else { return }
        projectKey = newKey
        store = newStore
        split.retarget(to: newStore, projectKey: newKey)
        applyTitle()
        pushFocusToDisk()
    }

    /// Put the sidebar's selection back on the project this window is actually showing. Used when a
    /// switch doesn't happen after all — the project turned out to be open in another window, which
    /// comes forward instead (see `WindowManager.retarget`).
    func syncSidebarSelection() {
        state.projectSelection = projectKey.map { [$0] } ?? []
    }

    /// The window's title — invisible in the titlebar, but what the Window menu, ⌘`, and the tab bar
    /// all show. The subtitle carries progress, which is where the header's "3/8" goes in a window.
    func applyTitle() {
        guard let window else { return }
        let title = store.notes?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title?.isEmpty ?? true) ? store.projectName : title
        window.title = name ?? "PM"
        let p = store.progress
        window.subtitle = p.total > 0 ? "\(p.done) of \(p.total) done" : ""
    }

    // MARK: Settings

    /// Float project windows above other apps' windows, if the user asked for it. "Show on all Spaces"
    /// is deliberately *not* here — it belongs to the focus panel, which is the surface that's meant to
    /// follow you around. A full editor window that shadows you onto every desktop is a nuisance, not a
    /// feature.
    func applyWindowSettings() {
        window?.level = WindowSettings.shared.floatAboveOthers ? .floating : .normal
    }

    // MARK: Sidebar

    /// The header's toggle, routed through the split view so it animates and persists in one place.
    /// Show the project list and put the keyboard in it — File ▸ All Projects…, which is "browse
    /// everything" rather than "toggle a pane", so it only ever opens the sidebar.
    func revealProjectList() {
        if isSidebarCollapsedNow { split.toggleSidebar(nil) }
        state.requestFocusProjectList()
    }

    private var isSidebarCollapsedNow: Bool { !isSidebarVisible }

    func toggleSidebar() {
        split.toggleSidebar(nil)
    }

    var isSidebarVisible: Bool { !split.isSidebarCollapsed }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        pushFocusToDisk()
        // Joining or leaving a tab group moves the content area without resizing the window, and there
        // is no delegate callback for it. Becoming main is the moment that always follows.
        measureTitlebarButtons()
    }

    /// The chrome-change hooks. All three land in the same place: whatever moved, re-ask the buttons
    /// where they are. The measurement is two coordinate conversions and `publishTitlebarMetrics`
    /// swallows sub-point changes, so running it on every frame of a live resize costs nothing.
    func windowDidResize(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowWillClose(_ notification: Notification) {
        split.prepareForClose()
        onClose?(self)
    }

    /// ⌘T and the tab bar's `+`. A tab on the project this window already shows would be a duplicate,
    /// so New Tab means "another project alongside this one": the most recent one that isn't open yet,
    /// added to this window's tab group.
    @objc override func newWindowForTab(_ sender: Any?) {
        guard let key = WindowManager.shared.nextUnopenedProjectKey else { return }
        WindowManager.shared.open(projectKey: key, asTabOf: self)
    }

    // MARK: Menu commands answered by this window

    /// File ▸ New Task. The content opens its inline add editor; the window can't do it directly, so it
    /// nudges the shared state and the view responds.
    @objc func newTask(_ sender: Any?) {
        state.requestNewTask()
    }

    /// File ▸ New Session. Same hand-off as New Task: the content opens today's session's note.
    @objc func newSession(_ sender: Any?) {
        state.requestNewSession()
    }

    /// Open the project's details form — the summary, problem, goals, approach and learnings, which
    /// were five separate Raycast forms and are one brief here. Same hand-off again.
    ///
    /// Deferred by a turn, unlike the two above, because the quick bar's `>details` may have opened
    /// this window a moment ago: a counter bumped before the content's first body pass is a change
    /// `onChange` never sees, and the request would be dropped. (The New Session hand-off can be
    /// reached the same way from the menu bar and takes that chance today.)
    func editDetails() {
        afterCurrentUpdate { [weak self] in self?.state.requestEditDetails() }
    }

    /// Edit ▸ Find ▸ Find…. Opens the window's find bar and puts the cursor in it.
    @objc func performFindPanelAction(_ sender: Any?) {
        state.requestFind()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newTask(_:)), #selector(newSession(_:)), #selector(performFindPanelAction(_:)):
            return store.projectName != nil
        case #selector(newWindowForTab(_:)):
            // Nothing to open if every project is already on screen.
            return WindowManager.shared.nextUnopenedProjectKey != nil
        default:
            return true
        }
    }

    /// The frontmost window owns the global focus, so the CLI, Raycast and the menubar all follow
    /// whichever project you're looking at.
    private func pushFocusToDisk() {
        guard let projectKey, projectKey != PMFiles.focusedProjectKey() else { return }
        PMStore.setGlobalFocus(key: projectKey) {
            // The watcher will see the write too, but that's debounced by up to a second; nudging the
            // menubar here makes the switch feel immediate.
            (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        }
    }
}

/// The project window itself: an `NSWindow` that reports whether a text editor holds the keyboard.
///
/// `makeFirstResponder` is the one funnel every focus change goes through — a SwiftUI `TextField`
/// taking the keyboard makes its *field editor* (an `NSTextView`) the responder, the note editor's own
/// text view goes the same way, and moving focus back to a list swaps in a plain view. So watching it
/// answers "is the user typing" for every field in either pane, present or future, without the panes
/// having to declare themselves.
///
/// Why the window needs to answer that at all: see `ProjectView.keyboardShortcuts`. In short, SwiftUI
/// key equivalents are offered the keystroke before the main menu is, so the content's commands have to
/// stand aside for the field rather than trusting Edit ▸ Select All to get there first.
final class TextFocusWindow: NSWindow {
    /// Called on every first-responder change with whether the new one is an editable text view.
    var onTextFocusChange: ((Bool) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        // Read back `firstResponder` rather than trusting the argument: handing a window an
        // `NSTextField` installs the shared field editor instead, and that editor is the responder the
        // keystrokes actually reach.
        onTextFocusChange?((firstResponder as? NSText)?.isEditable ?? false)
        return accepted
    }
}
