import AppKit
import PmLib

/// A web link handed to Folio by another app — Mail, Slack, a terminal's ⌘-click, "Open With ▸ Folio".
///
/// **Folio is an alternate handler for http and https, never the default** — the same claim it makes
/// for `.canvas` files (project.yml). It appears in a link's "Open With" and in the default-browser
/// list in System Settings, and only becomes where links go if somebody chooses it there.
///
/// **A link lands as a card on the front window's board**, stepped into so the page is live and the
/// keys are its own — the same place ⌘-click on a page puts one. A board that already has a card on
/// that address shows that card instead: a board is a set of things you keep, and the second card on
/// one address is a duplicate, not a second tab.
@MainActor
enum CanvasIncomingLinks {
    static func handles(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func open(_ url: URL) {
        // A satellite in front is where you are working: the link is a tab in it, as a ⌘-click on one
        // of its pages is. Its project window may well be put away behind it.
        if let satellite = NSApp.orderedWindows.lazy.compactMap({ $0.windowController }).first
            as? CanvasSatelliteWindow,
           let board = satellite.board, let shown = satellite.shownCard?.node.id,
           board.tiling?.position(of: shown) != nil,
           let normalized = CanvasAddress.normalized(url.absoluteString) {
            satellite.window?.makeKeyAndOrderFront(nil)
            var added: String?
            board.addingTab(to: shown) {
                let at = board.centreOfVisibleBoard
                added = board.addCard(CanvasNode(content: .link(url: normalized),
                                                 frame: CanvasRect(x: at.x - 200, y: at.y - 200,
                                                                   width: 400, height: 400)),
                                      actionName: "Add Web Card")
            }
            if let added { board.lendNewTab(added, to: satellite, showing: true) }
            return
        }
        let front = NSApp.orderedWindows.lazy
            .compactMap { $0.windowController as? ProjectWindowController }.first
            ?? WindowManager.shared.openFocusedProject()
        onBoard(of: front) { $0.openIncomingLink(url.absoluteString) }
    }

    /// A page carried in by the quick bar, to a project it was told — see `QuickBarModel.page`.
    ///
    /// Into one of the project's workspaces — never the canvas, where a page lands somewhere nobody is
    /// looking (`goToWorkspaceForIncomingPage`). With `inNewWindow`, out of it into a satellite of its
    /// own; the card keeps its tile in the workspace, so Bring Back has somewhere to put it.
    static func open(_ url: URL, inProject key: String, inNewWindow: Bool) {
        let window = WindowManager.shared.open(projectKey: key)
        window.showWorkspaceForIncomingPage()
        // A window just opened, or just switched tabs, builds its board on the next pass, and a
        // workspace lays its tiles out a turn or more after that.
        DispatchQueue.main.async {
            guard let pane = window.canvasPane else {
                Log.write("incoming page: no board to put it on")
                return
            }
            pane.whenTiled { [weak pane] in
                guard let board = pane?.board else { return }
                place(url, on: board, inNewWindow: inNewWindow)
            }
        }
    }

    private static func place(_ url: URL, on board: CanvasBoardView, inNewWindow: Bool) {
        guard inNewWindow else {
            board.openIncomingLink(url.absoluteString)
            return
        }
        guard let id = board.cardForIncomingLink(url.absoluteString) else { return }
        // The card's view is built as the board refreshes for the change that added it.
        DispatchQueue.main.async {
            if let out = board.nodeViews[id]?.lentTo {
                out.window?.makeKeyAndOrderFront(nil)
            } else if board.moveToWindow([id], showing: id) == nil {
                Log.write("incoming page: no view for \(id); left in the workspace")
                board.engage(cardWithID: id)
            }
        }
    }

    /// Run `then` with `window`'s board, brought forward and showing the board.
    private static func onBoard(of window: ProjectWindowController,
                                then: @escaping @MainActor (CanvasBoardView) -> Void) {
        window.show()
        window.setRenderer(.canvas)
        // A window just opened, or just switched to its canvas tab, builds its board on the next pass.
        DispatchQueue.main.async {
            guard let pane = window.canvasPane else {
                Log.write("incoming link: no board to put it on")
                return
            }
            // A link is a request to see the page, and List and Grid show no page. On the board the
            // card is placed and stepped into; in a lens it went into a frame on a board hidden
            // behind the list.
            if pane.presentation != .board { pane.presentation = .board }
            then(pane.board)
        }
    }
}

extension CanvasBoardView {
    func openIncomingLink(_ address: String) {
        guard let id = cardForIncomingLink(address) else { return }
        (scrollView as? CanvasScrollView)?.reveal(id)
        // The card's view is built as the board refreshes for the change above.
        DispatchQueue.main.async { [weak self] in self?.engage(cardWithID: id) }
    }

    /// The card on `address`, selected: the one already on this board if there is one, else a new one.
    func cardForIncomingLink(_ address: String) -> String? {
        guard let normalized = CanvasAddress.normalized(address) else { return nil }
        if let existing = document.nodes.first(where: {
            if case .link(let url) = $0.content { return CanvasAddress.normalized(url) == normalized }
            return false
        }) {
            // Into the workspace that's up when it lives elsewhere on the board: found but out of
            // sight is the same as not found.
            if isTiled, tiling?.position(of: existing.id) == nil { addToTiling(existing.id) }
            select([existing.id])
            return existing.id
        }
        let at = centreOfVisibleBoard
        return addCard(CanvasNode(content: .link(url: normalized),
                                  frame: CanvasRect(x: at.x - 200, y: at.y - 200, width: 400, height: 400)),
                       actionName: "Add Web Card")
    }
}

extension CanvasBoardView {
    /// Hand a card that has just joined a satellite's tile to that satellite as a tab.
    ///
    /// The card has no view until its tile shows it, so the tile is shown it first — behind the
    /// satellite, in a workspace window that may be put away — and the view is lent once it exists.
    func lendNewTab(_ id: String, to satellite: CanvasSatelliteWindow, showing: Bool) {
        showTab(id)
        func lend() -> Bool {
            guard let card = nodeViews[id] else { return false }
            satellite.adopt(card, showing: showing)
            return true
        }
        if lend() { return }
        DispatchQueue.main.async {
            if !lend() { Log.write("satellite tab: no view for \(id); left in the workspace") }
        }
    }
}
