import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import PmLib

/// A canvas, with its chrome, as a view controller — what a project window puts in the content pane
/// its task list would otherwise be in.
///
/// Everything about showing and driving a board lives here: the scroller, the floating header, the
/// notice banner, find, the page controls, and the page budget's answer to nobody looking. What is left
/// outside is what genuinely belongs to a window — its frame, its title, its tabs — which is why this
/// exists at all.
///
/// The store is **not** created here. Two surfaces can be showing the same file, so the store comes from
/// `CanvasStoreRegistry` and the owner is responsible for taking and giving back its hold — see
/// `teardown`.
@MainActor
final class CanvasPaneController: NSViewController, NSMenuItemValidation {
    let store: CanvasDocumentStore
    private let scroll: CanvasScrollView
    private let notice = CanvasNoticeBar()
    private let container = CanvasPaneContainer()

    /// Everything the header shows and everything its controls do. Exposed so an owner can put its own
    /// commands in the options menu — a project window adds the switch back to its task list.
    let header = CanvasHeaderModel()
    private var pill: NSHostingView<CanvasTitlePill>!
    private var capsule: NSHostingView<CanvasHeaderTrailingChrome>!
    private var tabBar: NSHostingView<CanvasTabBar>!
    /// Which part of the board this pane is pinned to. `.whole` is a plain board and behaves exactly as
    /// one; the other two are a tab that was opened *at* something.
    var focus: CanvasFocus = .whole

    /// The tabs of the window this board is in.
    ///
    /// **Not optional, and that is the whole of what retiring the separate canvas window bought.** A
    /// board used to be able to be in a window that had no tabs, so every feature reached through them
    /// — opening a frame beside its board, naming a workspace, pinning either — carried an "except
    /// there" clause, and the menu items for them appeared or didn't depending on which window you were
    /// in. Every board is in a project window now, so there is one answer.
    let tabModel: ProjectTabModel
    private var pillLeading: NSLayoutConstraint!

    /// How far the header's leading edge starts in from the pane's own edge.
    ///
    /// Normally the window's traffic lights decide it. A project window's sidebar holds those buttons
    /// over *itself*, so a board in that window's content pane wants no inset at all — the same
    /// reasoning, and the same answer, as the task column's header.
    var ignoresTrafficLights = false {
        didSet { measureTitlebar() }
    }

    init(store: CanvasDocumentStore, tabs: ProjectTabModel) {
        self.store = store
        self.tabModel = tabs
        scroll = CanvasScrollView(store: store)
        super.init(nibName: nil, bundle: nil)

        // The board's own menus reach the window's tabs through these.
        scroll.board.onOpenInTab = { [tabModel] focus in
            switch focus {
            case .whole: tabModel.openBoard()
            case .frame(let id): tabModel.openFrame(id)
            case .note: tabModel.openNotes()
            case .workspace(let name): tabModel.openWorkspace(name)
            }
        }
        scroll.board.onSaveWorkspace = { [weak self] name in self?.saveWorkspace(as: name) }
        scroll.board.onRemoveWorkspace = { [weak tabs] name in tabs?.deleteWorkspace(name) }
        scroll.board.onRenameWorkspace = { [weak tabs] name in tabs?.renameWorkspace(name) }
        scroll.board.onGoToWorkspace = { [weak self] name in self?.goToWorkspace(named: name) }
        scroll.board.workspaceNames = { [weak self] in self?.workspaceNames() ?? [] }
        scroll.board.onDuplicateWorkspace = { [weak tabs] name in tabs?.duplicateWorkspace(name) }
        // ⌘↩ on an untiled board: the tiling it is about to make is a workspace, and a workspace is a
        // tab. See `ProjectSplitViewController.tileAsWorkspace`.
        scroll.board.onTileAsWorkspace = { [tabModel] tiling in tabModel.tileAsWorkspace(tiling) }
        // ⌘−, and ⌘↩ with nothing left to narrow. A workspace is a place you were, not a state to
        // undo, so leaving one is going to the canvas — see `ProjectSplitViewController.goToCanvas`.
        scroll.board.onGoToCanvas = { [tabModel] in tabModel.goToCanvas() }

        wireHeader()
        scroll.board.onPageStateChanged = { [weak self] in self?.pageStateChanged() }
        scroll.board.onTilingChanged = { [weak self] in
            guard let self else { return }
            header.tiling = scroll.board.tilingSummary
            header.arrangement = scroll.board.tiling?.arrangement
            refreshTileCommand()
            rememberViewState()
            keepNamedWorkspaceUpToDate()
            // Derived rather than declared. It used to be set once, on the way in, which was fine
            // while the note view was a place you could only leave through the switch. Now that
            // leaving is a tiling command it has to be able to stop being true — and to *start* being
            // true when you tile the project's own card by hand on the whole board, which is the same
            // view arrived at from the other end.
            scroll.board.isProjectNoteView = isShowingProjectNoteAlone
            // The tab wears this too, and in a window with a bar it is the *only* place it is worn.
            onTilingChanged?()
        }
        // The header's tiling button says what it is about to do — "Fill Window with These 6 Cards" —
        // so it has to hear about the selection. Nothing was listening to this before; the board fired
        // it into an unset closure.
        scroll.board.onSelectionChanged = { [weak self] _ in self?.refreshTileCommand() }
        // The pane's own width, which is what the capsule has to fit inside — not the window's, since a
        // project window's sidebar takes a bite out of it.
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(paneResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: container)
        // Something happened that the board itself cannot show: a file downloaded, a link handed to
        // another app, a page refused the camera. The notice bar is where this window says things the
        // board can't, and it is the only surface a card can reach.
        scroll.board.onReport = { [weak self] message, file in
            self?.say(message, reveal: file)
        }
        scroll.board.onFocusAddress = { [weak self] in
            self?.header.addressFocusToken &+= 1
        }
        scroll.board.onRefreshIntervalChanged = { [weak self] in self?.rememberViewState() }
        scroll.board.onModeChanged = { [weak self] in
            guard let self else { return }
            // The mode is flipped from the View menu and from the header's options, so the header
            // follows the board rather than being the only thing that knows.
            header.mode = scroll.board.mode
            rememberViewState()
        }
        store.addWatcher(self,
                         changed: { [weak self] in self?.documentChanged() },
                         reloaded: { [weak self] in self?.noteOutsideChange() })
        // Filtering is verified after launch, which is usually after this pane exists.
        NotificationCenter.default.addObserver(
            self, selector: #selector(blockingHealthChanged),
            name: CanvasContentBlocker.healthChanged, object: nil)
        notice.onDismissedByUser = { [weak self] in self?.hidBlockingNotice = true }
        // Asked once here because the document is already in the store: a board that opens without its
        // project note has to offer it from the first time the `+` is pulled down, not from the first
        // edit.
        refreshProjectNoteOffer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// What the board's name is called in the header's pill.
    var title_: String {
        get { header.title }
        set { header.title = newValue }
    }

    override func loadView() {
        buildContent()
        container.onCoveredRegionChange = { [weak self] in self?.coveredRegionChanged() }
        view = container
    }

    /// Give up the board, and the document with it.
    ///
    /// Called by whoever owns this pane when it is finished with — a window closing, or a project
    /// window switching back to its task list. Explicit rather than in `deinit` because the registry is
    /// main-actor work and a hold given back late is a store that goes on polling a file nobody is
    /// looking at.
    func teardown() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopWatchingTheWindow()
        scroll.board.pauseAllPages()
        scroll.board.releaseCards()
        store.removeWatcher(self)
        CanvasStoreRegistry.release(store)
    }

    // MARK: Appearing, and being switched away from


    override func viewDidAppear() {
        super.viewDidAppear()
        watchTheWindow()
        view.window?.layoutIfNeeded()
        measureTitlebar()
        paneResized()
        fitWhenThereIsAWindowToFitTo()
        if let opening = openingNotice {
            openingNotice = nil
            say(opening.message, reveal: opening.file)
        }
    }

    /// Frame the board the first time this pane has a window to frame it in.
    ///
    /// Deferred a runloop turn because "fit" is computed against the clip view, and asked during
    /// `viewDidAppear` that is a view AppKit has not laid out yet. **The turn is not a guarantee**, and
    /// treating it as one is what left boards opening in the corner: a pane that appears inside a
    /// window still sizing itself — switching to a project whose canvas tab was never front, most of
    /// all — comes back from the hop with the same zero-width clip, `zoomToFit` quietly did nothing,
    /// and the latch was already set. The board then sat at the origin of its own frame, which is
    /// 1600pt of `CanvasBoardView.margin` above and left of the nearest card: scrollers pinned to the
    /// top-left, every card off the bottom-right, and only ⌘0 to get back. Canvas-backlog item 1.
    ///
    /// So the latch waits for `zoomToFit` to say it fitted, and `paneResized` asks again — which is the
    /// notification that fires when the pane finally gets a size, so the retry costs nothing and needs
    /// no clock.
    ///
    /// Restoring the view state waits on the same answer, for the reason `restoreViewState` gives: a
    /// tiling laid out for a window of no width is not a tiling anyone wants back.
    private func fitWhenThereIsAWindowToFitTo() {
        guard !hasFitted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !hasFitted, scroll.zoomToFit() else { return }
            restoreViewState()
            applyFocus()
            // **Last, which is what `isSettled` has always claimed.** The latch used to be set first,
            // and a tiling restored or focused between there and here would announce itself to a tab
            // that then read the half-built board as the answer — retargeting a notes tab to the whole
            // board a beat before the card it wanted was tiled. Nothing can interleave inside this
            // block, so the only thing moving it costs is the window of wrongness it closes.
            hasFitted = true
            view.window?.makeFirstResponder(scroll.board)
        }
    }

    /// Whether this pane has fitted, restored and applied its focus — see `fitWhenThereIsAWindowToFitTo`.
    ///
    /// **Asked before a tab is allowed to follow its board.** A pane pinned to a workspace spends a
    /// runloop turn or more knowing nothing about it, and a tab reconciled against that pane in the
    /// meantime would read "in no workspace" and throw the pin away before it was ever applied. See
    /// `ProjectSplitViewController.reconcileTabsWithTheirBoards`.
    var isSettled: Bool { hasFitted }

    private var hasFitted = false

    /// Whether this board is tiled to the project's own card and nothing else.
    ///
    /// **The note view, however you arrived at it** — restored into a `.note` tab, or built by hand on
    /// the whole board by tiling that one card. Since the switch went there is no other definition
    /// available: "am I looking at this project's notes" is a question about what is on screen, not
    /// about which door you came through, and a tab is made to agree with the answer (see
    /// `ProjectSplitViewController.reconcileTabsWithTheirBoards`).
    var isShowingProjectNoteAlone: Bool {
        guard let ids = scroll.board.tiling?.ids, ids.count == 1, let tiled = ids.first,
              let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url)
        else { return false }
        return CanvasProjectNoteCard.id(on: store.document, notes: notes,
                                        resolver: store.resolver) == tiled
    }

    // MARK: How you were looking at this board

    /// What is worth remembering about the way this board is being looked at. See `CanvasViewState`.
    /// **What is left of this row is how you were looking at the board, and nothing about workspaces.**
    ///
    /// It used to carry the tiling that was up and its name, because a tiling could exist with nothing
    /// pointing at it — that was the untitled workspace, and this was where it lived. §7i retired it:
    /// every tiling is a named workspace, named workspaces live in `CanvasWorkspaces`, and the pane
    /// that owns this row is the canvas tab's, which is never tiled. `lastTiling` stays, and is now the
    /// only thing here about tiles — it is what makes ⌘Return on the same six cards pick up the order
    /// and the widths you left them in rather than starting over.
    private var viewState: CanvasViewState {
        CanvasViewState(mode: scroll.board.mode,
                        refreshInterval: scroll.board.refreshInterval,
                        lastTiling: scroll.board.tilingMemory)
    }

    /// Put back what was up last time this board was open.
    ///
    /// After the fit rather than before it, and that is not just an ordering detail: a tiling is laid
    /// out in the region the window can show, so tiling a board whose scroller has not been sized yet
    /// lays the tiles out for a window of no width. The fit is already deferred for the same reason.
    ///
    /// Nothing here consults the board's *contents*, so a document that has changed since — under
    /// Obsidian, or under another window on the same file — restores what still exists and drops the
    /// rest. See `CanvasBoardView.restoreTiling`.
    private func restoreViewState() {
        // A pane that was opened *at* something takes its state from what it was opened at, not from
        // how the board was last left. This is also what keeps two tabs on one canvas from fighting
        // over the single row `CanvasViewMemory` keeps per file: only the plain one writes to it.
        //
        // **Settled here, once, rather than re-read from `focus`** — which now moves. A tab follows the
        // board it holds, so the plain tab you named a workspace in becomes a workspace tab
        // (`ProjectSplitViewController.reconcileTabsWithTheirBoards`), and a pane that stopped writing at
        // that moment would stop remembering the connect mode and the refresh interval too. Ownership
        // is about which pane opened the board, not about what its tab has since become.
        guard !hasRestoredViewState else { return }
        hasRestoredViewState = true
        ownsViewMemory = focus == .whole
        guard ownsViewMemory else { return }
        let remembered = CanvasViewMemory.of(store.url)
        scroll.board.mode = remembered.mode
        scroll.board.refreshInterval = remembered.refreshInterval
        // The arrangement comes back even when the board was left untiled, so the next ⌘Return on the
        // same cards picks up where you left off rather than starting over.
        scroll.board.lastTiling = remembered.lastTiling
        // **The tiling in this row is not restored, and used to be.** The pane that owns this row is
        // the canvas tab's (`focus == .whole`), and the canvas is never tiled (§7i) — a workspace is
        // restored by its own tab, out of `CanvasWorkspaces`, through `applyFocus`. A row written
        // before that was true still has a tiling and a name in it; both are simply not read, which is
        // the whole of the migration.
    }

    /// Written on every change rather than on the way out, because there is no reliable way out: a
    /// window closing, the app quitting, a project window switching back to its task list and a crash
    /// are four different paths and only three of them run code.
    ///
    /// Silent until the restore has happened, so the empty state a board starts in cannot overwrite
    /// the state being restored into it.
    private func rememberViewState() {
        guard ownsViewMemory else { return }
        CanvasViewMemory.remember(viewState, for: store.url)
    }

    private var hasRestoredViewState = false
    /// Whether this pane is the one that owns the board's row in `CanvasViewMemory` — see
    /// `restoreViewState`, which is the only thing that decides it.
    private var ownsViewMemory = false

    /// Put the board where this tab says it should be.
    ///
    /// After the fit, for the reason `restoreViewState` is after it: a workspace is laid out in the
    /// region the window can show, and a frame is fitted to the window, so both need a window with a
    /// width. A pin that no longer resolves — a frame deleted, a workspace removed — leaves the
    /// board on the whole canvas rather than on nothing, which is the same answer `restoreTiling` gives
    /// for cards that have gone.
    private func applyFocus() {
        switch focus {
        case .whole:
            break
        case .frame(let id):
            scroll.board.goTo(frame: id)
        case .note:
            goToProjectNote()
        case .workspace(let name):
            goToWorkspace(named: name)
        }
    }

    /// The board, tiled to the project's own card and nothing else — the project window's notes
    /// (docs/canvas-workspaces.md §7d).
    ///
    /// **The card is put back if it isn't there.** Every board `createProjectCanvas` writes starts with
    /// one, and taking it off is a thing you can do — but "show me this project" cannot depend on a
    /// card somebody dragged to the bin last week. Putting it back is the same act the add menu offers
    /// (`Add Project Note`), and it lands in the document, which is right: the note-only view is a
    /// board tiled to a real card, not a special case pretending to be one.
    ///
    /// Nothing happens for a canvas that is not a project's — a board opened straight from a file has
    /// no project note to show, and the window that opened it never asks for this.
    private func goToProjectNote() {
        guard let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url) else { return }
        let existing = CanvasProjectNoteCard.id(on: store.document, notes: notes,
                                                resolver: store.resolver)
        guard let id = existing ?? scroll.board.addProjectNoteCard(at: nil) else { return }
        // `isProjectNoteView` is not set here — tiling says it. See `onTilingChanged` above.
        scroll.board.tile([id])
        // A turn later, because tiling is what builds the card's view. See `engage(cardWithID:)` for
        // why it is stepped into rather than waiting for a click.
        afterCurrentUpdate { [weak self] in self?.scroll.board.engage(cardWithID: id) }
    }

    /// Aim a project command at this project's own card, for a command that arrived at the *window*
    /// rather than at a card you are standing in — the quick bar's `>session` and `>details`, and the
    /// menubar's New Session, all of which open a window and then ask it for something.
    ///
    /// The card you are in still wins, on the rule every project command on a board follows: inside a
    /// card, a command means the card. Otherwise it is the project's own note card, engaged first —
    /// the card's editors are gated on engagement, so one told to start a session while stepped out
    /// would open a takeover and close it again the moment the step-out was noticed.
    ///
    /// Nil-safe rather than card-making: a board whose project card has been deleted is a command with
    /// nothing to act on, which is not a reason to put the card back.
    ///
    /// A turn late when it has to engage, because engagement is what builds the card's SwiftUI body,
    /// and a request counter bumped before that body's first pass is a change `onChange` never sees.
    func aimAtProjectCard(_ act: @escaping (CanvasProjectCardCommands) -> Void) {
        if let engaged = scroll.board.engagedProjectCard { return act(engaged.projectCommands) }
        guard let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url),
              let id = CanvasProjectNoteCard.id(on: store.document, notes: notes,
                                                resolver: store.resolver)
        else { return }
        scroll.board.engage(cardWithID: id)
        afterCurrentUpdate { [weak self] in
            guard let card = self?.scroll.board.engagedProjectCard else { return }
            act(card.projectCommands)
        }
    }

    // MARK: What the window's tabs need from a board

    /// Told when this board tiles or untiles, so the tab holding it can re-title itself.
    var onTilingChanged: (() -> Void)?

    /// What a tiled view here is showing, long and short — what the tab puts after its name.
    var tilingSummary: (long: String, short: String)? { header.tiling }

    /// The name to put on a tab pinned to this frame.
    func frameName(_ id: String) -> String? { scroll.board.frameLabel(id) }

    /// Every frame the add menu could offer, in reading order.
    func frames() -> [ProjectTabItem] {
        scroll.board.frameChoices.map { ProjectTabItem(id: $0.id, name: $0.name) }
    }

    /// Every named workspace on this board.
    func workspaceNames() -> [String] { CanvasWorkspaces.names(of: store.url) }

    /// The name of the workspace the board is in, for whoever is drawing it.
    var workspaceName: String? { scroll.board.workspaceName }

    /// Name the workspace that is up, which is what promotes it out of `CanvasViewMemory` and keeps it.
    ///
    /// The board is told its own name last, and that is the visible half of the act: until now naming
    /// a workspace changed nothing you could see, which is most of why it read as not having worked.
    func saveWorkspace(as name: String) {
        guard let tiling = scroll.board.tilingMemory else { return }
        // Acquiring a name that is taken is replacing the workspace that has it, and that workspace is
        // not this one — see `WorkspaceNamePrompt.confirmReplacing`.
        guard name == scroll.board.workspaceName || !CanvasWorkspaces.exists(name, of: store.url)
                || WorkspaceNamePrompt.confirmReplacing(name)
        else { return }
        CanvasWorkspaces.save(tiling, as: name, for: store.url)
        scroll.board.workspaceName = name
        // The chip has to become this workspace's chip, and naming is the one act that changes which
        // workspace a tab is in without changing the tiling — so nothing else would tell the bar.
        onTilingChanged?()
    }

    /// Switch to one.
    ///
    /// **The tab it is already open in, if it is open in one.** Two chips on one workspace are two
    /// names for one thing, so switching goes to the chip that exists rather than retiling this board
    /// into a second copy of it — the same answer `WindowManager` gives for a project that already has
    /// a window (docs/canvas-workspaces.md §7c).
    ///
    /// Silent about a name that is not there any more, which is the same answer `applyFocus` gives: a
    /// workspace deleted in another window is a stale menu, not a reason to do something drastic.
    func goToWorkspace(named name: String) {
        guard !tabModel.selectWorkspace(name) else { return }
        guard let tiling = CanvasWorkspaces.tiling(named: name, of: store.url) else { return }
        scroll.board.restoreTiling(tiling, named: name)
    }

    /// A workspace was renamed from somewhere else in this window — a chip's menu, on this tab or
    /// another. A board that is *in* the one that moved follows it; a board that is not is untouched.
    func workspaceRenamed(from old: String, to new: String) {
        if scroll.board.workspaceName == old { scroll.board.workspaceName = new }
    }

    /// **The write-through, and the whole of "adjusting one is not saving one".**
    ///
    /// A named workspace is live: drag a tile, pin a width, promote a master, and it lands on the
    /// workspace as you do it. No Save, no dirty mark, no Revert — the same decision `DetailsEditor`
    /// made for the brief, for the same reason (docs/canvas-workspaces.md §7b).
    ///
    /// **Only at the root of the tiling**, which is the guard that makes the rest safe. Drilling into
    /// one tile of a six-tile workspace is a temporary narrowing that Escape unwinds; writing it
    /// through would reduce the workspace to that one tile, permanently and with nothing to undo it
    /// with. `leaveTiling` already reasons this way about what is worth keeping — it remembers the
    /// root of the drill-in stack rather than the tile you left through.
    private func keepNamedWorkspaceUpToDate() {
        guard let name = scroll.board.workspaceName,
              scroll.board.tilingHistory.isEmpty,
              let tiling = scroll.board.tilingMemory
        else { return }
        CanvasWorkspaces.save(tiling, as: name, for: store.url)
    }

    /// Take the keyboard, for an owner that has just put this pane on screen.
    func focusBoard() { view.window?.makeFirstResponder(scroll.board) }

    /// The traffic lights move when the titlebar's height changes and disappear in full screen, and a
    /// window's own resize is not the only thing that moves them — a project window's sidebar opening
    /// does too. Watched here rather than left to a window delegate, because this pane can be inside a
    /// window whose delegate is somebody else's.
    private func watchTheWindow() {
        guard let window = view.window, watchedWindow !== window else { return }
        stopWatchingTheWindow()
        watchedWindow = window
        let centre = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            centre.addObserver(self, selector: #selector(windowGeometryChanged),
                               name: name, object: window)
        }
        centre.addObserver(self, selector: #selector(windowBecameKey),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        centre.addObserver(self, selector: #selector(windowResignedKey),
                           name: NSWindow.didResignKeyNotification, object: window)
    }

    private var watchedWindow: NSWindow?

    private func stopWatchingTheWindow() {
        guard let watchedWindow else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: watchedWindow)
        }
        self.watchedWindow = nil
    }

    @objc private func windowGeometryChanged() { measureTitlebar() }

    /// The sidebar opened or closed, so the region the chrome and the tiles have to stay clear of has
    /// changed. That is a safe-area change and not a frame change — the pane keeps its size and gains a
    /// covered strip — so neither the resize notification nor the clip view's own hook sees it, and it
    /// arrives continuously while the sidebar slides rather than once when the flag flips.
    ///
    /// AppKit reports it on the *view* (`safeAreaInsetsDidChange`), not on the view controller, which is
    /// why the pane's container is a subclass rather than a bare `NSView`.
    fileprivate func coveredRegionChanged() {
        measureTitlebar()
        if scroll.board.isTiled { scroll.board.retileForWindowSize() }
    }

    @objc private func paneResized() {
        let room = CanvasHeaderModel.Room(width: container.bounds.width)
        if header.room != room { header.room = room }
        // The pane getting a size is the event the first fit was waiting for, when it was asked too
        // early to have one. A no-op once it has happened.
        fitWhenThereIsAWindowToFitTo()
    }

    @objc private func windowBecameKey() {
        idleTimer?.invalidate()
        idleTimer = nil
        scroll.board.reviewPageBudget()
        store.checkForOutsideChange()
    }

    /// Looked away. Start the clock — unless the board is tiled, which is exempt.
    ///
    /// **A tiling is the answer to the question the timer is guessing at.** Everything that pauses a
    /// page is a guess about which of them you would miss: the budget guesses from distance and from
    /// how long ago you saw a card, and this guesses from how long the window has been in the
    /// background. A tiled view has no guessing left to do — you named these cards and the window is
    /// showing every one of them, which is the same argument `CanvasPageBudget.liveWhileTiled` already
    /// makes against the budget. It only ever reached here because this asked a question about the
    /// window and never about the board inside it.
    ///
    /// It is a real cost and worth stating: a tiled board left behind your work goes on running its
    /// pages for as long as it is open. That is what a dashboard is, and it is bounded by the tiling —
    /// a handful of cards that fit the window at a readable size, not the forty on the board. Leaving
    /// the tiled view hands it straight back to the budget.
    @objc private func windowResignedKey() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard !scroll.board.isTiled else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleGrace, repeats: false) { _ in
            Task { @MainActor [weak self] in
                // Asked again on the way out as well as on the way in: a board can be tiled from
                // another window's command between the two, and pausing the tiles of a view somebody
                // has just built is the one outcome this must not have.
                guard let self, !self.scroll.board.isTiled else { return }
                self.scroll.board.pauseAllPages()
            }
        }
    }

    /// The board, edge to edge, with the window's chrome floating over it.
    ///
    /// Nothing in this window is a bar. The board fills the content view — under the titlebar, out to
    /// every edge — and the pill, the trailing chrome and the notice banner are laid over it. The pill
    /// and the chrome are **separate hosting views sized to their own contents** rather than one strip
    /// across the top: a strip would hit-test its whole width and swallow every click in the band where
    /// the cards you are reading actually are.
    ///
    /// The trailing view is one hosting view holding both capsules — the board's controls and, when
    /// there is one, the live page's. That pairing is `CanvasHeaderTrailingChrome`'s business rather
    /// than this method's, so the page capsule appearing cannot shift the control capsule off the
    /// window's edge.
    private func buildContent() {
        pill = NSHostingView(rootView: CanvasTitlePill(model: header))
        capsule = NSHostingView(rootView: CanvasHeaderTrailingChrome(model: header))
        // The hosting view is the size SwiftUI says it is, so each view's frame is the pill or the
        // capsule and not a rectangle of window around it. Set one at a time because the two are
        // different generic types and an array of them is an array of `NSView`.
        tabBar = NSHostingView(rootView: CanvasTabBar(model: header, tabs: tabModel))
        pill.sizingOptions = [.intrinsicContentSize]
        capsule.sizingOptions = [.intrinsicContentSize]
        tabBar.sizingOptions = [.intrinsicContentSize]
        // And no safe area, which is the difference between this header sitting *in* the titlebar band
        // and sitting below it. The window has a full-size content view, so AppKit reports the titlebar
        // and toolbar as a top safe area inset — correct for content that should stay clear of the
        // window's chrome, and exactly backwards for chrome that is meant to run up into it. SwiftUI
        // honours that inset inside a hosting view by default, so the pill was starting below the band
        // and then taking its own drop on top: about 66 points of droop for a 14-point offset.
        pill.safeAreaRegions = []
        capsule.safeAreaRegions = []
        tabBar.safeAreaRegions = []
        pill.translatesAutoresizingMaskIntoConstraints = false
        capsule.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(notice)
        container.addSubview(pill)
        container.addSubview(tabBar)
        container.addSubview(capsule)

        // Held so the leading inset can follow the traffic lights, which move with the titlebar's
        // height and vanish in full screen.
        //
        // Against the **safe area**, not the view's own edge, and only on this axis. In a project
        // window the content pane runs *beneath* the floating sidebar — that is the design, and the
        // task column stays clear of it by the leading safe-area inset AppKit supplies. The board
        // should run under it too; its chrome must not, and pinning the pill to the container's raw
        // leading edge put the board's name behind the sidebar.
        //
        // Leading only. The top edge is where this header deliberately runs *into* the titlebar to sit
        // level with the traffic lights, and a top safe area is exactly the inset that would push it
        // back out again — which is the bug this header started life with.
        pillLeading = pill.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor,
                                                    constant: TitlebarButtonMetrics.unmeasured.leadingInset)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            pill.topAnchor.constraint(equalTo: container.topAnchor),
            pillLeading,
            capsule.topAnchor.constraint(equalTo: container.topAnchor),
            capsule.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor,
                                              constant: -14),
            // Between the two, which is the space this header deliberately leaves empty — and the bar
            // is the one thing that has earned it, because it answers the same question the pill does.
            // Its own island, sized to its contents: a strip across the band would hit-test the whole
            // width and swallow clicks on the cards up there. See `ProjectTabBar`.
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: pill.trailingAnchor,
                                            constant: HeaderMetrics.capsuleGap),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: capsule.leadingAnchor,
                                             constant: -HeaderMetrics.capsuleGap),
            // The pill gives way first when the window is too narrow to hold both — the controls have a
            // floor and the title has a truncation.
            pill.trailingAnchor.constraint(lessThanOrEqualTo: capsule.leadingAnchor, constant: -12),

            // Under the chrome rather than level with it, so the banner reads as something the window
            // is telling you about the board rather than as part of the window's controls.
            notice.topAnchor.constraint(equalTo: container.topAnchor, constant: 56),
            notice.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor,
                                            constant: 14),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: container.safeAreaLayoutGuide.trailingAnchor,
                                             constant: -14),
        ])
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The bar gives way before the pill does: a tab chip has a truncation of its own and the
        // project's name does not repeat anywhere else in the column.
        tabBar.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        tabBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        notice.onRepairAll = { [weak self] in self?.repairAllPaths() }
        notice.onReveal = { [weak self] in
            guard let self else { return }
            // What Reveal means depends on what is up: a downloaded file to show in the Finder, or the
            // cards whose files have moved. One button, because there is only ever one notice.
            if let file = event?.file {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                selectMovedCards()
            }
        }
    }

    /// Keep the header level with, and clear of, the window's own buttons.
    ///
    /// The vertical drop is the header's business (see `TitlebarDrop`), because it depends on how tall
    /// each piece turns out to be. The leading inset is this pane's, because it depends on where the
    /// traffic lights are relative to *it* — and there are three answers, not two. A window with its
    /// sidebar hidden puts them over the board, so the pill starts clear of them. Full screen has none, so
    /// it starts at the edge. And with the sidebar showing they sit over the sidebar, which is a
    /// different pane entirely, so again the pill starts at the edge — see `ignoresTrafficLights`.
    private func measureTitlebar() {
        guard pillLeading != nil else { return }
        let metrics = view.window?.titlebarButtonMetrics()
        // `Self.margin` is the floor in every case, so the pill never sits hard against the pane's edge
        // — full screen reports no buttons at all, and a sidebar holding them reports buttons that are
        // over somebody else's pane.
        let inset = ignoresTrafficLights ? Self.margin
            : max(Self.margin, metrics?.leadingInset ?? pillLeading.constant)
        if abs(pillLeading.constant - inset) > 0.5 { pillLeading.constant = inset }
        if let metrics, header.titlebar != metrics { header.titlebar = metrics }
    }

    /// The gap between the header's chrome and the edge of the pane. The task column's is 14 too.
    private static let margin: CGFloat = 14

    // MARK: The header

    /// Point the header's controls at the board and the window.
    private func wireHeader() {
        header.addCard = { [weak self] in self?.addTextCard() }
        header.addFrame = { [weak self] in self?.addFrame() }
        header.addLink = { [weak self] in self?.scroll.board.addLinkCard(at: nil) }
        header.addFile = { [weak self] in self?.scroll.board.addFileCard(at: nil) }
        header.addProjectNote = { [weak self] in self?.scroll.board.addProjectNoteCard(at: nil) }
        header.setMode = { [weak self] mode in self?.scroll.board.mode = mode }
        header.zoomIn = { [weak self] in self?.scroll.zoom(by: 1.25) }
        header.zoomOut = { [weak self] in self?.scroll.zoom(by: 1 / 1.25) }
        header.zoomToFit = { [weak self] in self?.scroll.zoomToFit() }
        header.zoomActualSize = { [weak self] in self?.scroll.zoomToActualSize() }
        header.pageBack = { [weak self] in self?.engagedCard?.goBack() }
        header.pageForward = { [weak self] in self?.engagedCard?.goForward() }
        header.pageReload = { [weak self] in self?.engagedCard?.reload() }
        header.pageStop = { [weak self] in self?.engagedCard?.stopLoading() }
        header.pageGo = { [weak self] address in self?.engagedCard?.go(to: address) }
        header.pageHome = { [weak self] in self?.engagedCard?.goHome() }
        header.pageAdoptAddress = { [weak self] in self?.engagedCard?.adoptCurrentAddress() }
        header.findChanged = { [weak self] query in self?.search(query) }
        header.findClosed = { [weak self] in self?.closeFind() }
        header.tile = { [weak self] in self?.scroll.board.tileSelection(nil) }
        header.setArrangement = { [weak self] arrangement in
            guard let self else { return }
            // The same "choosing an arrangement is a request to tile" rule the View menu follows —
            // otherwise these two items are settings for a state you have to already be in to reach
            // them. See `setTileArrangement`.
            if scroll.board.isTiled { return scroll.board.setArrangement(arrangement) }
            // Tiling from here makes a workspace, exactly as ⌘↩ does — see `offerAsWorkspace`. The
            // arrangement you picked is the one it is made with.
            let targets = scroll.board.tileTargets
            guard !scroll.board.offerAsWorkspace(targets, arrangement: arrangement) else { return }
            scroll.board.tile(targets, arrangement: arrangement)
        }
        header.findCommitted = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(scroll.board)
        }
    }

    // MARK: Driving the page inside a card

    /// Back, forward, reload — and the address the page is actually on, which you can type into.
    ///
    /// In the window's chrome rather than on the card, and that is now the *only* place they could be:
    /// a card has no chrome to put them in. It was the right answer before that was true. On the card
    /// they were laid out over the page, which meant fighting the site for the one piece of a web page
    /// every site puts its own navigation in, at a size that had to be fought back from the zoom, in a
    /// corner the board also wanted for dragging.
    ///
    /// They appear only while a card is engaged. A board is not a browser, and a header carrying
    /// browser buttons for a board with nothing running on it would say otherwise.
    private var engagedCard: CanvasLinkNodeView? {
        scroll.board.engagedPageCard as? CanvasLinkNodeView
    }

    func pageStateChanged() {
        guard let card = engagedCard else {
            header.page = nil
            return
        }
        header.page = CanvasHeaderModel.Page(
            host: card.liveHost,
            liveAddress: card.liveURL?.absoluteString ?? card.address,
            savedAddress: card.address,
            wandered: card.hasWandered,
            canGoBack: card.canGoBack,
            canGoForward: card.canGoForward,
            isLoading: card.isLoading,
            age: card.loadedAt.map { canvasFreshnessLabel(for: $0) })
    }

    // MARK: Finding

    private var lastQuery: String { header.find.query }

    /// Run the query, and say when it found nothing.
    ///
    /// The count goes in the field's own trailing edge; only the empty result gets the banner, because
    /// that is the one outcome where the board itself shows you nothing and would otherwise look like a
    /// board that had simply lost your selection.
    /// The card ⌘F is searching inside, if you are inside one.
    ///
    /// **Find follows what you are in**, which is the rule ⌘+ and ⌘− already follow on this board: on
    /// the board they mean the board, inside a card they mean the card. ⌘F searching the *board* while
    /// the keyboard is in a web page was the one command that ignored where you were — and the board's
    /// find cannot see a page's text at all, so the answer it gave was always "nothing matches" for
    /// words that were plainly on the screen.
    private var searchTarget: CanvasLinkNodeView? {
        scroll.board.engagedPageCard as? CanvasLinkNodeView
    }

    /// The project card you are standing in, when there is one. The third thing find can be pointed
    /// at, on the same rule as the first two: **find looks inside whatever you have stepped into.**
    /// Nothing engaged means the board itself, and the board's find matches cards.
    private var searchedProjectCard: CanvasFileNodeView? { scroll.board.engagedProjectCard }

    /// The card whose match count is being listened to, and the subscription doing it.
    ///
    /// The count cannot be read back the moment the query is written: the card is SwiftUI, so it does
    /// the counting on its next pass, and reading straight after writing would put yesterday's answer
    /// in the field on every keystroke. So the field follows the card rather than asking it.
    private weak var searchedCard: CanvasFileNodeView?
    private var searchedCardMatches: AnyCancellable?

    private func watchMatches(of card: CanvasFileNodeView) {
        guard searchedCard !== card else { return }
        searchedCard = card
        searchedCardMatches = card.projectDisplay.$matches
            // `@Published` fires *before* the value lands, so the read has to be a turn later.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showMatchCount(of: card) }
    }

    private func showMatchCount(of card: CanvasFileNodeView) {
        let query = card.projectDisplay.find
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            header.find.summary = ""
            notice.dismiss()
            updateNotice()
            return
        }
        let matches = card.projectDisplay.matches ?? 0
        header.find.summary = "\(matches)"
        if matches == 0 {
            notice.show(message: "No tasks on this card match \u{201C}\(query)\u{201D}.",
                        kind: .informational, actionTitle: nil)
        } else {
            notice.dismiss()
            updateNotice()
        }
    }

    private func search(_ query: String) {
        if let page = searchTarget {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                header.find.summary = ""
                notice.dismiss()
                updateNotice()
                return
            }
            // WebKit says whether it found one, not how many — so the field says nothing rather than a
            // count it would have to invent, and the banner carries the only outcome worth a sentence.
            page.find(query) { [weak self] found in
                guard let self else { return }
                header.find.summary = ""
                if found {
                    notice.dismiss()
                    updateNotice()
                } else {
                    notice.show(message: "Nothing on this page matches \u{201C}\(query)\u{201D}.",
                                kind: .informational, actionTitle: nil)
                }
            }
            return
        }
        // A project card is a task list, so find narrows it the way the window's find bar narrows the
        // same list — rather than selecting the one card the query is obviously inside.
        if let card = searchedProjectCard {
            watchMatches(of: card)
            card.projectDisplay.find = query
            return
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            scroll.board.select([])
            header.find.summary = ""
            notice.dismiss()
            updateNotice()
            return
        }
        let found = scroll.board.find(query)
        header.find.summary = found.isEmpty ? "" : "\(found.count)"
        if found.isEmpty {
            notice.show(message: "Nothing on this canvas matches \u{201C}\(query)\u{201D}.",
                        kind: .informational, actionTitle: nil)
        } else {
            notice.dismiss()
            updateNotice()
        }
    }

    /// Close the field and drop the query with it — a selection you can no longer see the reason for is
    /// a selection you'll wonder about.
    private func closeFind() {
        header.find = CanvasHeaderModel.Find()
        // A filter you cannot see is a filter you will forget, so closing the field un-narrows the
        // card as well as dropping the board's selection.
        searchedProjectCard?.projectDisplay.find = ""
        scroll.board.select([])
        updateNotice()
        view.window?.makeFirstResponder(scroll.board)
    }

    /// Edit ▸ Find. AppKit's standard Find selector, told apart by the item's `tag` — the same
    /// convention the project window follows, so ⌘F means the same thing in both.
    ///
    /// The field grows out of the header's capsule rather than opening a bar of its own; ⌘F while it is
    /// already open re-focuses and selects, so a second press is "search again" rather than a no-op.
    @objc func performFindPanelAction(_ sender: Any?) {
        let action = (sender as? NSMenuItem).map { NSTextFinder.Action(rawValue: $0.tag) } ?? .showFindInterface
        switch action {
        case .showFindInterface:
            header.find.isShowing = true
            header.find.focusToken &+= 1
        case .nextMatch, .previousMatch:
            // Inside a page, "again" walks the page's own matches — forwards or back, which the board's
            // own find has never offered because a set of matching cards has no direction to walk in.
            if let page = searchTarget {
                page.find(lastQuery, forward: action == .nextMatch) { _ in }
            } else if let card = searchedProjectCard {
                // A narrowed list has a direction after all: "again" walks the selection down it.
                card.projectDisplay.stepFind(action == .nextMatch ? 1 : -1)
            } else {
                scroll.board.findNext(lastQuery)
            }
        default:
            break
        }
    }

    /// The stack ⌘Z acts on in this pane: the editor of the card you are typing in, and otherwise the
    /// canvas document. See `CanvasBoardView.engagedCardUndoManager`.
    var undoManagerForContent: UndoManager { scroll.board.engagedCardUndoManager ?? store.undoManager }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == Selector(("undo:")) { return validateUndo(item, redoing: false) }
        if item.action == Selector(("redo:")) { return validateUndo(item, redoing: true) }
        guard item.action == #selector(performFindPanelAction(_:)) else { return true }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: return true
        case .nextMatch, .previousMatch: return !lastQuery.isEmpty
        default: return false
        }
    }

    // MARK: Reacting

    private func documentChanged() {
        // The canvas is now the more recently edited of the two documents a board can hold — see
        // `CanvasBoardView.lastEditedProject`.
        scroll.board.lastEditedProject = nil
        scroll.board.documentChanged()
        updateNotice()
        // A frame tiles what is inside it, so what the tiling button promises can change without the
        // selection changing at all.
        refreshTileCommand()
        refreshProjectNoteOffer()
    }

    /// Keep the `+` menu's fifth item in step with the board.
    ///
    /// From the document rather than from the menu opening, because a SwiftUI `Menu` builds its
    /// content from published state and cannot ask a question at the moment it is pulled down. Cheap
    /// enough to do on every change — see `CanvasProjectNoteCard.isOn`, which was written for exactly
    /// this call being on the drag path.
    private func refreshProjectNoteOffer() {
        let offers = scroll.board.offersProjectNoteCard
        if header.offersProjectNote != offers { header.offersProjectNote = offers }
    }

    /// Keep the header's tiling button saying what it would actually do.
    ///
    /// Driven from the three things that change the answer — the selection, the document, and whether
    /// a tiling is up. Deliberately not from scrolling: the wording only counts a *selection*, exactly
    /// so this doesn't have to run at the rate a trackpad reports. See `CanvasTiling.commandTitle`.
    private func refreshTileCommand() {
        header.tileTitle = scroll.board.tileCommandTitle
    }

    // MARK: Undo, on a board that can hold two kinds of document

    /// ⌘Z and ⇧⌘Z, routed to whichever document was edited last.
    ///
    /// A board holds a canvas — cards moved, resized, added — and it can hold project cards, whose edits
    /// belong to a `PMStore` and its own snapshot stack. Both are real documents with real histories,
    /// and the window can only hand back one `UndoManager`. So the routing is here, on the pane, which
    /// sits in the responder chain ahead of the window: it answers `undo:` itself and sends it to the
    /// right one.
    ///
    /// "Edited last" rather than "whatever has focus", because that is what a person means by ⌘Z. You
    /// tick a task, you press ⌘Z, and you expect the tick back — not the card you nudged before it.
    @objc func undo(_ sender: Any?) {
        if let project = scroll.board.lastEditedProject, project.canUndo { return project.undo() }
        store.undoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let project = scroll.board.lastEditedProject, project.canRedo { return project.redo() }
        store.undoManager.redo()
    }

    /// What the Edit menu says, and whether it says it at all.
    ///
    /// Named, because the two documents are answering the same key and the title is the only thing that
    /// can say which one it is about to act on: "Undo Complete Task" and "Undo Move Card" are the
    /// difference between a command you can trust and one you have to try.
    private func validateUndo(_ item: NSMenuItem, redoing: Bool) -> Bool {
        // The card you are typing in comes first — while its editor is open, ⌘Z is that editor's, and
        // the menu has to say so or the key it is the shortcut for never arrives. See
        // `undoManagerForContent`.
        if let editing = scroll.board.engagedCardUndoManager {
            item.title = redoing ? editing.redoMenuItemTitle : editing.undoMenuItemTitle
            return redoing ? editing.canRedo : editing.canUndo
        }
        if let project = scroll.board.lastEditedProject, redoing ? project.canRedo : project.canUndo {
            item.title = redoing ? "Redo" : "Undo"
            return true
        }
        let manager = store.undoManager
        let can = redoing ? manager.canRedo : manager.canUndo
        item.title = redoing ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        return can
    }

    private func noteOutsideChange() {
        notice.show(message: "This canvas changed in another app. PM reloaded it.",
                    kind: .informational, actionTitle: nil)
    }

    /// How many cards point at a file that isn't where the canvas says.
    private var movedCards: [CanvasNode] {
        store.document.nodes.filter { node in
            guard case .file(let path, _) = node.content else { return false }
            return store.resolver.resolve(path).hasMoved
        }
    }

    @objc private func blockingHealthChanged() { updateNotice() }

    /// Dismissing the blocking warning keeps it dismissed for the life of this window. It is app-wide
    /// and there is nothing to do about it from here, so saying it again on the next redraw would be
    /// nagging rather than informing.
    private var hidBlockingNotice = false

    /// Something that just happened, and the file to show for it. Cleared on a timer.
    ///
    /// **First in the notice bar, ahead of both standing warnings.** The other two are conditions —
    /// cards point at moved files, filtering isn't in force — which are equally true a minute from now.
    /// This is an event, it is the consequence of something you did a second ago, and if it waits its
    /// turn behind a condition it is not a report of anything.
    private var event: (message: String, file: URL?)?
    private var eventClock: Timer?

    /// How long a report stays up. Long enough to read a sentence and reach the button on it, short
    /// enough that the standing warning underneath is not hidden for the rest of the session.
    private static let eventLifetime: TimeInterval = 9

    /// Something to say the moment this pane appears, rather than in response to anything done in it.
    ///
    /// Set before the view loads, by whoever made the pane. The one caller is the split view controller
    /// after it has replaced a canvas that would not open: the pane it then builds is the first thing
    /// you see of a board you did not know had been rewritten, and it owes you that sentence and the
    /// button to the old file. See `ProjectSplitViewController.replaceUnreadableCanvasOnce`.
    var openingNotice: (message: String, file: URL?)?

    private func say(_ message: String, reveal file: URL?) {
        event = (message, file)
        eventClock?.invalidate()
        eventClock = Timer.scheduledTimer(withTimeInterval: Self.eventLifetime, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.event = nil
                self.updateNotice()
            }
        }
        updateNotice()
    }

    private func updateNotice() {
        if let event {
            return notice.show(message: event.message, kind: .informational, actionTitle: nil,
                               revealTitle: event.file == nil ? nil : "Show in Finder")
        }
        let moved = movedCards.count
        if moved > 0 {
            return notice.show(message: moved == 1
                                   ? "1 card points at a file that has moved. PM is showing it from where it is now."
                                   : "\(moved) cards point at files that have moved. PM is showing them from where they are now.",
                               kind: .warning,
                               actionTitle: "Repair Paths",
                               revealTitle: "Show Them")
        }
        // Second, because the moved-file warning is about *this* canvas and can be acted on, while
        // this one is about the app. It is still worth the space: a filtering failure looks exactly
        // like a page, so nothing else on screen would ever tell you.
        if let trouble = CanvasContentBlocker.trouble, !hidBlockingNotice {
            return notice.show(message: trouble, kind: .warning, actionTitle: nil)
        }
        notice.dismiss()
    }

    private func selectMovedCards() {
        let ids = Set(movedCards.map(\.id))
        scroll.board.select(ids)
        if let first = movedCards.first {
            scroll.centre(on: CanvasPoint(x: first.frame.midX, y: first.frame.midY))
        }
    }

    /// Rewrite every stale path in one step — undoable as one, because that is how it will be regretted
    /// if it is regretted at all.
    private func repairAllPaths() {
        let resolver = store.resolver
        store.change("Repair Card Paths") { doc in
            for index in doc.nodes.indices {
                guard case .file(let path, let subpath) = doc.nodes[index].content,
                      case .moved(let url, _) = resolver.resolve(path),
                      let corrected = resolver.storablePath(for: url) else { continue }
                doc.nodes[index].content = .file(path: corrected, subpath: subpath)
            }
        }
        notice.dismiss()
    }

    // MARK: Commands

    @objc private func zoomIn() { scroll.zoom(by: 1.25) }
    @objc private func zoomOut() { scroll.zoom(by: 1 / 1.25) }
    @objc private func zoomToFit() { scroll.zoomToFit() }

    /// A new card lands in the middle of what you're looking at, which is the only place you can be
    /// sure you'll see it.
    private var centreOfView: CanvasPoint {
        let visible = scroll.documentVisibleRect
        return scroll.board.canvasPoint(NSPoint(x: visible.midX, y: visible.midY))
    }

    /// The header's Add ▸ Card. The board owns it — it had a copy of its own for the right-click menu,
    /// and a card added from here landed on top of the tiles while one was up because only the board's
    /// copy knew about tiled views. See `CanvasBoardView.addTextCard`.
    @objc private func addTextCard() { scroll.board.addTextCard(at: nil) }

    @objc private func addFrame() {
        let centre = centreOfView
        let node = CanvasNode(content: .group(label: "Frame", background: nil, backgroundStyle: nil),
                              frame: CanvasRect(x: centre.x - 300, y: centre.y - 200,
                                                width: 600, height: 400))
        store.change("Add Frame") { $0.nodes.append(node) }
        scroll.board.select([node.id])
    }

    @objc private func addLink() { scroll.board.addLinkCard(at: nil) }

    @objc private func addFile() { scroll.board.addFileCard(at: nil) }

    // MARK: A board nobody is looking at

    private var idleTimer: Timer?

    /// How long a board goes on running its pages after you have looked away.
    ///
    /// Not immediately, and that is the whole design of the number: switching to your editor to check
    /// something and switching straight back is the single most common thing that happens to a
    /// dashboard, and a board that tore down eight renderers each time would spend the day rebuilding
    /// them — costing more than it saved and making every glance back a reload. Two minutes is long
    /// enough to cover going away and coming back, and short enough that a board left open behind your
    /// work isn't quietly running a browser all afternoon.
    private static let idleGrace: TimeInterval = 120

}

/// The pane's own view, which exists only to notice when something starts covering it.
///
/// A project window's sidebar slides *over* this pane rather than beside it, so opening or closing it
/// changes what covers the board without changing the pane's size — no frame change, no notification.
/// AppKit has `safeAreaInsets` but, unlike UIKit, nothing that tells you when it moved, so this watches
/// it across layout passes. Layout is the right place to watch from: it runs on every frame of the
/// sidebar's slide, so the chrome and the tiles follow the animation rather than jumping when it ends.
///
/// The compare-and-store is what keeps this from recursing. The callback moves constraints, which asks
/// for another layout pass, in which the insets are the ones already recorded and nothing fires.
private final class CanvasPaneContainer: NSView {
    var onCoveredRegionChange: (() -> Void)?
    private var covered = NSEdgeInsets()

    override func layout() {
        super.layout()
        let now = safeAreaInsets
        guard now.left != covered.left || now.right != covered.right
                || now.top != covered.top || now.bottom != covered.bottom else { return }
        covered = now
        onCoveredRegionChange?()
    }
}


// MARK: - Being one tab among several

extension CanvasPaneController: ProjectTabContent {
    /// Brought forward again. The page budget is settled on a timer and on scrolling, and a tab you
    /// switched away from ten minutes ago has had neither — so without this a board comes back with
    /// every card frozen until something happens to it.
    func paneBecameVisible() {
        scroll.board.settlePageBudget()
        focusBoard()
    }

    func paneWillClose() { teardown() }
}
