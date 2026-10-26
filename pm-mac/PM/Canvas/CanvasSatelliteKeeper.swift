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
/// **A window closing keeps them too**: closing one window changes nothing else on screen. Only a
/// tab closing puts its satellites away, to come back with it.
@MainActor
enum CanvasSatelliteKeeper {
    /// Set while a window is dropping its panes for a project switch or its own close.
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

    // MARK: Across a relaunch

    /// The kept boards at quit — the workspaces with satellites out and no window — so the next launch
    /// brings them out again with no window either. A workspace in a window comes back with that
    /// window (`CanvasBoardView.restoreSatellites`).
    static let keptKey = "PMCanvasKeptWorkspaces"

    private struct Kept: Codable {
        var project: String?
        var canvas: String
        var workspace: String
    }

    /// Written at quit, while the kept boards are still here to say what they are.
    static func rememberKept(in defaults: UserDefaults = .standard) {
        let all = kept.map(\.board).filter { !$0.satellites.isEmpty }.map { board in
            Kept(project: board.boardProject?.key, canvas: board.store.url.path, workspace: board.satelliteScope)
        }
        defaults.set(all.isEmpty ? nil : try? JSONEncoder().encode(all), forKey: keptKey)
    }

    /// At launch: each workspace kept at quit up in a window that is never shown, which brings its
    /// satellites out where they were and is closed once it has — keeping its board for them, as a
    /// window closing does. What it showed for its project is put back as it was: the window was never
    /// one you opened.
    static func restoreKept(in defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: keptKey),
              let all = try? JSONDecoder().decode([Kept].self, from: data) else { return }
        defaults.removeObject(forKey: keptKey)
        for entry in all {
            let canvas = URL(fileURLWithPath: entry.canvas)
            guard FileManager.default.fileExists(atPath: canvas.path),
                  !CanvasSatellites.records(canvas: canvas, workspace: entry.workspace, in: defaults).isEmpty,
                  entry.project.map({ PMFiles.projectName(fromKey: $0) != nil }) ?? true else { continue }
            let tabs = ProjectTabMemory.stored(for: entry.project)
            let carrier = WindowManager.shared.open(projectKey: entry.project, reusingExistingWindow: false,
                                                    canvas: entry.project == nil ? canvas : nil, carrier: true)
            carriers.append((carrier, entry.project, tabs, canvas.standardizedFileURL, entry.workspace))
            carrier.showTab(entry.workspace.isEmpty ? .board(.whole) : .board(.workspace(entry.workspace)))
            // A workspace that cannot come up — gone from its canvas, say — still lets its window go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak carrier] in
                if let carrier { closeCarrier(carrier) }
            }
        }
    }

    /// The windows `restoreKept` has open: what their project's tabs were before them, and the
    /// workspace each is there for.
    private static var carriers: [(controller: ProjectWindowController, project: String?, tabs: Data?,
                                   canvas: URL, workspace: String)] = []

    /// A board has brought its satellites out: the one a carrier is there for lets the carrier go. Not
    /// another board on the way — the carrier may open on another tab before it gets to its workspace.
    static func satellitesRestored(on board: CanvasBoardView) {
        guard let controller = board.window?.windowController as? ProjectWindowController,
              let carrier = carriers.first(where: { $0.controller === controller }),
              carrier.canvas == board.store.url.standardizedFileURL,
              carrier.workspace == board.satelliteScope else { return }
        closeCarrier(controller)
    }

    private static func closeCarrier(_ controller: ProjectWindowController) {
        guard let index = carriers.firstIndex(where: { $0.controller === controller }) else { return }
        let carrier = carriers.remove(at: index)
        controller.close()
        ProjectTabMemory.restore(carrier.tabs, for: carrier.project)
    }

    /// Show Window for a kept board: a window on its project — or its canvas file — at its workspace.
    static func reopen(_ board: CanvasBoardView) {
        ProjectWindowController.showWorkspace(board.satelliteScope, projectKey: board.boardProject?.key,
                                              canvas: board.store.url)
    }
}
