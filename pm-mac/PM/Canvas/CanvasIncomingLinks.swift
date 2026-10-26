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
        front.show()
        front.setRenderer(.canvas)
        // A window just opened, or just switched to its canvas tab, builds its board on the next pass.
        DispatchQueue.main.async {
            guard let pane = front.canvasPane else {
                Log.write("incoming link: no board to put it on")
                return
            }
            // A link is a request to see the page, and List and Grid show no page. On the board the
            // card is placed and stepped into; in a lens it went into a frame on a board hidden
            // behind the list.
            if pane.presentation != .board { pane.presentation = .board }
            pane.board.openIncomingLink(url.absoluteString)
        }
    }
}

extension CanvasBoardView {
    func openIncomingLink(_ address: String) {
        guard let normalized = CanvasAddress.normalized(address) else { return }
        let id: String
        if let existing = document.nodes.first(where: {
            if case .link(let url) = $0.content { return CanvasAddress.normalized(url) == normalized }
            return false
        }) {
            id = existing.id
            select([id])
        } else {
            let at = centreOfVisibleBoard
            id = addCard(CanvasNode(content: .link(url: normalized),
                                    frame: CanvasRect(x: at.x - 200, y: at.y - 200, width: 400, height: 400)),
                         actionName: "Add Web Card")
        }
        (scrollView as? CanvasScrollView)?.reveal(id)
        // The card's view is built as the board refreshes for the change above.
        DispatchQueue.main.async { [weak self] in self?.engage(cardWithID: id) }
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
