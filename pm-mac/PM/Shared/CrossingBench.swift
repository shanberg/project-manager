import AppKit

/// Press ⌘Return for you, twenty times, identically.
///
/// **A crossing measured once by hand is not measured.** `FrameMeter` reports what one crossing cost,
/// and the differences worth acting on here are a few milliseconds off a p95 — comfortably inside the
/// spread between two runs on the same build. Worse, a hand-run comparison changes two things at once:
/// a marquee drag never selects quite the same cards twice, and a workspace of six tiles and one of
/// nine are not the same measurement. So the answer comes back different and nothing has been learnt.
///
/// This does the same crossing on the same cards as many times as asked, so the numbers can be pooled
/// and the two builds actually compared. It drives the board through the callbacks the tab bar uses —
/// `onGoToCanvas` and `onGoToWorkspace` — so what runs is the real crossing, `restoreTiling` and
/// `leaveTiling` by way of `CanvasPaneController.arrive(from:)`, and not a private shortcut to it.
///
/// **Off unless the meter is on**, which means off unless somebody has deliberately turned it on for
/// this machine — see `FrameMeter.isEnabled`. `pmpanel://bench` does nothing whatever otherwise, and
/// the URL grammar the panel and Raycast use is unchanged for everybody else.
@MainActor
enum CrossingBench {

    /// The workspace the bench makes and bounces in and out of.
    ///
    /// Named rather than left to `WorkspaceNamePrompt.freshName`, for two reasons that are both about
    /// being able to trust the numbers: the same name means the same workspace across runs and builds
    /// rather than a fresh "Workspace 4" each time, and a name you can recognise is a name you can
    /// delete from its chip when you are done benching.
    static let workspaceName = "Crossing Bench"

    /// How long between crossings.
    ///
    /// Longer than it looks like it needs to be, and every part of the gap is spoken for: the movement
    /// is 0.3s, `FrameMeter` watches for 1.2s so that the page budget's settling pass at +0.75s is
    /// inside the measurement, and a crossing started before that finished would abandon it. What is
    /// left over is a moment for the machine to be idle, so that each measurement starts from the same
    /// place rather than in the wake of the last one.
    private static let interval: TimeInterval = 2.0

    /// The configuration the crossings being measured right now are running under — see `FrameMeter`,
    /// which puts it on every line.
    private(set) static var configurationName = "[shipping]"

    /// Walk every configuration in `CrossingTuning.spread`, `rounds` round trips apiece —
    /// **interleaved, not in blocks.**
    ///
    /// Running each configuration's crossings together is the obvious arrangement and it produced a
    /// table that could not be read. A board does not sit still between crossings: the page budget
    /// wakes and freezes renderers as the tiling comes and goes (`canvas pages live: 6 of 6` then
    /// `1 of 6`, over and over), pages finish loading minutes after the window opens, and the machine
    /// warms up. All of that drifts across a run, so in blocks it lands on whichever configuration
    /// happened to be running at the time — and the first block, measured while the pages were still
    /// frozen, came out best no matter what it was testing.
    ///
    /// Interleaved, the drift is shared. Each configuration takes one round trip and hands over, so a
    /// slow minute costs every configuration a crossing rather than costing one configuration all of
    /// them.
    ///
    /// **One configuration per round *trip*, not per crossing.** There are eight configurations and
    /// the direction alternates, so rotating on every crossing would give each configuration the same
    /// parity for ever — one would only ever be measured going in, another only coming out, and those
    /// are not the same cost.
    static func runSpread(each rounds: Int, tiles: Int, all: Bool = false) {
        guard FrameMeter.isEnabled else { return declineWithoutTheMeter() }
        guard !screenIsLocked else { return Log.write("BENCH declined: the screen is locked") }
        guard let board = frontBoard() else { return Log.write("BENCH declined: no board in front") }
        guard let plan = prepare(board: board, tiles: tiles) else { return }
        guard board.onTileAsWorkspace(plan) else {
            return Log.write("BENCH declined: this window will not keep a workspace")
        }
        walking = all ? CrossingTuning.spread : CrossingTuning.focused
        let total = rounds * walking.count * 2
        Log.write("BENCH spread interleaved: \(walking.count) configurations "
            + "× \(rounds) round trips of \(plan.ids.count) tiles — \(total) crossings")
        cross(0, of: total)
    }

    /// The configurations this run is walking — the focused set, or all of them.
    private static var walking: [(name: String, tuning: CrossingTuning)] = CrossingTuning.focused

    /// One crossing, then the next, rotating the configuration every round trip.
    private static func cross(_ index: Int, of total: Int) {
        guard index < total else {
            CrossingTuning.current = .shipping
            configurationName = "[shipping]"
            return Log.write("BENCH spread done")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                guard !screenIsLocked else {
                    return Log.write("BENCH stopped: the screen locked mid-run")
                }
                guard let board = frontBoard() else { return Log.write("BENCH stopped: no board") }
                let entry = walking[(index / 2) % walking.count]
                CrossingTuning.current = entry.tuning
                configurationName = "[\(entry.name)]"
                if index.isMultiple(of: 2) {
                    board.onGoToCanvas()
                } else {
                    board.onGoToWorkspace(workspaceName)
                }
                cross(index + 1, of: total)
            }
        }
    }

    /// The workspace the run bounces through, saved under our own name so the same cards resume the
    /// same workspace across runs and builds. Nil when the board cannot supply one.
    private static func prepare(board: CanvasBoardView, tiles: Int) -> CanvasViewState.Tiling? {
        let cards = board.document.nodes.filter { !$0.isGroup }.prefix(tiles).map(\.id)
        guard cards.count >= 2 else {
            Log.write("BENCH declined: \(cards.count) cards on the board")
            return nil
        }
        let plan = CanvasViewState.Tiling(ids: Array(cards), arrangement: .grid,
                                          masterFraction: CanvasTiling.savedMasterFraction,
                                          sizes: nil)
        CanvasWorkspaces.save(plan, as: workspaceName, for: board.store.url)
        return plan
    }

    private static func declineWithoutTheMeter() {
        Log.write("BENCH declined: the frame meter is off "
            + "(defaults write com.stuarthanberg.pm PMFrameMeterEnabled -bool YES)")
    }

    /// Run `iterations` crossings, alternating out of the workspace and back into it.
    static func run(iterations: Int, tiles: Int, then finished: (() -> Void)? = nil) {
        guard FrameMeter.isEnabled else { return declineWithoutTheMeter() }
        guard let board = frontBoard() else {
            Log.write("BENCH declined: no board in front")
            return finished?() ?? ()
        }
        let cards = board.document.nodes.filter { !$0.isGroup }.prefix(tiles).map(\.id)
        guard cards.count >= 2 else {
            return Log.write("BENCH declined: \(cards.count) cards on the board")
        }
        // Saved under our own name *before* the window is asked to make the workspace, so that
        // `ProjectSplitViewController.tileAsWorkspace` finds one with this exact card set already
        // there and opens a tab on it rather than minting `Workspace 2`. See its note on why the
        // same cards resume the same workspace.
        let plan = CanvasViewState.Tiling(ids: Array(cards), arrangement: .grid,
                                          masterFraction: CanvasTiling.savedMasterFraction,
                                          sizes: nil)
        CanvasWorkspaces.save(plan, as: workspaceName, for: board.store.url)
        // Opens its tab, which is what the alternation below needs: with no tab on the workspace,
        // `goToWorkspace(named:)` lays the tiles into the pane it is already in and nothing crosses.
        guard board.onTileAsWorkspace(plan) else {
            return Log.write("BENCH declined: this window will not keep a workspace")
        }
        Log.write("BENCH \(iterations) crossings of \(cards.count) tiles, \(interval)s apart")
        step(0, of: iterations, then: finished)
    }

    /// One crossing, then the next. Recursive rather than a repeating timer so a step that cannot find
    /// a board stops the run instead of logging the same complaint every two seconds.
    private static func step(_ index: Int, of total: Int, then finished: (() -> Void)?) {
        guard index < total else {
            Log.write("BENCH done")
            return finished?() ?? ()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                // Found again every time: each crossing swaps the pane, so the board that ran the last
                // one is not the board on screen now. See `ProjectContentPane.show`.
                guard !screenIsLocked else {
                    Log.write("BENCH stopped: the screen locked mid-run")
                    return finished?() ?? ()
                }
                guard let board = frontBoard() else {
                    Log.write("BENCH stopped: no board")
                    return finished?() ?? ()
                }
                if index.isMultiple(of: 2) {
                    board.onGoToCanvas()
                } else {
                    board.onGoToWorkspace(workspaceName)
                }
                step(index + 1, of: total, then: finished)
            }
        }
    }

    /// Whether the screen is locked — **the one condition that makes a run silently worthless.**
    ///
    /// Nothing is presented to a locked screen, so `CADisplayLink` does not tick and every measurement
    /// collects nothing and is abandoned by the next crossing. That reads in the log like a bench
    /// firing too fast rather than like a dead clock, and it costs a whole run to work out. Checked
    /// before a run and again at every step, because a screen that locks halfway through takes the
    /// second half of the spread with it.
    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The board in the front window, wherever it is in its view tree.
    ///
    /// Searched for rather than reached through the window controller, which would mean opening up
    /// `ProjectWindowController.split` and `CanvasPaneController.scroll` — two private properties made
    /// internal for the benefit of a bench. A dev-only tool should not be why a boundary moves.
    private static func frontBoard() -> CanvasBoardView? {
        let window = WindowManager.shared.frontmost?.window ?? NSApp.mainWindow ?? NSApp.keyWindow
        return window?.contentView.flatMap(descend)
    }

    private static func descend(_ view: NSView) -> CanvasBoardView? {
        if let board = view as? CanvasBoardView { return board }
        for sub in view.subviews {
            if let found = descend(sub) { return found }
        }
        return nil
    }
}
