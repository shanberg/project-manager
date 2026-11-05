import AppKit
import PmLib
import SwiftUI

/// The Arc-style frame over a space's board: the sidebar lists the board, the window's content is the
/// workspace. docs/spaces.md § The frame.
///
/// - Rows are the board's cards: favourites as icons, then Pinned (named workspaces first, then pinned
///   cards), then Today. Frames on the board are folders.
/// - Clicking a card already showing brings it forward; one in a named workspace jumps there; any other
///   replaces the tile you're in (alone, if you were in a named workspace).
/// - ⌥-click: a tile beside. ⌘-click picks; ⌘↩ tiles the picked as a new workspace.
/// - Lives in the project window's sidebar slot, in place of the project list, for a space's window.
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

    let spaceID: String
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
    /// The front card's address, for ⌘L to start from.
    private(set) var frontAddress = ""

    @ObservationIgnored private weak var split: ProjectSplitViewController?
    @ObservationIgnored private let store: CanvasDocumentStore
    @ObservationIgnored private let canvas: URL

    init(spaceID: String, canvas: URL, store: CanvasDocumentStore, split: ProjectSplitViewController) {
        self.spaceID = spaceID
        self.canvas = canvas
        self.store = store
        self.split = split
        store.addWatcher(self, changed: { [weak self] in self?.refresh() }, reloaded: { [weak self] in self?.refresh() })
        refresh()
    }

    func stop() { store.removeWatcher(self) }

    private var pane: CanvasPaneController? { split?.canvasPane }
    private var board: CanvasBoardView? { pane?.board }

    // MARK: Reading the board

    func refresh() {
        let document = store.document
        let board = self.board
        let tiled = Set(board?.tiling?.ids ?? [])
        let front = board?.focusedTile ?? (tiled.count == 1 ? tiled.first : nil)
        let lookups = CanvasExistingCards.lookups(isFolder: { board?.isFolderPath($0) ?? false })
        let sections = CanvasItems.sections(of: document, showing: [], lookups: lookups)
        func row(_ item: CanvasItem) -> Row? {
            guard let node = document.node(id: item.id) else { return nil }
            var host: String?, symbol: String?
            switch item.kind {
            case .page(let h): host = h
            case .file(let s), .view(let s): symbol = s
            case .text: symbol = "text.alignleft"
            }
            let title = board?.describeCard(item.id)?.title ?? item.title
            return Row(id: item.id, title: title, host: host, symbol: symbol,
                       pinned: SpaceCardMarks.isPinned(node), favorite: SpaceCardMarks.isFavorite(node),
                       showing: tiled.contains(item.id), front: item.id == front)
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
        self.favorites = favorites
        self.pinned = pinned
        self.today = today
        cardCount = sections.reduce(0) { $0 + $1.items.count }
        let current = board?.workspaceName
        workspaces = CanvasWorkspaces.names(of: canvas).map { name in
            let ids = CanvasWorkspaces.tiling(named: name, of: canvas)?.ids ?? []
            let hosts = ids.prefix(3).map { id -> String? in
                if case .link(let url)? = document.node(id: id)?.content { return URL(string: url)?.host() }
                return nil
            }
            return Workspace(name: name, hosts: hosts, showing: current == name && (board?.isTiled ?? false))
        }
        boardShowing = !(board?.isTiled ?? false)
        frontHost = front.flatMap { id in
            if case .link(let url)? = document.node(id: id)?.content { return URL(string: url)?.host() }
            return nil
        }
        picked = picked.filter { document.node(id: $0) != nil }
        let space = Spaces.shared.space(spaceID)
        spaceTitle = space?.title ?? ""
        washColor = space.flatMap { ProjectColor(value: $0.color) }
        spaceColor = Color(nsColor: washColor?.nsColor ?? .systemGray)
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
        show(id)
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
            split.openTab(.board(.workspace(name)))
            split.canvasPane?.whenInWorkspace(name) { [weak self] in
                self?.board?.showTab(id)
                self?.refresh()
            }
            return refresh()
        }
        // Anywhere else replaces the tile you're in. In a named workspace, that's leaving it for the
        // card on its own, on the board's own tab.
        if board.workspaceName != nil || split.canvasPane?.focus != .whole {
            split.goToCanvas()
            guard let canvasBoard = self.board else { return }
            alone(id, on: canvasBoard)
            return refresh()
        }
        if board.isTiled, let tile = board.focusedTile ?? board.tiling?.ids.first {
            board.replaceInTiling(tile, with: id)
            board.select([id])
        } else {
            board.tile([id])
        }
        refresh()
    }

    private func alone(_ id: String, on board: CanvasBoardView) {
        if let tiling = board.tiling, tiling.ids.count == 1, let only = tiling.ids.first {
            board.replaceInTiling(only, with: id)
            board.select([id])
        } else {
            if board.isTiled { board.leaveTiling(animated: false) }
            board.tile([id])
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

    func showWorkspace(_ name: String) {
        split?.openTab(.board(.workspace(name)))
        refresh()
    }

    func deleteWorkspace(_ name: String) {
        split?.tabModel.deleteWorkspace(name)
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
        board.select([id])
        board.deleteSelection()
        refresh()
    }

    /// ⌘W: the card in front, closed as above. False when there's none, so the window closes instead.
    /// ⌘W: the focused tile out of the layout — the card stays in the sidebar, and ⌘Z puts it back.
    /// False with no tile focused, so the window closes instead.
    func closeFront() -> Bool {
        guard let board, board.isTiled, let id = board.focusedTile ?? board.tiling?.ids.first else { return false }
        board.closeInTiling([id])
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

    // MARK: New tab

    /// ⌘T: the address field, for a new card.
    func askForAddress() {
        editingFront = false
        addressRequests += 1
    }

    /// ⌘L: the address field on the page in front, to send it somewhere else — as Arc's ⌘L.
    func editFrontAddress() {
        guard let card = frontPage else { return askForAddress() }
        frontAddress = card.url?.absoluteString ?? ""
        editingFront = true
        addressRequests += 1
    }

    /// The web card in front: the one you're in, else the focused tile's.
    private var frontPage: CanvasLinkNodeView? {
        guard let board else { return nil }
        if let engaged = board.engagedPageCard as? CanvasLinkNodeView { return engaged }
        return board.focusedTile.flatMap { board.nodeViews[$0] } as? CanvasLinkNodeView
    }

    /// The address field gave up the keyboard without a line.
    func addressCancelled() { editingFront = false }

    /// The address field's line: the page in front sent there (⌘L), or a web card in Today, shown in
    /// the tile you're in (⌘T).
    func open(_ typed: String) {
        let engine = CanvasSearchEngine.current == .none ? .duckDuckGo : CanvasSearchEngine.current
        guard let board, let address = CanvasAddress.resolved(typed, engine: engine) else { return }
        if editingFront, let card = frontPage {
            editingFront = false
            return card.go(to: address)
        }
        editingFront = false
        let right = store.document.nodes.map { $0.frame.x + $0.frame.width }.max() ?? 0
        let node = CanvasNode(content: .link(url: address),
                              frame: CanvasRect(x: right + 40, y: 0, width: 400, height: 400))
        let id = board.addCard(node, actionName: "New Tab")
        show(id)
    }
}

// MARK: - The sidebar

/// Arc's sidebar, over a board: the address under the window's buttons, favourites as tiles, the
/// board's pinned cards, a rule, New Tab and today's cards, the space's name at the foot.
struct SpaceFrameSidebar: View {
    @Bindable var frame: SpaceFrame
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            addressField
            if !frame.favorites.isEmpty { favorites }
            // The list fills the scroll area at least, so the empty sidebar under the last row is the
            // drag area behind the rows rather than the scroll view's own ground (which moves nothing).
            GeometryReader { area in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SpaceSidebarRow(title: "Board", symbol: "rectangle.on.rectangle.angled",
                                    trailing: "\(frame.cardCount)", on: frame.boardShowing, dim: true) { frame.showBoard() }
                    ForEach(frame.workspaces) { workspace in
                        SpaceSidebarRow(title: workspace.name, stack: workspace.hosts, on: workspace.showing) {
                            frame.showWorkspace(workspace.name)
                        }
                        .contextMenu { Button("Delete Workspace") { frame.deleteWorkspace(workspace.name) } }
                    }
                    group(frame.pinned)
                    rule
                    SpaceSidebarRow(title: "New Tab", symbol: "plus", dim: true) { frame.askForAddress() }
                    group(frame.today)
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: .topLeading)
                .background { WindowDragArea() }
            }
            .scrollIndicators(.never)
            }
            if !frame.picked.isEmpty {
                Button("Tile \(frame.picked.count) as a Workspace") { frame.tilePicked() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
        .background { SpaceWash(color: frame.washColor, tiled: !frame.boardShowing).ignoresSafeArea() }
        .ignoresSafeArea(edges: .top)
        .onChange(of: frame.addressRequests) {
            address = frame.editingFront ? frame.frontAddress : ""
            addressFocused = true
        }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: frame.frontHost == nil ? "magnifyingglass" : "lock.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            TextField(frame.frontHost ?? "Search or enter address", text: $address)
                .textFieldStyle(.plain)
                .focused($addressFocused)
                .onSubmit {
                    let typed = address.trimmingCharacters(in: .whitespaces)
                    address = ""
                    addressFocused = false
                    if !typed.isEmpty { frame.open(typed) }
                }
                .onExitCommand { address = ""; addressFocused = false; frame.addressCancelled() }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(addressFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
    }

    private var favorites: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 80), spacing: 8)], spacing: 8) {
            ForEach(frame.favorites) { row in
                SpaceFavoriteTile(row: row) { frame.click(row.id) }
                    .contextMenu { menu(for: row) }
            }
        }
    }

    /// Between what's kept and what's today: a hairline, as Arc's.
    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            .padding(.horizontal, 8).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(frame.spaceColor).frame(width: 8, height: 8)
            Text(frame.spaceTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func group(_ group: SpaceFrame.Group) -> some View {
        ForEach(group.loose) { cardRow($0, indent: false) }
        ForEach(group.folders) { folder in
            let open = !frame.closedFolders.contains(folder.id)
            SpaceSidebarRow(title: folder.label, symbol: open ? "folder" : "folder.fill", disclosure: open) {
                if open { frame.closedFolders.insert(folder.id) } else { frame.closedFolders.remove(folder.id) }
            }
            if open { ForEach(folder.rows) { cardRow($0, indent: true) } }
        }
    }

    private func cardRow(_ row: SpaceFrame.Row, indent: Bool) -> some View {
        SpaceSidebarRow(row: row, indent: indent, picked: frame.picked.contains(row.id),
                        close: { frame.close(row.id) }) { frame.click(row.id) }
            .contextMenu { menu(for: row) }
    }

    @ViewBuilder
    private func menu(for row: SpaceFrame.Row) -> some View {
        Button(row.pinned ? "Unpin" : "Pin") { frame.setPinned(row.id, !row.pinned) }
        Button(row.favorite ? "Remove from Favourites" : "Add to Favourites") { frame.setFavorite(row.id, !row.favorite) }
        Button("Open in a Tile Beside") { frame.tileBeside(row.id) }
        Divider()
        Button(row.pinned ? "Unpin" : "Close") { frame.close(row.id) }
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
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            SpaceRowGlyph(row: row, size: 20)
                .frame(maxWidth: .infinity).frame(height: 42)
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
    let tap: () -> Void
    @State private var hover = false

    init(title: String, symbol: String? = nil, stack: [String?] = [], trailing: String? = nil, on: Bool = false,
         dim: Bool = false, disclosure: Bool? = nil, tap: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.stack = stack; self.trailing = trailing
        self.on = on; self.front = on; self.dim = dim; self.disclosure = disclosure; self.tap = tap
    }

    init(row: SpaceFrame.Row, indent: Bool, picked: Bool, close: @escaping () -> Void, tap: @escaping () -> Void) {
        title = row.title; symbol = row.symbol; host = row.host; on = row.showing; front = row.front
        self.indent = indent; self.picked = picked; self.close = close; self.tap = tap
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
            }
            Text(title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(dim && !front ? .secondary : .primary)
            Spacer(minLength: 2)
            if let trailing, !hover { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
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
        .onHover { hover = $0 }
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(front ? .isSelected : [])
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
