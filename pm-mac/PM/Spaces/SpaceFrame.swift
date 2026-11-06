import AppKit
import PmLib
import SwiftUI
import UniformTypeIdentifiers

/// The Arc-style frame over a board, a space's or a project's: the sidebar lists the board, the
/// window's content is the workspace. docs/spaces.md § The frame.
///
/// - Rows are the board's cards: favourites as icons, then Pinned (named workspaces first, then pinned
///   cards), then Today. Frames on the board are folders.
/// - Clicking a card already showing brings it forward; one in a named workspace jumps there; any other
///   replaces the tile you're in (alone, if you were in a named workspace).
/// - ⌥-click: a tile beside. ⌘-click picks; ⌘↩ tiles the picked as a new workspace.
/// - Lives in the project window's sidebar slot, in place of the project list.
/// - A project's frame has Notes above Board, Cards where a space has Today (nothing archives), the
///   project's name as a menu of the other projects at its top, and the focused task at its foot.
@MainActor
@Observable
final class SpaceFrame {
    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var host: String?
        var symbol: String?
        var pinned: Bool
        var favorite: Bool
        var showing: Bool
        var front: Bool
        /// Making sound now (`CanvasPageView.isPlayingAudio`).
        var playing = false
        var muted = false
        /// Its place in its list, once a drag has given it one (`SpaceCardMarks.orderKey`).
        var order: Double?
    }

    struct Folder: Identifiable, Equatable {
        var id: String
        var label: String
        var rows: [Row]
    }

    struct Group: Equatable {
        var loose: [Row] = []
        var folders: [Folder] = []
        var isEmpty: Bool { loose.isEmpty && folders.isEmpty }
    }

    struct Workspace: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var hosts: [String?]
        var showing: Bool
    }

    /// The space this frames; nil for a project's board.
    let spaceID: String?
    /// The project this frames; nil for a space. Its name, colour, focused task and session are read
    /// from it live by the sidebar.
    @ObservationIgnored private(set) weak var project: PMStore?
    var isSpace: Bool { spaceID != nil }
    /// The board's canvas file, to tell whether a window still frames the board it's showing.
    var canvasURL: URL { canvas }
    /// The project's Notes workspace (the notes card alone), and whether it's up.
    private(set) var notesWorkspace: String?
    private(set) var notesShowing = false
    private(set) var favorites: [Row] = []
    private(set) var pinned = Group()
    private(set) var today = Group()
    private(set) var workspaces: [Workspace] = []
    private(set) var boardShowing = false
    private(set) var frontHost: String?
    private(set) var cardCount = 0
    private(set) var spaceTitle = ""
    private(set) var spaceColor = Color.gray
    private(set) var washColor: ProjectColor?
    var picked: Set<String> = []
    var closedFolders: Set<String> = []
    /// Bumped to ask the address field for the keyboard (⌘T).
    private(set) var addressRequests = 0
    /// What the address field is for while it has the keyboard: a new card (⌘T), or this page (⌘L).
    private(set) var editingFront = false
    /// Which sidebar's field takes it: the floating one when the sidebar is folded away.
    var addressInPeek = false
    /// Asked before the field is wanted (the split shows the floating sidebar when the docked one is
    /// away) and told when the field is done (and puts it away again).
    @ObservationIgnored var presentAddress: () -> Void = {}
    @ObservationIgnored var addressDone: () -> Void = {}
    /// The front card's address, for ⌘L to start from.
    private(set) var frontAddress = ""
    /// Where the field's next web card goes, when a folder's + or a menu asked for one; nil is the top
    /// of Today / Cards.
    @ObservationIgnored private var pendingList: SpaceCardMarks.List?
    /// The browser session the field's next web card is on: Private Web Card from the add list.
    private(set) var pendingProfile: String?

    @ObservationIgnored private weak var split: ProjectSplitViewController?
    @ObservationIgnored private let store: CanvasDocumentStore
    @ObservationIgnored private let canvas: URL

    init(spaceID: String?, project: PMStore? = nil, canvas: URL, store: CanvasDocumentStore,
         split: ProjectSplitViewController) {
        self.spaceID = spaceID
        self.project = project
        self.canvas = canvas
        self.store = store
        self.split = split
        store.addWatcher(self, changed: { [weak self] in self?.refresh() }, reloaded: { [weak self] in self?.refresh() })
        audioWatch = NotificationCenter.default.addObserver(forName: CanvasPageView.audioChanged, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @ObservationIgnored private var audioWatch: NSObjectProtocol?

    func stop() {
        store.removeWatcher(self)
        if let audioWatch { NotificationCenter.default.removeObserver(audioWatch) }
        audioWatch = nil
    }

    /// The speaker on a row: stop that card's page.
    func pause(_ id: String) { CanvasLinkNodeView.pause(card: id, onCanvas: canvas) }

    private var pane: CanvasPaneController? { split?.canvasPane }
    private var board: CanvasBoardView? { pane?.board }

    // MARK: Reading the board

    func refresh() {
        let document = store.document
        let board = self.board
        let tiled = Set(board?.tiling?.ids ?? [])
        let front = board?.focusedTile ?? (tiled.count == 1 ? tiled.first : nil)
        if let front, recentFronts.first != front {
            recentFronts.removeAll { $0 == front }
            recentFronts.insert(front, at: 0)
        }
        recentFronts = Array(recentFronts.filter { document.node(id: $0) != nil }.prefix(64))
        let lookups = CanvasExistingCards.lookups(isFolder: { board?.isFolderPath($0) ?? false })
        let sounding = CanvasLinkNodeView.playingCards(onCanvas: canvas)
        let sections = CanvasItems.sections(of: document, showing: [], lookups: lookups)
        // A project's notes card is its Notes row, not one of its cards.
        var notesCard: String?
        if !isSpace, let notes = CanvasProjectNoteCard.notes(forCanvasAt: canvas) {
            notesCard = CanvasProjectNoteCard.id(on: document, notes: notes, resolver: store.resolver)
        }
        // The workspace holding the notes card alone (`CanvasProjectNoteCard.notesWorkspace`), read
        // the way the workspace rows are, so the two agree on which one it is.
        let names = CanvasWorkspaces.names(of: canvas)
        notesWorkspace = notesCard.flatMap { card in
            names.first { CanvasWorkspaces.tiling(named: $0, of: canvas)?.ids == [card] }
                ?? names.first { $0 == CanvasProjectNoteCard.notesWorkspaceName
                    && CanvasWorkspaces.tiling(named: $0, of: canvas)?.ids.contains(card) == true }
        }
        func row(_ item: CanvasItem) -> Row? {
            guard item.id != notesCard, let node = document.node(id: item.id) else { return nil }
            var host: String?, symbol: String?
            switch item.kind {
            case .page(let h): host = h
            case .file(let s), .view(let s): symbol = s
            case .text: symbol = "text.alignleft"
            }
            let title = board?.describeCard(item.id)?.title ?? item.title
            return Row(id: item.id, title: title, host: host, symbol: symbol,
                       pinned: SpaceCardMarks.isPinned(node), favorite: SpaceCardMarks.isFavorite(node),
                       showing: tiled.contains(item.id), front: item.id == front, playing: sounding.contains(item.id),
                       muted: CanvasCardMedia.isMuted(node), order: SpaceCardMarks.order(node))
        }
        var favorites: [Row] = [], pinned = Group(), today = Group()
        for section in sections {
            let rows = section.items.compactMap(row)
            favorites += rows.filter(\.favorite)
            let pins = rows.filter { $0.pinned && !$0.favorite }, rest = rows.filter { !$0.pinned }
            if let frame = section.frame {
                let label = section.label ?? "Frame"
                if !pins.isEmpty { pinned.folders.append(Folder(id: frame, label: label, rows: pins)) }
                if !rest.isEmpty { today.folders.append(Folder(id: frame, label: label, rows: rest)) }
            } else {
                pinned.loose += pins
                today.loose += rest
            }
        }
        // Each list in the order rows were dragged into, the rest after them as they sit on the board.
        func sorted(_ rows: [Row]) -> [Row] { SpaceCardMarks.sorted(rows, by: \.order) }
        func sorted(_ group: Group) -> Group {
            Group(loose: sorted(group.loose),
                  folders: group.folders.map { Folder(id: $0.id, label: $0.label, rows: sorted($0.rows)) })
        }
        self.favorites = sorted(favorites)
        self.pinned = sorted(pinned)
        self.today = sorted(today)
        cardCount = sections.reduce(0) { $0 + $1.items.count }
        let current = board?.workspaceName
        let selectedTab = split?.tabs.selected.view
        notesShowing = !isSpace && (selectedTab?.isNotesTab == true
            || (current != nil && current == notesWorkspace && (board?.isTiled ?? false)))
        workspaces = CanvasWorkspaces.ordered(of: canvas).filter { $0 != notesWorkspace }.map { name in
            let ids = CanvasWorkspaces.tiling(named: name, of: canvas)?.ids ?? []
            let hosts = ids.prefix(3).map { id -> String? in
                if case .link(let url)? = document.node(id: id)?.content { return URL(string: url)?.host() }
                return nil
            }
            return Workspace(name: name, hosts: hosts, showing: current == name && (board?.isTiled ?? false))
        }
        boardShowing = !(board?.isTiled ?? false) && !notesShowing
        // The page the focused tile is on now, not the address the card was saved with.
        let frontURL: URL? = front.flatMap { id in
            if let live = (board?.nodeViews[id] as? CanvasLinkNodeView)?.liveURL { return live }
            if case .link(let url)? = document.node(id: id)?.content { return URL(string: url) }
            return nil
        }
        frontHost = frontURL.map { CanvasAddressSuggestions.bare($0.absoluteString) }
        picked = picked.filter { document.node(id: $0) != nil }
        let everyRow = favorites + pinned.loose + pinned.folders.flatMap(\.rows) + today.loose + today.folders.flatMap(\.rows)
        // The mini player: a card making sound that isn't on screen, and one it paused, until shown.
        heldInPlayer = heldInPlayer.filter { id in everyRow.contains { $0.id == id && !$0.showing } }
        player = everyRow.first { $0.playing && !$0.showing } ?? everyRow.first { heldInPlayer.contains($0.id) }
        guard let spaceID else {
            // A project's board: nothing archives, and its colour is the project's.
            archiveAfter = nil
            otherSpaces = []
            spaceTitle = ""
            washColor = project?.color
            spaceColor = Color(nsColor: washColor?.nsColor ?? .systemGray)
            return
        }
        noteSeen(everyRow.filter(\.showing).map(\.id), all: everyRow.map(\.id))
        let space = Spaces.shared.space(spaceID)
        archiveAfter = space?.archiveAfter
        otherSpaces = Spaces.shared.all.filter { $0.id != spaceID }.map { ($0.id, $0.title) }
        spaceTitle = space?.title ?? ""
        washColor = space.flatMap { ProjectColor(value: $0.color) }
        spaceColor = Color(nsColor: washColor?.nsColor ?? .systemGray)
    }

    /// The focused tile or its page changed. Many in a row (a load's progress) refresh once.
    @ObservationIgnored private var frontRefreshQueued = false
    func frontChanged() {
        guard !frontRefreshQueued else { return }
        frontRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.frontRefreshQueued = false
            self?.refresh()
        }
    }

    // MARK: Today

    /// What's in the mini player (sidebar foot), and the card it paused, kept there until it's shown.
    private(set) var player: Row?
    @ObservationIgnored private var heldInPlayer: Set<String> = []
    private(set) var archiveAfter: Double?
    private(set) var otherSpaces: [(id: String, title: String)] = []

    static let archiveChoices: [(title: String, seconds: Double?)] = [
        ("Never", nil), ("After 12 Hours", 12 * 3600), ("After a Day", 86_400),
        ("After a Week", 7 * 86_400), ("After 30 Days", 30 * 86_400),
    ]

    func setArchiveAfter(_ seconds: Double?) {
        guard let spaceID else { return }
        Spaces.shared.change(spaceID) { $0.archiveAfter = seconds }
        archiveIfDue(force: true)
    }

    /// Clear: every Today card off the board (⌘Z brings them back). Pinned and favourites stay.
    func clearToday() {
        let ids = (today.loose + today.folders.flatMap(\.rows)).map(\.id)
        guard !ids.isEmpty else { return }
        remove(Set(ids), actionName: "Clear Today")
    }

    private func remove(_ ids: Set<String>, actionName: String) {
        for id in ids { noteClosed(id) }
        store.change(actionName) { doc in
            doc.nodes.removeAll { ids.contains($0.id) }
            doc.edges.removeAll { ids.contains($0.fromNode) || ids.contains($0.toNode) }
        }
        refresh()
    }

    /// When each card was last on screen, by space and card. A card first seen now counts from now.
    private static let seenKey = "PMSpaceCardSeen"
    @ObservationIgnored private var lastSweep = Date.distantPast

    private func noteSeen(_ showing: [String], all: [String]) {
        var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
        guard let spaceID else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for id in all {
            let key = spaceID + "/" + id
            let stale = (seen[key] ?? 0) < now - 60
            if seen[key] == nil || (showing.contains(id) && stale) { seen[key] = now; changed = true }
        }
        if changed { UserDefaults.standard.set(seen, forKey: Self.seenKey) }
        if Date().timeIntervalSince(lastSweep) > 60 {
            DispatchQueue.main.async { [weak self] in self?.archiveIfDue(force: false) }
        }
    }

    /// Arc's archive: Today cards not on screen for `archiveAfter` go, checked at most once a minute.
    private func archiveIfDue(force: Bool) {
        guard force || Date().timeIntervalSince(lastSweep) > 60 else { return }
        lastSweep = Date()
        guard let spaceID, let after = Spaces.shared.space(spaceID)?.archiveAfter else { return }
        let seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - after
        let due = (today.loose + today.folders.flatMap(\.rows))
            .filter { !$0.showing && !$0.playing && (seen[spaceID + "/" + $0.id] ?? .infinity) < cutoff }
            .map(\.id)
        guard !due.isEmpty else { return }
        Log.write("space \(spaceID): archived \(due.count) Today cards")
        remove(Set(due), actionName: "Archive Today")
    }

    // MARK: The mini player, mute, and the rest of a row's menu

    func playerToggle() {
        guard let row = player, let card = CanvasLinkNodeView.card(row.id, onCanvas: canvas) else { return }
        if row.playing {
            heldInPlayer.insert(row.id)
            card.pauseMedia()
        } else {
            card.resumeMedia()
        }
    }

    func playerPictureInPicture() {
        guard let row = player else { return }
        CanvasLinkNodeView.card(row.id, onCanvas: canvas)?.togglePictureInPicture()
    }

    func playerDismiss() {
        heldInPlayer = []
        if let row = player, row.playing { CanvasLinkNodeView.card(row.id, onCanvas: canvas)?.pauseMedia() }
        player = nil
    }

    func setMuted(_ id: String, _ on: Bool) {
        store.change(on ? "Mute Card" : "Unmute Card") { doc in
            if let index = doc.nodes.firstIndex(where: { $0.id == id }) { CanvasCardMedia.setMuted(on, on: &doc.nodes[index]) }
        }
        refresh()
    }

    func moveToSpace(_ id: String, _ target: String) {
        guard let spaceID else { return }
        Spaces.shared.move(id, from: spaceID, to: target)
        refresh()
    }

    /// A second card on the page this one has got to, with its back list (`openPageAsNewCard`).
    func duplicate(_ id: String) {
        guard let board else { return }
        if let card = board.nodeViews[id] as? CanvasLinkNodeView, board.openPageAsNewCard(from: card) {
            if let added = board.selection.first { show(added) }
            return
        }
        guard case .link(let address)? = store.document.node(id: id)?.content else { return }
        openNewCard(address, showing: true)
    }

    func copyAddress(_ id: String) {
        if let card = CanvasLinkNodeView.card(id, onCanvas: canvas) { return card.copyAddress() }
        guard case .link(let address)? = store.document.node(id: id)?.content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    /// ⇧⌘C: the front page's address.
    func copyFrontAddress() -> Bool {
        guard let card = frontPage, let url = card.liveURL else { return false }
        card.copyAddress()
        board?.report("Copied \(url.host() ?? url.absoluteString).")
        return true
    }

    // MARK: Showing

    /// A row clicked. ⌘ picks; ⌥ puts it in a tile beside; otherwise show it, as Arc.
    func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
            return
        }
        picked = []
        if flags.contains(.option) { return tileBeside(id) }
        openAlone(id)
    }

    /// A click on a card: the card on its own, whether or not a layout holds it.
    ///
    /// **A card in a layout is still a card.** `show` takes you to the layout, which is right for a
    /// jump by keyboard or by search but wrong for a click on one row: you asked for that card, and a
    /// layout of five others arrives with it. The layouts are left as they were, and the row's menu
    /// has "Show in <layout>" for going back into one (`showInLayout`).
    ///
    /// A card no layout holds goes the way it always did (`show`), which replaces the tile you're in.
    func openAlone(_ id: String) {
        guard let split, let board else { return }
        let inLayout = board.tiling?.cards.contains(id) == true
            || !CanvasWorkspaces.names(holdingAnyOf: [id], of: canvas).isEmpty
        guard inLayout else { return show(id) }
        // From a layout's own tab, leave for the board's tab; from the board, `alone` does the rest.
        if board.workspaceName != nil || split.canvasPane?.focus != .whole { split.goToCanvas() }
        guard let canvasBoard = self.board else { return }
        alone(id, on: canvasBoard)
        refresh()
    }

    /// The layouts, in the sidebar's order, that hold this card — what its row's menu offers.
    func layouts(holding id: String) -> [String] {
        let holding = Set(CanvasWorkspaces.names(holdingAnyOf: [id], of: canvas))
        return CanvasWorkspaces.ordered(of: canvas).filter { holding.contains($0) && $0 != notesWorkspace }
    }

    /// Go to a layout with this card's tile forward.
    func showInLayout(_ name: String, card id: String) {
        guard let split else { return }
        split.openTab(.board(.workspace(name)))
        split.canvasPane?.whenInWorkspace(name) { [weak self] in
            self?.board?.showTab(id)
            self?.refresh()
        }
        refresh()
    }

    func show(_ id: String) {
        guard let split, let board else { return }
        // Already on screen: forward, as a tab in its tile if it is one.
        if let tiling = board.tiling, tiling.cards.contains(id) {
            board.showTab(id)
            return refresh()
        }
        // In a named workspace: go there, with this card's tile picked.
        if let name = CanvasWorkspaces.names(holdingAnyOf: [id], of: canvas).first {
            return showInLayout(name, card: id)
        }
        // Anywhere else replaces the tile you're in. In a named workspace, that's leaving it for the
        // card on its own, on the board's own tab.
        if board.workspaceName != nil || split.canvasPane?.focus != .whole {
            split.goToCanvas()
            guard let canvasBoard = self.board else { return }
            alone(id, on: canvasBoard)
            return refresh()
        }
        // A tab switch, so a cut (`replaceInTiling`). From the Board overview it's a crossing into the
        // card, which does show where it was, and stays animated.
        if board.isTiled, let tile = board.focusedTile ?? board.tiling?.ids.first {
            board.replaceInTiling(tile, with: id, animated: false)
            board.select([id])
        } else {
            board.tile([id])
        }
        refresh()
    }

    private func alone(_ id: String, on board: CanvasBoardView) {
        if let tiling = board.tiling, tiling.ids.count == 1, let only = tiling.ids.first {
            board.replaceInTiling(only, with: id, animated: false)
            board.select([id])
        } else {
            if board.isTiled { board.leaveTiling(animated: false) }
            board.tile([id], animated: false)
        }
    }

    func tileBeside(_ id: String) {
        guard let board else { return }
        if board.isTiled {
            board.addExistingCard(withID: id)
        } else {
            board.tile([id])
        }
        refresh()
    }

    /// ⌘↩: the picked cards as a new workspace, a row among Pinned.
    func tilePicked() {
        guard let split, let board, !picked.isEmpty,
              let plan = board.plannedTiling(for: picked) else { return }
        picked = []
        _ = split.tileAsWorkspace(plan)
        refresh()
    }

    func showBoard() {
        guard let split else { return }
        split.goToCanvas()
        if let board, board.isTiled { board.leaveTiling(animated: true) }
        refresh()
    }

    /// A project's Notes row: its Notes workspace, made if it isn't yet (`ProjectSplitViewController.openTab`).
    func showNotes() {
        split?.openTab(.notes)
        refresh()
    }

    /// The window's state, which the project list in the name's popover shares with the window.
    @ObservationIgnored weak var windowState: ProjectWindowState?
    /// Bumped to open the project list under the name (File ▸ All Projects…).
    private(set) var projectsRequests = 0
    func askForProjects() { projectsRequests += 1 }

    func showWorkspace(_ name: String) {
        split?.openTab(.board(.workspace(name)))
        refresh()
    }

    func deleteWorkspace(_ name: String) {
        split?.tabModel.deleteWorkspace(name)
        refresh()
    }

    /// A layout's name typed into its row — the same rename as typing into its tab chip, so it carries
    /// the chips, asks before replacing a name that's taken, and is one ⌘Z.
    func renameWorkspace(_ old: String, to new: String) {
        split?.renameWorkspace(named: old, to: new)
        refresh()
    }

    // MARK: Marks

    func setPinned(_ id: String, _ on: Bool) {
        store.change(on ? "Pin" : "Unpin") { doc in
            if let i = doc.nodes.firstIndex(where: { $0.id == id }) { SpaceCardMarks.setPinned(on, on: &doc.nodes[i]) }
        }
    }

    func setFavorite(_ id: String, _ on: Bool) {
        store.change(on ? "Add to Favourites" : "Remove from Favourites") { doc in
            if let i = doc.nodes.firstIndex(where: { $0.id == id }) { SpaceCardMarks.setFavorite(on, on: &doc.nodes[i]) }
        }
    }

    /// Close: a pinned card is unpinned; any other comes off the board (⌘Z brings it back).
    func close(_ id: String) {
        guard let node = store.document.node(id: id) else { return }
        if SpaceCardMarks.isPinned(node) { return setPinned(id, false) }
        guard let board else { return }
        // **Closing the card in front goes to the one you were on before it**, as a browser does — into
        // its slot, so the layout keeps its shape. See `nextFront`.
        let tiling = board.tiling
        let front = board.focusedTile ?? (tiling?.ids.count == 1 ? tiling?.ids.first : nil)
        let document = store.document
        let next = id == front ? tiling.flatMap {
            Self.nextFront(closing: id, recent: recentFronts, tabs: $0.tabs(of: id)) { document.node(id: $0) != nil }
        } : nil
        noteClosed(id)
        if let next, tiling?.cards.contains(next) == false {
            board.replaceInTiling(id, with: next, animated: false)
        }
        board.select([id])
        board.deleteSelection()
        if let next { show(next) }
        refresh()
    }

    /// The cards that have been in front, most recent first: where closing the one in front goes.
    @ObservationIgnored private var recentFronts: [String] = []

    /// Where closing `closed`, the card in front, sends you: the card in front before it that is still
    /// on the board (`recent`, most recent first) — a tab of the same tile first, when it had others,
    /// so closing a tab stays in its tile. Nil for nowhere remembered, which leaves the tiling's own
    /// rule (the neighbouring tab, or the board).
    static func nextFront(closing closed: String, recent: [String], tabs: [String],
                          exists: (String) -> Bool) -> String? {
        let candidates = recent.filter { $0 != closed && exists($0) }
        if tabs.count > 1 { return candidates.first(where: tabs.contains) }
        return candidates.first
    }

    /// ⌘W: the card in front, closed as above. False when there's none, so the window closes instead.
    /// ⌘W: the focused tile out of the layout — the card stays in the sidebar, and ⌘Z puts it back.
    /// False with no tile focused, so the window closes instead.
    func closeFront() -> Bool {
        // In a project's notes, ⌘W goes to the board: the notes don't close.
        if notesShowing { showBoard(); return true }
        guard let board, board.isTiled, let id = board.focusedTile ?? board.tiling?.ids.first else { return false }
        board.closeTileRemembering(id, inSpace: spaceID)
        refresh()
        return true
    }

    /// The cards in the sidebar's order: favourites, pinned (folders opened), today. ⌘1…⌘9.
    var cardsInOrder: [Row] {
        func all(_ group: Group) -> [Row] { group.loose + group.folders.flatMap(\.rows) }
        return favorites + all(pinned) + all(today)
    }

    /// ⌘1…⌘8 the card in that place, ⌘9 the last, as Arc. False when there's no card there.
    @discardableResult
    func showCard(at slot: Int) -> Bool {
        let cards = cardsInOrder
        let index = slot == 8 ? cards.count - 1 : slot
        guard cards.indices.contains(index) else { return false }
        show(cards[index].id)
        return true
    }

    /// ⇧⌘T: the card if it's still on the board (⌘W leaves it there), else a new card on its address.
    func reopen(_ closed: CanvasHistory.Closed) {
        if store.document.node(id: closed.cardID) != nil { return show(closed.cardID) }
        openNewCard(closed.address, showing: true)
    }

    /// The grip's ✕: this tile out of the layout, as ⌘W on it.
    func closeTile(_ id: String) {
        guard let board, board.isTiled, board.tiling?.ids.contains(id) == true else { return }
        board.closeTileRemembering(id, inSpace: spaceID)
        refresh()
    }

    /// For ⇧⌘T, a card coming off the board (a row's Close, Clear): its address and where it was.
    /// Tiles taken out of the layout are remembered by `closeTileRemembering`.
    private func noteClosed(_ id: String) {
        guard let node = store.document.node(id: id), case .link(let address) = node.content else { return }
        let live = (board?.nodeViews[id] as? CanvasLinkNodeView)?.liveURL?.absoluteString
        CanvasHistory.didClose(live ?? address, card: id, canvas: canvas, inSpace: spaceID)
    }

    /// ⌃⇥ and ⇧⌘]: the card after the one in front, round to the first.
    func cycleCards(by step: Int) {
        let cards = cardsInOrder
        guard !cards.isEmpty else { return }
        let at = cards.firstIndex(where: \.front) ?? (step > 0 ? -1 : 0)
        show(cards[(at + step + cards.count) % cards.count].id)
    }

    // MARK: Dragging rows

    /// Where a dragged row would go: a slot in one of the lists, or into a workspace.
    enum DropSpot: Equatable {
        case list(SpaceCardMarks.List, Int)
        case workspace(String)
        /// A workspace row's new place among the workspace rows.
        case workspaceSlot(Int)
    }

    /// The card whose row is being dragged, while one is.
    var dragging: String?
    /// The workspace whose row is being dragged, while one is.
    var draggingWorkspace: String?
    /// Where letting go in the sidebar would put it, marked there.
    var dropSpot: DropSpot?

    /// A workspace row's drag began. It carries a tab chip's type (`ProjectTabDrag`): a workspace row
    /// is the frame's tab, and nothing but the sidebar takes it.
    func beginWorkspaceDrag(_ name: String) -> NSItemProvider {
        picked = []
        draggingWorkspace = name
        return ProjectTabDrag.itemProvider(for: name) { [weak self] in
            guard let self, self.draggingWorkspace == name else { return }
            self.draggingWorkspace = nil
            self.dropSpot = nil
        }
    }

    /// A workspace row let go at `slot` of the rows as they stand.
    func moveWorkspace(_ name: String, to slot: Int) {
        var names = workspaces.map(\.name)
        guard let from = names.firstIndex(of: name) else { return }
        names.remove(at: from)
        names.insert(name, at: min(from < slot ? slot - 1 : slot, names.count))
        CanvasWorkspaces.setOrder(names, for: canvas)
        refresh()
    }

    /// A row's drag began.
    func beginDrag(_ id: String) -> NSItemProvider {
        picked = []
        dragging = id
        var address: String?
        if case .link(let url)? = store.document.node(id: id)?.content { address = url }
        return SpaceRowDrag.itemProvider(card: id, canvas: canvas, address: address) { [weak self] in
            guard let self, self.dragging == id else { return }
            self.dragging = nil
            self.dropSpot = nil
        }
    }

    /// The cards in a list, in the sidebar's order.
    func members(of list: SpaceCardMarks.List) -> [String] {
        func ids(_ group: Group, _ folder: String?) -> [String] {
            guard let folder else { return group.loose.map(\.id) }
            return group.folders.first { $0.id == folder }?.rows.map(\.id) ?? []
        }
        switch list {
        case .favorites: return favorites.map(\.id)
        case .pinned(let folder): return ids(pinned, folder)
        case .today(let folder): return ids(today, folder)
        }
    }

    /// The pointer is over `spot`: mark it, unless letting go there would leave the row where it is.
    func propose(_ spot: DropSpot?) {
        var spot = spot
        if case .list(let list, let index)? = spot, let id = dragging,
           let from = members(of: list).firstIndex(of: id), index == from || index == from + 1 {
            spot = nil
        }
        if case .workspaceSlot(let index)? = spot, let name = draggingWorkspace,
           let from = workspaces.firstIndex(where: { $0.name == name }), index == from || index == from + 1 {
            spot = nil
        }
        if dropSpot != spot { dropSpot = spot }
    }

    /// Let go in the sidebar.
    func land(at spot: DropSpot) {
        let id = dragging, workspace = draggingWorkspace
        SpaceRowDrag.end()
        dragging = nil
        draggingWorkspace = nil
        dropSpot = nil
        if case .workspaceSlot(let index) = spot {
            if let workspace { moveWorkspace(workspace, to: index) }
            return
        }
        guard let id else { return }
        switch spot {
        case .workspaceSlot: return
        case .workspace(let name):
            addToWorkspace(id, name)
        case .list(let list, let index):
            let members = members(of: list)
            // Dropped where it was.
            if let from = members.firstIndex(of: id), index == from || index == from + 1 { return }
            if list != .favorites, case .group? = store.document.node(id: id)?.content { return }
            store.change("Move Card") { SpaceCardMarks.move(id, to: list, at: index, members: members, in: &$0) }
            refresh()
        }
    }

    /// Files from Finder (or any app) let go in the sidebar: a file card each, in the list at `spot`'s
    /// slot in the order dropped, or into the workspace a row was dropped on; the last one shown. Files
    /// outside the vault ask Copy In / Point At It first, as a drop on the board does. One undo step.
    func landFiles(_ files: [URL], at spot: DropSpot) {
        dropSpot = nil
        guard !files.isEmpty else { return }
        let list: SpaceCardMarks.List, index: Int, workspace: String?
        switch spot {
        case .list(let at, let slot): (list, index, workspace) = (at, slot, nil)
        case .workspace(let name): (list, index, workspace) = (.today(folder: nil), 0, name)
        case .workspaceSlot: return
        }
        // Asked on the next turn: this runs from inside the drop, and a modal session there nests in it.
        DispatchQueue.main.async { [weak self] in
            self?.addDropped(files, to: list, at: index, workspace: workspace)
        }
    }

    /// `landFiles`, at once: the question (if any) asked now. Internal for tests.
    func addDropped(_ files: [URL], to list: SpaceCardMarks.List, at index: Int, workspace: String?) {
        var files = files
        let outsiders = CanvasBoardView.outside(files, of: store.resolver)
        if !outsiders.isEmpty {
            switch CanvasBoardView.askAboutOutsiders(outsiders) {
            case .copyIn?:
                let moved = Set(outsiders)
                files = files.map { file in
                    guard moved.contains(file) else { return file }
                    return CanvasBoardView.copyIn(file, besideBoardAt: canvas) ?? file
                }
            case .pointAt?: break
            case nil: return
            }
        }
        let nodes = files.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isFolder { SpaceRecentFolders.note(url) }
            return CanvasNode(content: .file(path: store.resolver.storablePath(for: url) ?? url.path, subpath: nil),
                              frame: newCardFrame(width: 400, height: isFolder ? 400 : 350))
        }
        // Side by side right of everything, rather than all at the one place `newCardFrame` gives.
        var placed = nodes
        for i in placed.indices.dropFirst() {
            placed[i].frame.x = placed[i - 1].frame.x + placed[i - 1].frame.width + 40
        }
        let members = members(of: list)
        store.change(placed.count > 1 ? "Add Files" : "Add File") {
            SpaceCardMarks.insert(placed, into: list, at: index, members: members, in: &$0)
        }
        refresh()
        if let workspace {
            placed.forEach { addToWorkspace($0.id, workspace) }
        } else if let last = placed.last {
            show(last.id)
        }
    }

    /// A row dropped on a workspace's: the card joins it, beside the tile in front, and the workspace
    /// comes up with it focused.
    func addToWorkspace(_ id: String, _ name: String) {
        guard let split else { return }
        let add = { [weak self] in
            guard let board = self?.board else { return }
            if board.tiling?.cards.contains(id) == true { board.showTab(id) } else { board.addExistingCard(withID: id) }
            self?.refresh()
        }
        if board?.workspaceName == name, board?.isTiled == true { return add() }
        split.openTab(.board(.workspace(name)))
        split.canvasPane?.whenInWorkspace(name, add)
        refresh()
    }

    // MARK: New tab

    /// ⌘T: the address field, for a new card.
    func askForAddress() {
        editingFront = false
        presentAddress()
        addressRequests += 1
    }

    /// ⌘L: the address field on the page in front, to send it somewhere else — as Arc's ⌘L.
    func editFrontAddress() {
        guard let card = frontPage else { return askForAddress() }
        frontAddress = card.url?.absoluteString ?? ""
        editingFront = true
        presentAddress()
        addressRequests += 1
    }

    /// The web card in front: the one you're in, else the focused tile's.
    private var frontPage: CanvasLinkNodeView? {
        guard let board else { return nil }
        if let engaged = board.engagedPageCard as? CanvasLinkNodeView { return engaged }
        return board.focusedTile.flatMap { board.nodeViews[$0] } as? CanvasLinkNodeView
    }

    /// What the sidebar's field suggests: the same as the header's (`CanvasHistory.candidates`).
    var addressCandidates: [CanvasAddressSuggestions.Candidate] {
        CanvasHistory.candidates(board: store.document.nodes, back: frontPage?.backSteps ?? [])
    }

    /// The engine a space searches with: Settings', as every address field (`CanvasSearchEngine.current`).
    static var engine: CanvasSearchEngine { CanvasSearchEngine.current }

    /// The address field made a card instead of going somewhere ("time", "folder", a path): where a
    /// folder's + asked, else the top of Today / Cards.
    func makeFromField(_ card: SpaceNewCard) {
        let list = pendingList
        editingFront = false
        pendingList = nil
        pendingProfile = nil
        addressDone()
        make(card, in: list)
    }

    /// The address field gave up the keyboard without a line.
    func addressCancelled() {
        editingFront = false
        pendingList = nil
        pendingProfile = nil
        addressDone()
    }

    /// The address field's line: the page in front sent there (⌘L), or a web card in Today, shown in
    /// the tile you're in (⌘T).
    func open(_ typed: String) {
        guard board != nil, let address = CanvasAddress.resolved(typed, engine: Self.engine) else { return }
        defer { addressDone() }
        if editingFront, let card = frontPage {
            editingFront = false
            return card.go(to: address)
        }
        editingFront = false
        let list = pendingList ?? .today(folder: nil), profile = pendingProfile
        pendingList = nil
        pendingProfile = nil
        openNewCard(address, showing: true, in: list, profile: profile)
    }

    /// A link from another app: the card on that address if the space has one, else a new card.
    func openIncoming(_ address: String) {
        guard let normalized = CanvasAddress.normalized(address) else { return }
        let existing = store.document.nodes.first {
            if case .link(let url) = $0.content { return CanvasAddress.normalized(url) == normalized }
            return false
        }
        if let existing { return show(existing.id) }
        openNewCard(normalized, showing: true)
    }

    /// A web card in Today, right of everything on the board, shown in the tile you're in when
    /// `showing` (⌘T, a link that wants a new window) or left in the sidebar (⇧⌘-click).
    /// From the address field (`list` given): at the start of that list, which is the top of Today /
    /// Cards unless a folder's + asked, on `profile`'s session.
    @discardableResult
    func openNewCard(_ address: String, showing: Bool, in list: SpaceCardMarks.List? = nil,
                     profile: String? = nil) -> String? {
        guard board != nil else { return nil }
        var node = CanvasNode(content: .link(url: address), frame: newCardFrame(width: 400, height: 400))
        CanvasCardSession.set(profile, on: &node)
        // Onto the board only, not `addCard`, which also tiles it into the layout up: in a named
        // workspace that grew the workspace (a project's Notes became two cards) instead of showing
        // the card in the tile you're in (2026-11-05).
        put(node, actionName: profile == nil ? "New Tab" : "New Private Tab", in: list)
        if showing { show(node.id) } else { refresh() }
        return node.id
    }

    /// Right of everything on the board, where a new card goes.
    private func newCardFrame(width: Double, height: Double) -> CanvasRect {
        let right = store.document.nodes.map { $0.frame.x + $0.frame.width }.max() ?? 0
        return CanvasRect(x: right + 40, y: 0, width: width, height: height)
    }

    /// One undo step: the card onto the board, and when `list` is given, first in it (into its folder's
    /// frame if it has one).
    private func put(_ node: CanvasNode, actionName: String, in list: SpaceCardMarks.List?) {
        let members = list.map(members(of:)) ?? []
        store.change(actionName) { document in
            document.nodes.append(node)
            if let list { SpaceCardMarks.move(node.id, to: list, at: 0, members: members, in: &document) }
        }
    }

    // MARK: Adding cards (docs/spaces.md § Adding cards from the sidebar)

    /// A card from the address field or the add menu, first in `list` (the top of Today / Cards when
    /// nil), shown in the tile you're in. A web card asks for its address in the field; a file, or a
    /// folder not among the recent ones, asks with the open panel.
    func make(_ card: SpaceNewCard, in list: SpaceCardMarks.List? = nil) {
        guard let board else { return }
        let list = list ?? .today(folder: nil)
        let node: CanvasNode, action: String
        switch card {
        case .kind(.web), .kind(.privateWeb):
            pendingList = list
            pendingProfile = card == .kind(.privateWeb) ? CanvasWebSession.ephemeralName : nil
            return askForAddress()
        case .kind(.file):
            guard let url = choose(folder: false) else { return }
            return make(.file(url), in: list)
        case .kind(.folder), .chooseFolder:
            guard let url = choose(folder: true) else { return }
            return make(.folder(url), in: list)
        case .folder(let url), .file(let url):
            let isFolder = card == .folder(url)
            if isFolder { SpaceRecentFolders.note(url) }
            node = CanvasNode(content: .file(path: store.resolver.storablePath(for: url) ?? url.path, subpath: nil),
                              frame: newCardFrame(width: 400, height: isFolder ? 400 : 350))
            action = isFolder ? "Add Folder" : "Add File"
        case .kind(.frame):
            // A folder in the sidebar; nothing to show in a tile.
            let frame = CanvasNode(content: .group(label: "Frame", background: nil, backgroundStyle: nil),
                                   frame: newCardFrame(width: 600, height: 400))
            store.change("Add Frame") { $0.nodes.append(frame) }
            return refresh()
        case .kind(.card):
            node = board.newCardNode(frame: newCardFrame(width: 400, height: 400))
            action = "Add Card"
        case .kind(let command):
            guard let spec = command.viewSpec else { return }
            var view = CanvasNode(content: .text(spec.noteText), frame: newCardFrame(width: 360, height: 480))
            CanvasViewSpec.set(spec, on: &view)
            node = view
            action = "Add View"
        }
        put(node, actionName: action, in: list)
        show(node.id)
        if card == .kind(.card) { board.beginEditing(node.id) }
    }

    /// The open panel for a file or a folder, starting in the project's folder when there is one.
    private func choose(folder: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.message = folder ? "Choose a folder." : "Choose a file."
        panel.directoryURL = projectFolder
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// A project's own folder, which leads the recent folders; nil in a space.
    var projectFolder: URL? { isSpace ? nil : CanvasProjectNoteCard.projectFolder(forCanvasAt: canvas) }

    /// The add list as a menu: a folder's +, a right-click on the sidebar (docs/spaces.md § Adding cards
    /// from the sidebar). File ▸ New Card's list, except New Folder is the recent folders.
    func addMenu(in list: SpaceCardMarks.List? = nil) -> NSMenu {
        let menu = NSMenu()
        let item = { (title: String, card: SpaceNewCard) -> NSMenuItem in
            SpaceMenuItem(title) { [weak self] in self?.make(card, in: list) }
        }
        for row in CanvasAddCommand.rows(projectNote: false, tabs: false) {
            switch row {
            case .item(.folder):
                let folders = NSMenu()
                for url in SpaceRecentFolders.list(projectFolder: projectFolder) {
                    let entry = item(url.lastPathComponent, .folder(url))
                    entry.toolTip = url.path
                    folders.addItem(entry)
                }
                if !folders.items.isEmpty { folders.addItem(.separator()) }
                folders.addItem(item("Choose\u{2026}", .chooseFolder))
                menu.addItem(withTitle: "New Folder", action: nil, keyEquivalent: "").submenu = folders
            case .item(let command):
                menu.addItem(item(command.title, .kind(command)))
            case .views(let views):
                let submenu = NSMenu()
                for command in views {
                    let entry = item(command.viewName ?? command.title, .kind(command))
                    entry.image = command.viewKind.flatMap { MenuPictures.symbol($0.symbol, $0.title) }
                    MenuPictures.forceImageVisible(entry)
                    if let subtitle = command.viewSubtitle { entry.subtitle = subtitle }
                    submenu.addItem(entry)
                }
                menu.addItem(withTitle: "New View", action: nil, keyEquivalent: "").submenu = submenu
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

/// A menu item that runs a closure.
final class SpaceMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(_:run:)") }

    @objc private func fire() { run() }
}

// MARK: - The sidebar

/// Arc's sidebar, over a board: the address under the window's buttons, favourites as tiles, the
/// board's pinned cards, a rule, New Tab and today's cards, the space's name at the foot.
struct SpaceFrameSidebar: View {
    @Bindable var frame: SpaceFrame
    /// The floating copy over the content (sidebar folded away) rather than the docked one.
    var inPeek = false
    /// The peek was opened to type an address (⌘T, ⌘L), so its field takes the keyboard as it appears.
    /// Never for one opened by the pointer reaching the edge.
    var focusesAddress = false
    @State private var address = ""
    @State private var addressFocused = false
    @State private var focusToken = 0
    @State private var candidates: [CanvasAddressSuggestions.Candidate] = []
    @State private var fieldWidth: CGFloat = 220
    @State private var ruleHover = false
    @State private var sidebarHover = false
    /// The layout whose row's name is being typed into, if one is.
    @State private var renamingWorkspace: String?
    /// A card's icon is one thing whether it's on a row or a favourite: adding to (or taking off)
    /// Favourites moves it between the two (`matchedGeometryEffect`).
    @Namespace private var glyphs

    /// Every card's place in the sidebar. A change to it (closing, Clear, archive, ⌘T, pinning,
    /// favouriting, Move to Space) animates the rows into their new places; anything else, such as the
    /// card in front changing, doesn't. Folding a folder isn't in it: folders snap.
    private var placement: [String] {
        frame.favorites.map { "f" + $0.id } + frame.cardsInOrder.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let project = frame.project {
                ProjectFrameHeader(store: project, state: frame.windowState, requests: frame.projectsRequests)
            }
            addressField
            if !frame.favorites.isEmpty { favorites } else if frame.dragging != nil { favoritesWell }
            // The list fills the scroll area at least, so the empty sidebar under the last row is the
            // drag area behind the rows rather than the scroll view's own ground (which moves nothing).
            GeometryReader { area in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !frame.isSpace {
                        SpaceSidebarRow(title: "Notes", symbol: "doc.text", on: frame.notesShowing) { frame.showNotes() }
                    }
                    SpaceSidebarRow(title: "Board", symbol: "rectangle.on.rectangle.angled",
                                    trailing: "\(frame.cardCount)", on: frame.boardShowing, dim: true) { frame.showBoard() }
                    ForEach(Array(frame.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        workspaceRow(workspace, index: index)
                    }
                    group(frame.pinned, pinned: true)
                    Group { if frame.isSpace { todayRule } else { cardsRule } }
                        .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(
                            frame: frame, owned: [pinnedEnd, todayStart]) { $0.y < 12 ? pinnedEnd : todayStart })
                    SpaceSidebarRow(title: "New Tab", symbol: "plus", dim: true) { frame.askForAddress() }
                        .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(
                            frame: frame, owned: [todayStart]) { _ in todayStart })
                    group(frame.today, pinned: false)
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: .topLeading)
                .background { WindowDragArea { frame.addMenu() } }
                // Files let go anywhere a row doesn't take them (Notes, Board, the empty sidebar below
                // the rows): the end of Today / Cards. Files only — a row has to land on a row.
                .onDrop(of: [.fileURL], delegate: SpaceRowDropTarget(frame: frame, owned: [todayEnd]) { _ in todayEnd })
            }
            .scrollIndicators(.never)
            }
            if !frame.picked.isEmpty {
                Button("Tile \(frame.picked.count) as a Workspace") { frame.tilePicked() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            if let row = frame.player {
                // It turns up because sound left the screen, which you didn't do on purpose: rises 8pt as it
                // fades in, and goes quicker than it came.
                SpaceMiniPlayer(row: row, frame: frame)
                    .transition(Motion.moving(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.combined(with: .offset(y: 4)).animation(.easeIn(duration: Motion.Tempo.exit)))))
            }
            footer
        }
        .animation(Motion.animation(.easeOut(duration: 0.22)), value: placement)
        .animation(Motion.animation(.easeOut(duration: Motion.Tempo.standard)), value: frame.player?.id)
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
        .background { SpaceWash(color: frame.washColor, tiled: !frame.boardShowing).ignoresSafeArea() }
        .ignoresSafeArea(edges: .top)
        .onHover { sidebarHover = $0 }
        .onChange(of: frame.addressRequests) {
            guard frame.addressInPeek == inPeek else { return }
            askForTheKeyboard()
        }
        // A peek built for ⌘T / ⌘L is made after the request was counted, so there is no change for
        // `onChange` to see: it asks for itself. One built because the pointer reached the edge does not.
        .onAppear { if focusesAddress { askForTheKeyboard() } }
    }

    private func askForTheKeyboard() {
        address = frame.editingFront ? frame.frontAddress : ""
        candidates = frame.addressCandidates
        focusToken &+= 1
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: frame.frontHost == nil ? "magnifyingglass" : "lock.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            CanvasAddressTextField(
                text: $address, focusToken: focusToken, engine: SpaceFrame.engine, candidates: candidates,
                originalAddress: frame.editingFront ? frame.frontAddress : "", boxWidth: fieldWidth,
                placeholder: frame.pendingProfile != nil ? "Private: search or enter address"
                    : frame.frontHost ?? "Search or enter address",
                cards: frame.editingFront ? nil : .init(projectFolder: frame.projectFolder) { card in
                    address = ""
                    addressFocused = false
                    frame.makeFromField(card)
                }
            ) { destination in
                address = ""
                addressFocused = false
                if let destination { frame.open(destination) } else { frame.addressCancelled() }
            } onCancel: {
                address = ""
                addressFocused = false
                frame.addressCancelled()
            } onBegin: {
                addressFocused = true
                // A click straight into the field: suggestions from now, a new card on Return.
                if focusToken == 0 || candidates.isEmpty { candidates = frame.addressCandidates }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background { GeometryReader { box in Color.clear.onAppear { fieldWidth = box.size.width }
            .onChange(of: box.size.width) { _, width in fieldWidth = width } } }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(addressFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
    }

    private var favorites: some View {
        let count = frame.favorites.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 80), spacing: 8)], spacing: 8) {
            ForEach(Array(frame.favorites.enumerated()), id: \.element.id) { index, row in
                SpaceFavoriteTile(row: row, glyphs: glyphs) { frame.click(row.id) }
                    .contextMenu { menu(for: row) }
                    .overlay(alignment: .leading) {
                        if frame.dropSpot == .list(.favorites, index) { insertionMark(vertical: true).offset(x: -5) }
                    }
                    .overlay(alignment: .trailing) {
                        if index == count - 1, frame.dropSpot == .list(.favorites, count) {
                            insertionMark(vertical: true).offset(x: 5)
                        }
                    }
                    .opacity(frame.dragging == row.id ? 0.4 : 1)
                    .onDrag { frame.beginDrag(row.id) }
                    .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(
                        frame: frame, owned: [.list(.favorites, index), .list(.favorites, index + 1)]) { point in
                        .list(.favorites, point.x < 22 ? index : index + 1)
                    })
            }
        }
    }

    /// Where a row goes to become the first favourite, while a row is being dragged and there are none.
    private var favoritesWell: some View {
        let spot = SpaceFrame.DropSpot.list(.favorites, 0)
        return Text("Drop to Add to Favourites")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(frame.dropSpot == spot ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(frame.dropSpot == spot ? Color.accentColor : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .transition(.opacity)
            .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(frame: frame, owned: [spot]) { _ in spot })
    }

    /// A workspace's row: a card's row dropped on it joins the workspace; another workspace's row
    /// dropped on its top or bottom half goes before or after it.
    private func workspaceRow(_ workspace: SpaceFrame.Workspace, index: Int) -> some View {
        let into = SpaceFrame.DropSpot.workspace(workspace.name)
        let count = frame.workspaces.count
        return SpaceSidebarRow(title: workspace.name, stack: workspace.hosts, on: workspace.showing,
                               editing: renamingWorkspace == workspace.name,
                               rename: { renamingWorkspace = workspace.name },
                               endRename: { new in
                                   // Once: Escape then the blur that follows would otherwise commit.
                                   guard renamingWorkspace == workspace.name else { return }
                                   renamingWorkspace = nil
                                   if let new { frame.renameWorkspace(workspace.name, to: new) }
                               }) {
            frame.showWorkspace(workspace.name)
        }
        .overlay(dropRing(frame.dropSpot == into))
        .overlay(alignment: .top) {
            if frame.dropSpot == .workspaceSlot(index) { insertionMark().offset(y: -2) }
        }
        .overlay(alignment: .bottom) {
            if index == count - 1, frame.dropSpot == .workspaceSlot(count) { insertionMark().offset(y: 2) }
        }
        .opacity(frame.draggingWorkspace == workspace.name ? 0.4 : 1)
        .contextMenu {
            Button("Rename Layout\u{2026}") { renamingWorkspace = workspace.name }
            Button("Delete Workspace") { frame.deleteWorkspace(workspace.name) }
        }
        // Not while its name is being typed into: a drag there is selecting text.
        .onDrag(if: renamingWorkspace != workspace.name) { frame.beginWorkspaceDrag(workspace.name) }
        .onDrop(of: SpaceRowDropTarget.types + [ProjectTabDrag.type], delegate: SpaceRowDropTarget(
            frame: frame, owned: [into, .workspaceSlot(index), .workspaceSlot(index + 1)]) { point in
            frame.draggingWorkspace != nil ? .workspaceSlot(point.y < 16 ? index : index + 1) : into
        })
    }

    private var pinnedEnd: SpaceFrame.DropSpot { .list(.pinned(folder: nil), frame.pinned.loose.count) }
    private var todayStart: SpaceFrame.DropSpot { .list(.today(folder: nil), 0) }
    private var todayEnd: SpaceFrame.DropSpot { .list(.today(folder: nil), frame.today.loose.count) }

    /// The line where a dragged row would go.
    private func insertionMark(vertical: Bool = false) -> some View {
        Capsule().fill(Color.accentColor)
            .frame(width: vertical ? 2 : nil, height: vertical ? 30 : 2)
            .padding(.horizontal, vertical ? 0 : 6)
            .allowsHitTesting(false)
    }

    /// A row a dragged row would go into (a workspace, a folder).
    private func dropRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5)
            .allowsHitTesting(false)
    }

    /// Between what's kept and what's today: a hairline, as Arc's, with Clear at its end while the
    /// pointer is over it (or the sidebar). Its menu sets when Today's cards archive themselves.
    private var todayRule: some View {
        HStack(spacing: 6) {
            Rectangle().fill(ruleTargeted ? Color.accentColor : Color.primary.opacity(0.1))
                .frame(height: ruleTargeted ? 2 : 1)
            if !frame.today.isEmpty && (ruleHover || sidebarHover) {
                // Shown whenever the pointer enters the sidebar, so it fades rather than flickering.
                Button { frame.clearToday() } label: {
                    Label("Clear", systemImage: "arrow.down").labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close every Today card (⌘Z brings them back)")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Motion.Tempo.quick), value: ruleHover || sidebarHover)  // motion: fade-only
        .frame(height: 18)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { ruleHover = $0 }
        .contextMenu { archiveMenu }
    }

    /// A drop at the end of Pinned or the start of Today, which the rule between them marks.
    private var ruleTargeted: Bool { frame.dropSpot == pinnedEnd || frame.dropSpot == todayStart }

    /// A project's: the rule over its unpinned cards, which stay until you close them (nothing archives).
    private var cardsRule: some View {
        HStack(spacing: 6) {
            Text("Cards").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            Rectangle().fill(ruleTargeted ? Color.accentColor : Color.primary.opacity(0.1))
                .frame(height: ruleTargeted ? 2 : 1)
        }
        .frame(height: 18)
        .padding(.horizontal, 8).padding(.vertical, 3)
        // Right-click: the add list (a space's rule has its Archive menu there instead).
        .background { WindowDragArea { frame.addMenu() } }
    }

    @ViewBuilder
    private var archiveMenu: some View {
        Button("Clear Today") { frame.clearToday() }.disabled(frame.today.isEmpty)
        Picker("Archive Today\u{2019}s Cards", selection: Binding(
            get: { frame.archiveAfter ?? -1 },
            set: { frame.setArchiveAfter($0 < 0 ? nil : $0) })) {
            ForEach(SpaceFrame.archiveChoices, id: \.title) { choice in
                Text(choice.title).tag(choice.seconds ?? -1)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let project = frame.project { ProjectFrameFoot(store: project) } else { spaceFooter }
    }

    private var spaceFooter: some View {
        HStack(spacing: 7) {
            Circle().fill(frame.spaceColor).frame(width: 8, height: 8)
            Text(frame.spaceTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !CanvasDownloads.shared.items.isEmpty { SpaceDownloadsButton() }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .contextMenu { archiveMenu }
    }

    @ViewBuilder
    private func group(_ group: SpaceFrame.Group, pinned: Bool) -> some View {
        let loose: SpaceCardMarks.List = pinned ? .pinned(folder: nil) : .today(folder: nil)
        ForEach(Array(group.loose.enumerated()), id: \.element.id) { index, row in
            cardRow(row, indent: false, list: loose, index: index, count: group.loose.count)
        }
        ForEach(group.folders) { folder in
            let open = !frame.closedFolders.contains(folder.id)
            let list: SpaceCardMarks.List = pinned ? .pinned(folder: folder.id) : .today(folder: folder.id)
            // A row dropped on a folder goes in first; a closed folder is marked as the place.
            let first = SpaceFrame.DropSpot.list(list, 0)
            SpaceSidebarRow(title: folder.label, symbol: open ? "folder" : "folder.fill", disclosure: open,
                            addMenu: { frame.addMenu(in: list) }) {
                if open { frame.closedFolders.insert(folder.id) } else { frame.closedFolders.remove(folder.id) }
            }
            .overlay(dropRing(!open && frame.dropSpot == first))
            .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(frame: frame, owned: [first]) { _ in first })
            if open {
                ForEach(Array(folder.rows.enumerated()), id: \.element.id) { index, row in
                    cardRow(row, indent: true, list: list, index: index, count: folder.rows.count)
                }
            }
        }
    }

    /// A card's row: click to show, drag to move it in the list, into a folder or workspace, or onto
    /// the tiles. The line marks where it would land; nothing moves until it's let go.
    private func cardRow(_ row: SpaceFrame.Row, indent: Bool, list: SpaceCardMarks.List, index: Int,
                         count: Int) -> some View {
        SpaceSidebarRow(row: row, indent: indent, picked: frame.picked.contains(row.id), glyphs: glyphs,
                        close: { frame.close(row.id) },
                        pause: { row.muted ? frame.setMuted(row.id, false) : frame.pause(row.id) }) { frame.click(row.id) }
            .contextMenu { menu(for: row) }
            .overlay(alignment: .top) {
                if frame.dropSpot == .list(list, index) { insertionMark().offset(y: -2) }
            }
            .overlay(alignment: .bottom) {
                if index == count - 1, frame.dropSpot == .list(list, count) { insertionMark().offset(y: 2) }
            }
            .opacity(frame.dragging == row.id ? 0.4 : 1)
            .onDrag { frame.beginDrag(row.id) }
            .onDrop(of: SpaceRowDropTarget.types, delegate: SpaceRowDropTarget(
                frame: frame, owned: [.list(list, index), .list(list, index + 1)]) { point in
                .list(list, point.y < 16 ? index : index + 1)
            })
    }

    @ViewBuilder
    private func menu(for row: SpaceFrame.Row) -> some View {
        Button(row.pinned ? "Unpin" : "Pin") { frame.setPinned(row.id, !row.pinned) }
        Button(row.favorite ? "Remove from Favourites" : "Add to Favourites") { frame.setFavorite(row.id, !row.favorite) }
        ForEach(frame.layouts(holding: row.id), id: \.self) { name in
            Button("Show in \u{201C}\(name)\u{201D}") { frame.showInLayout(name, card: row.id) }
        }
        Button("Open in a Tile Beside") { frame.tileBeside(row.id) }
        Divider()
        if row.host != nil {
            Button("Copy Address") { frame.copyAddress(row.id) }
            Button("Duplicate") { frame.duplicate(row.id) }
            Button(row.muted ? "Unmute" : "Mute") { frame.setMuted(row.id, !row.muted) }
        }
        if !frame.otherSpaces.isEmpty {
            Menu("Move to Space") {
                ForEach(frame.otherSpaces, id: \.id) { space in
                    Button(space.title) { frame.moveToSpace(row.id, space.id) }
                }
            }
        }
        Divider()
        Button(row.pinned ? "Unpin" : "Close") { frame.close(row.id) }
    }
}

/// A project's frame, at the top: the project's mark and name, a menu of the other projects — Up Next,
/// then the project list as the window's sidebar had it, under its filters (docs/spaces.md § The frame).
struct ProjectFrameHeader: View {
    var store: PMStore
    var state: ProjectWindowState?
    /// A change opens the list (File ▸ All Projects…).
    var requests: Int
    @State private var showing = false
    @State private var hovering = false

    private var name: String {
        let title = store.notes?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return store.projectName.map { ProjectCodes.display($0) } ?? "Folio"
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                if let icon = store.icon {
                    // The text colour, not the project's: a dark project colour vanishes on a dark sidebar.
                    ProjectIconMark(icon: icon, size: 15)
                        .frame(width: 18, height: 18)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: store.color?.nsColor ?? .systemGray))
                        .frame(width: 16, height: 16)
                }
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering || showing ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Other projects")
        .onChange(of: requests) { showing = true }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let state { ProjectListPopover(store: store, state: state) }
        }
    }
}

/// The project list in the name's popover: filters as chips over it, then the list the window's
/// sidebar used to be (Up Next first). Picking a project switches the window to it.
struct ProjectListPopover: View {
    var store: PMStore
    var state: ProjectWindowState
    @AppStorage("PMSidebarStatus") private var status: ProjectStatusFilter = .active
    @AppStorage("PMSidebarGroup") private var grouping: ProjectGrouping = .domain

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                chip("Active", status == .active) { status = .active }
                chip("Archived", status == .archived) { status = .archived }
                chip("All", status == .all) { status = .all }
                Spacer(minLength: 8)
                chip("By Due", grouping == .due) { grouping = .due }
                chip("By Domain", grouping == .domain) { grouping = .domain }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            ProjectSidebar(store: store, state: state)
        }
        .frame(width: 320, height: 540)
    }

    private func chip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(on ? 0.12 : 0.05)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? .primary : .secondary)
    }
}

/// A project's frame, at the foot: the task you're on (tick to finish it) and the session.
struct ProjectFrameFoot: View {
    var store: PMStore

    private var sessionLine: String {
        guard let session = store.notes?.sessions.first else { return "No session yet" }
        let label = SessionLabel(parsing: session.label)
        let day = session.date == formatSessionDate() ? "Today" : session.date
        return [day, label.name.isEmpty ? label.time : label.name].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let todo = store.focusedTodo {
                HStack(spacing: 7) {
                    Button { store.complete(todo) } label: {
                        Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Complete")
                    Text(todo.text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            HStack(spacing: 7) {
                Text(sessionLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !CanvasDownloads.shared.items.isEmpty { SpaceDownloadsButton() }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// The content's ground, under the sidebar too: the board's grey (or a tiling's deeper one) with the
/// space's colour washed down from the top — the same `CanvasColorWash` the content paints, so the two
/// meet without a seam.
struct SpaceWash: NSViewRepresentable {
    var color: ProjectColor?
    var tiled: Bool

    func makeNSView(context: Context) -> CanvasColorWash { CanvasColorWash() }

    func updateNSView(_ wash: CanvasColorWash, context: Context) {
        wash.color = color
        wash.ground = CanvasPalette.ground(tiled: tiled ? 1 : 0)
    }
}

/// The fill a row or tile wears when it's the one in front: a raised white chip in light, a lifted
/// grey in dark — Arc's selected tab.
struct SpaceSelectedFill: View {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.92))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 1.5, y: 1)
    }
}

struct SpaceFavoriteTile: View {
    let row: SpaceFrame.Row
    var glyphs: Namespace.ID?
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            SpaceRowGlyph(row: row, size: 20)
                .matchedGlyph(row.id, in: glyphs)
                .frame(maxWidth: .infinity).frame(height: 42)
                .overlay(alignment: .topTrailing) {
                    if row.playing {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary).padding(5)
                            .accessibilityLabel("Playing")
                    }
                }
                .background {
                    if row.front { SpaceSelectedFill(radius: 11) }
                    else { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0.06)) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(row.title)
        .accessibilityLabel(row.title)
    }
}

/// One sidebar row: a card, a workspace, a folder, or Board / New Tab.
struct SpaceSidebarRow: View {
    var title: String
    var symbol: String?
    var host: String?
    var stack: [String?] = []
    var trailing: String?
    var on = false
    var front = false
    var dim = false
    var indent = false
    var picked = false
    var disclosure: Bool?
    var close: (() -> Void)?
    /// Middle-click closes the row: set for a card that isn't pinned (a pinned one's close only
    /// unpins it, which a stray middle-click shouldn't do).
    var middleClickCloses = false
    var glyphs: Namespace.ID?
    var cardID: String?
    let tap: () -> Void
    @State private var hover = false

    /// Rename in place: double-click the row (or its Rename) puts a field where the title is.
    /// Return or clicking away keeps what's typed; Escape abandons. Nil `rename` = not renameable.
    var editing = false
    var rename: (() -> Void)?
    /// The edit's end: the typed name, or nil when abandoned or unchanged.
    var endRename: ((String?) -> Void)?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// A folder's +, shown on hover: the add list, into that folder.
    var addMenu: (() -> NSMenu)?

    init(title: String, symbol: String? = nil, stack: [String?] = [], trailing: String? = nil, on: Bool = false,
         dim: Bool = false, disclosure: Bool? = nil, addMenu: (() -> NSMenu)? = nil, editing: Bool = false,
         rename: (() -> Void)? = nil, endRename: ((String?) -> Void)? = nil, tap: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.stack = stack; self.trailing = trailing
        self.on = on; self.front = on; self.dim = dim; self.disclosure = disclosure; self.addMenu = addMenu
        self.editing = editing; self.rename = rename; self.endRename = endRename
        self.tap = tap
    }

    var playing = false
    var muted = false
    var pause: (() -> Void)?

    init(row: SpaceFrame.Row, indent: Bool, picked: Bool, glyphs: Namespace.ID? = nil, close: @escaping () -> Void,
         pause: (() -> Void)? = nil, tap: @escaping () -> Void) {
        title = row.title; symbol = row.symbol; host = row.host; on = row.showing; front = row.front
        self.glyphs = glyphs; cardID = row.id
        playing = row.playing || row.muted
        muted = row.muted
        self.indent = indent; self.picked = picked; self.close = close; self.pause = pause; self.tap = tap
        middleClickCloses = !row.pinned
    }

    var body: some View {
        HStack(spacing: 9) {
            if let disclosure {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(disclosure ? 90 : 0)).frame(width: 8)
            }
            if !stack.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(Array(stack.prefix(2).enumerated()).reversed(), id: \.offset) { index, host in
                        SpaceRowGlyph(host: host, symbol: "doc", title: "", size: 14)
                            .padding(1.5).background(Circle().fill(.background))
                            .offset(x: CGFloat(index) * 8)
                    }
                }
                .frame(width: 24, alignment: .leading)
            } else {
                SpaceRowGlyph(host: host, symbol: symbol, title: title, size: 16)
                    .matchedGlyph(cardID, in: glyphs)
            }
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13)).lineLimit(1)
                    .focused($fieldFocused)
                    .onSubmit { finishRename(keeping: true) }
                    .onExitCommand { finishRename(keeping: false) }
                    .onChange(of: fieldFocused) { _, focused in if !focused { finishRename(keeping: true) } }
                    .onAppear { draft = title; fieldFocused = true }
            } else {
                Text(title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(dim && !front ? .secondary : .primary)
            }
            Spacer(minLength: 2)
            if let trailing, !hover { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
            if let addMenu, hover {
                SidebarMenuButton(menu: addMenu)
                    .frame(width: 18, height: 18)
                    .help("Add a Card to \(title)")
            }
            if playing {
                // Arc's speaker: says the tab is making sound, and stops it.
                Button { pause?() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(muted ? "Unmute" : "Pause")
                .accessibilityLabel(muted ? "Muted. Unmute" : "Playing. Pause")
            }
            if hover || front, let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.leading, indent ? 26 : 10).padding(.trailing, 6)
        .frame(height: 32)
        .background {
            if front { SpaceSelectedFill(radius: 8) }
            else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(on ? 0.07 : hover ? 0.05 : 0))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .background { if middleClickCloses { MiddleClickArea(enabled: !editing) { close?() } } }
        .onHover { hover = $0 }
        .onTapGesture { if !editing { tap() } }
        // Simultaneous, so the first click still shows the row at once instead of waiting out the
        // double-click interval.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !editing { rename?() } })
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(front ? .isSelected : [])
    }
}

extension SpaceSidebarRow {
    /// Guarded on `editing`: ending blurs the field, and the blur would end it again — after Escape,
    /// committing what Escape refused.
    fileprivate func finishRename(keeping: Bool) {
        guard editing else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename?(keeping && !name.isEmpty && name != title ? name : nil)
    }
}

/// A row's mark: the site's icon once seen, else the card kind's symbol, else an initial.
struct SpaceRowGlyph: View {
    var host: String?
    var symbol: String?
    var title: String
    var size: CGFloat

    init(host: String?, symbol: String?, title: String, size: CGFloat) {
        self.host = host; self.symbol = symbol; self.title = title; self.size = size
    }

    init(row: SpaceFrame.Row, size: CGFloat) {
        self.init(host: row.host, symbol: row.symbol, title: row.title, size: size)
    }

    var body: some View {
        if let host, let icon = FaviconLoader.shared.cached(for: host) {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if host == nil, let symbol {
            Image(systemName: symbol).font(.system(size: size * 0.78)).foregroundStyle(.secondary).frame(width: size, height: size)
        } else {
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: size * 0.58, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color(nsColor: .systemGray)))
                .onAppear { if let host { FaviconLoader.shared.warm(hosts: [host]) } }
        }
    }
}

/// Arc's mini player, at the sidebar's foot: a card making sound that isn't on screen. Click to go to
/// it; play/pause, picture-in-picture, and dismiss (which pauses).
struct SpaceMiniPlayer: View {
    let row: SpaceFrame.Row
    let frame: SpaceFrame
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            SpaceRowGlyph(row: row, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(row.playing ? "Playing" : "Paused").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            button(row.playing ? "pause.fill" : "play.fill", row.playing ? "Pause" : "Play") { frame.playerToggle() }
            button("pip.enter", "Picture in Picture") { frame.playerPictureInPicture() }
            if hover { button("xmark", "Dismiss") { frame.playerDismiss() } }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.09 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { frame.show(row.id) }
        .help("Go to \(row.title)")
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The sidebar foot's downloads arrow (Arc's): a ring while one runs, a dot once one finishes unseen.
struct SpaceDownloadsButton: View {
    var downloads = CanvasDownloads.shared
    @State private var open = false
    @State private var seen = 0

    var body: some View {
        Button { open.toggle(); seen = downloads.finishedCount } label: {
            Image(systemName: downloads.running ? "arrow.down.circle.dotted" : "arrow.down.circle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .overlay(alignment: .topTrailing) {
                    if downloads.finishedCount > seen {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                            .transition(Motion.moving(.scale(scale: 0.4).combined(with: .opacity)))
                    }
                }
                .animation(Motion.animation(.easeOut(duration: 0.15)), value: downloads.finishedCount > seen)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Downloads (⌥⌘L)")
        .popover(isPresented: $open, arrowEdge: .top) {
            CanvasDownloadsList().frame(width: 340, height: 360)
        }
        .onAppear { seen = downloads.finishedCount }
    }
}

private extension View {
    /// The card's icon as one view wherever it shows (a row, a favourite), when there's a namespace.
    @ViewBuilder
    func matchedGlyph(_ id: String?, in namespace: Namespace.ID?) -> some View {
        if let id, let namespace { matchedGeometryEffect(id: id, in: namespace) } else { self }
    }
}

/// A place in the sidebar a dragged row can go — or files from Finder, which land there as file cards
/// (`SpaceFrame.landFiles`). The spot follows the pointer; the drop happens on letting go
/// (`SpaceFrame.land`).
struct SpaceRowDropTarget: DropDelegate {
    /// What every sidebar target takes: a row, or files.
    static let types: [UTType] = [SpaceRowDrag.type, .fileURL]

    let frame: SpaceFrame
    /// Every spot this target marks, so leaving it clears its own mark and no other.
    let owned: [SpaceFrame.DropSpot]
    let spot: (CGPoint) -> SpaceFrame.DropSpot?

    /// Files rather than a row: nothing of the sidebar's is in flight. A web card's row carries its
    /// address as a URL, never a file URL, so it can't pass for one.
    private func isFiles(_ info: DropInfo) -> Bool {
        frame.dragging == nil && frame.draggingWorkspace == nil && info.hasItemsConforming(to: [.fileURL])
    }

    /// Where files would go: not between workspace rows, which only reorder them.
    private func spot(for info: DropInfo) -> SpaceFrame.DropSpot? {
        let spot = spot(info.location)
        if isFiles(info), case .workspaceSlot? = spot { return nil }
        return spot
    }

    func validateDrop(info: DropInfo) -> Bool {
        frame.dragging != nil || frame.draggingWorkspace != nil || isFiles(info)
    }

    func dropEntered(info: DropInfo) { frame.propose(spot(for: info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let spot = spot(for: info)
        frame.propose(spot)
        guard isFiles(info) else { return DropProposal(operation: .move) }
        return DropProposal(operation: spot == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        if let current = frame.dropSpot, owned.contains(current) { frame.dropSpot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let spot = spot(for: info) else { frame.dropSpot = nil; return false }
        guard isFiles(info) else {
            frame.land(at: spot)
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var files: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { files.append(url) }
            }
            frame.landFiles(files, at: spot)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }
}

/// A small + that drops a menu below itself — a folder's add list. AppKit, so the menu is the add
/// list's `NSMenu` (recent folders, views) rather than a second copy of it in SwiftUI.
struct SidebarMenuButton: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a Card")!,
                              target: context.coordinator, action: #selector(Coordinator.pop(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.menu = menu }

    func makeCoordinator() -> Coordinator { Coordinator(menu: menu) }

    @MainActor
    final class Coordinator: NSObject {
        var menu: () -> NSMenu
        init(menu: @escaping () -> NSMenu) { self.menu = menu }

        @objc func pop(_ sender: NSButton) {
            let below = sender.isFlipped ? sender.bounds.maxY + 4 : -4
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
        }
    }
}
