import AppKit

/// Satellites outliving their window's project: the board they came from, kept while they are out.
///
/// **A satellite's content is lent, not given** (`CanvasSatelliteWindow`): the card that owns it is on a
/// board, and the board is what keeps the card. Pointing a project window at another project drops
/// every pane it had and tears their boards down, which used to put the satellites away with them.
/// Satellites stay out while another workspace is up, and another project is the same case to the
/// person looking at them — so a pane being dropped by that switch, with satellites out, is kept here
/// instead of torn down: off screen, its board without a window, its satellites still out and in the
/// dock.
///
/// **Handed back, not kept for ever.** The board lets go once its last satellite has come home, and a
/// board that comes up on the same workspace in any window takes the satellites over — put away where
/// they are and brought out again on the board that can show them (`CanvasBoardView.restoreSatellites`).
/// The dock's Show Window, for a kept board, is what asks for that window (`reopen`).
///
/// Only a project switch keeps anything. A window closing, or a tab closing, still puts its
/// satellites away, to come back with it.
@MainActor
enum CanvasSatelliteKeeper {
    /// Set while a window is dropping its panes for a project switch.
    private(set) static var isKeeping = false
    private static var kept: [CanvasPaneController] = []

    /// Drop panes — `work` — keeping any whose board has satellites out.
    static func keepingSatellitesOut(_ work: () -> Void) {
        isKeeping = true
        defer { isKeeping = false }
        work()
    }

    /// From a pane being dropped: whether it is kept rather than torn down.
    static func keep(_ pane: CanvasPaneController) -> Bool {
        guard isKeeping, !pane.board.satellites.isEmpty, !kept.contains(where: { $0 === pane }) else { return false }
        kept.append(pane)
        return true
    }

    static func isKept(_ board: CanvasBoardView) -> Bool { kept.contains { $0.board === board } }

    /// A board has come up on a workspace a kept board has satellites out for: they are put away where
    /// they are, for `board` to bring out again. The kept board lets go as its last one closes.
    static func adopt(by board: CanvasBoardView) {
        for pane in kept where pane.board !== board
            && pane.board.store.url == board.store.url && pane.board.satelliteScope == board.satelliteScope {
            for satellite in pane.board.satellites { satellite.putAway() }
        }
    }

    /// A satellite has closed: a kept board with none left is torn down, on the next turn — out of the
    /// window's own close.
    static func releaseIfDone(_ board: CanvasBoardView) {
        guard board.satellites.isEmpty, let index = kept.firstIndex(where: { $0.board === board }) else { return }
        let pane = kept.remove(at: index)
        DispatchQueue.main.async { pane.teardown() }
    }

    /// Show Window for a kept board: a window on its project — or its canvas file — at its workspace.
    static func reopen(_ board: CanvasBoardView) {
        ProjectWindowController.showWorkspace(board.satelliteScope, projectKey: board.boardProject?.key,
                                              canvas: board.store.url)
    }
}
