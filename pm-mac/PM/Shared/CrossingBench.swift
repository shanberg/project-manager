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

    /// One journey, then the next.
    ///
    /// **Every journey flies the board**, which is why every one of them is worth a number: the picker
    /// zooms out to fit, a peek zooms onto one card, entering a workspace closes on the tiles, and all
    /// of them go through `CanvasScrollView.fly`, where the magnification is what a crossing costs.
    private static func walk(_ index: Int, of total: Int, _ journey: Journey,
                             then finished: (() -> Void)? = nil) {
        guard index < total else {
            Log.write("BENCH done")
            return finished?() ?? ()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                guard !screenIsLocked else {
                    return Log.write("BENCH stopped: the screen locked mid-run")
                }
                // A crossing swaps panes and wants whatever is in front now; the rest act on the tiled
                // board in place. See `tiledBoard`.
                let found = journey == .crossing ? frontBoard() : tiledBoard()
                guard let board = found else {
                    Log.write("BENCH stopped: no board")
                    return finished?() ?? ()
                }
                guard !isHidden(board) else {
                    Log.write("BENCH stopped: the window went behind something mid-run")
                    return finished?() ?? ()
                }
                perform(journey, on: board, at: index)
                walk(index + 1, of: total, journey, then: finished)
            }
        }
    }

    /// What one step of a journey does. Each asks the board what state it is in rather than counting
    /// parity: a peek has to open the picker first, and a step that could not act would otherwise leave
    /// every later step going the wrong way.
    private static func perform(_ journey: Journey, on board: CanvasBoardView, at index: Int) {
        switch journey {
        case .crossing:
            if index.isMultiple(of: 2) { board.onGoToCanvas() }
            else { board.onGoToWorkspace(workspaceName) }
        case .picking:
            board.togglePicking()
        case .peek:
            if !board.isPicking { board.beginPicking() }
            else if board.peeking == nil { board.tiling?.cards.first.map(board.beginPeek) }
            else { board.endPeek() }
        case .maximize:
            board.tiling?.ids.first.map { board.toggleMaximizeTile($0) }
        case .windows:
            windowStep(on: board, at: index)
        }
    }

    // MARK: Windows

    /// One step of the window journey, in a cycle of six: sweep, full screen in, out, sweep, to the
    /// other display, back. On one display the move steps sweep instead.
    ///
    /// **A sweep is a resize driven frame by frame**, 30 frames in and 30 back out to where it began,
    /// each one a `setFrame(_:display:)` — what a drag on the window's corner delivers, down to the
    /// clip view's frame change and the re-tile it sets off (`CanvasScrollView.clipResized`). It is not
    /// AppKit's live resize (`inLiveResize` stays false), so anything that only engages during a live
    /// resize is not measured by it.
    private static func windowStep(on board: CanvasBoardView, at index: Int) {
        guard let window = board.window else { return }
        let tiles = board.tiling?.ids.count ?? 0
        let webTiles = board.tiling?.ids.filter { board.nodeViews[$0] is CanvasLinkNodeView }.count ?? 0
        let label = { (kind: String) in "window \(kind) (\(tiles) tiles, \(webTiles) web)" }
        let other = window.screen.flatMap { here in NSScreen.screens.first { $0 != here } }
        let step = index % 6
        if step == 1 || step == 2 {
            FrameMeter.measure(label(step == 1 ? "full screen in" : "full screen out"), on: board, for: 1.6)
            window.toggleFullScreen(nil)
            return
        }
        // Everything else needs a window that isn't full screen; a step that finds one waits it out.
        guard !window.styleMask.contains(.fullScreen) else { return }
        if (step == 4 || step == 5), let there = other {
            FrameMeter.measure(label("to other display"), on: board, for: 1.2)
            var frame = window.frame
            frame.size.width = min(frame.width, there.visibleFrame.width - 80)
            frame.size.height = min(frame.height, there.visibleFrame.height - 80)
            frame.origin = NSPoint(x: there.visibleFrame.midX - frame.width / 2,
                                   y: there.visibleFrame.midY - frame.height / 2)
            window.setFrame(frame, display: true)
            return
        }
        // The whole sweep is the movement: sixty `setFrame`s over a second, plus a frame of slack.
        FrameMeter.measure(label(sidebarOff ? "resize sweep, no sidebar" : "resize sweep"),
                           on: board, for: 1.4, movement: 1.05)
        sweep(window)
    }

    /// Shrink the window by a quarter of its width and height over half a second, then grow it back.
    private static func sweep(_ window: NSWindow) {
        let start = window.frame
        let frames = 30
        var tick = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                tick += 1
                guard tick <= frames * 2 else { return timer.invalidate() }
                let t = Double(tick <= frames ? tick : frames * 2 - tick) / Double(frames)
                var frame = start
                frame.size.width = start.width * (1 - 0.25 * t)
                frame.size.height = start.height * (1 - 0.25 * t)
                frame.origin.y = start.maxY - frame.height
                window.setFrame(frame, display: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The workspace the run bounces through, saved under our own name so the same cards resume the
    /// same workspace across runs and builds. Nil when the board cannot supply one.
    ///
    /// **Saved as columns, the way the app writes one.** This used to save `ids` and an arrangement and
    /// nothing else — the shape from before §7k — so every benched crossing came back through the
    /// legacy conversion in `CanvasTileSession.init(restoring:)`, which runs the arrangement into
    /// columns against the window. That is a path a workspace saved today never takes, and it is extra
    /// work besides, so the bench was measuring a journey the app does not make.
    private static func prepare(board: CanvasBoardView, tiles: Int,
                                webFirst: Bool = false) -> CanvasViewState.Tiling? {
        var nodes = board.document.nodes.filter { !$0.isGroup }
        if webFirst {
            let web = nodes.filter { CanvasNodeView.kind(of: $0) == CanvasLinkNodeView.self }
            nodes = web + nodes.filter { CanvasNodeView.kind(of: $0) != CanvasLinkNodeView.self }
        }
        let cards = nodes.prefix(tiles).map(\.id)
        guard cards.count >= 2 else {
            Log.write("BENCH declined: \(cards.count) cards on the board")
            return nil
        }
        let columns = CanvasTiling.columns(.grid, of: cards.map { CanvasTiling.Tile($0) },
                                           in: board.tileableRect(atZoom: 1),
                                           masterFraction: CanvasTiling.savedMasterFraction)
        // The old fields go on being written for the reason `CanvasTileSession.memory` writes them: a
        // build from before columns can still open what this saved.
        let plan = CanvasViewState.Tiling(ids: Array(cards), arrangement: .grid,
                                          masterFraction: CanvasTiling.savedMasterFraction,
                                          sizes: nil, columns: columns)
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
        // Saved under our own name *before* the window is asked to make the workspace, so that
        // `ProjectSplitViewController.tileAsWorkspace` finds one with this exact card set already
        // there and opens a tab on it rather than minting `Workspace 2`. See its note on why the
        // same cards resume the same workspace, and `prepare` for why it is saved as columns.
        guard let plan = prepare(board: board, tiles: tiles) else { return finished?() ?? () }
        // Opens its tab, which is what the alternation below needs: with no tab on the workspace,
        // `goToWorkspace(named:)` lays the tiles into the pane it is already in and nothing crosses.
        guard board.onTileAsWorkspace(plan) else {
            return Log.write("BENCH declined: this window will not keep a workspace")
        }
        Log.write("BENCH \(iterations) crossings of \(plan.ids.count) tiles, \(interval)s apart")
        step(0, of: iterations, then: finished)
    }

    /// What a run repeats.
    ///
    /// **The crossing is no longer the only journey that lays every tile out again.** §7k added three
    /// more, each of which moves every tile on screen and so costs what a crossing costs: the board as
    /// the picker (⌥B), a peek's zoom onto one card, and maximizing a tile. Each is measured where it
    /// happens — see `CanvasBoardView.beginPicking`, `beginPeek` and `toggleMaximizeTile` — and this is
    /// what drives them enough times for the numbers to mean something.
    enum Journey: String {
        case crossing, picking, peek, maximize
        /// Window management over a tiled workspace: resize sweeps, full screen in and out, and a
        /// move to the other display and back where there is one. What web tiles are felt in.
        case windows
    }

    /// Repeat one of the workspace's own journeys, rather than crossing in and out of the canvas.
    ///
    /// `sidebarOff` folds the window's sidebar away for the run and brings it back after — the other
    /// half of an A/B for what the sidebar costs a resize, which spans alone could not settle: the
    /// hosting controller's layout is entered from the window's own pass, with no frame of ours on
    /// the stack (windows-5 trace, 2026-11-27).
    static func runJourney(_ journey: Journey, iterations: Int, tiles: Int, sidebarOff: Bool = false) {
        guard FrameMeter.isEnabled else { return declineWithoutTheMeter() }
        guard !screenIsLocked else { return Log.write("BENCH declined: the screen is locked") }
        guard let board = frontBoard() else { return Log.write("BENCH declined: no board in front") }
        guard !isHidden(board) else {
            return Log.write("BENCH declined: the window is not on screen — bring it to the front")
        }
        // The window journey is about web tiles, so it takes the board's web cards first.
        guard let plan = prepare(board: board, tiles: tiles, webFirst: journey == .windows) else { return }
        guard board.onTileAsWorkspace(plan) else {
            return Log.write("BENCH declined: this window will not keep a workspace")
        }
        Log.write("BENCH \(iterations) \(journey.rawValue) journeys of \(plan.ids.count) tiles, "
            + "\(interval)s apart\(sidebarOff ? ", sidebar folded" : "")")
        let split = board.window.flatMap { splitController(in: $0.contentViewController) }
        let wasCollapsed = split?.isSidebarCollapsed ?? true
        Self.sidebarOff = sidebarOff
        if sidebarOff { split?.setSidebarCollapsedForBench(true) }
        walk(0, of: iterations, journey) {
            Self.sidebarOff = false
            if sidebarOff { split?.setSidebarCollapsedForBench(wasCollapsed) }
        }
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
    /// second half of the run with it.
    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The board showing the workspace — **not simply the first one in the front window.**
    ///
    /// A window holds more than one board at a time: the canvas pane and a workspace pane both stay
    /// alive, and `frontBoard` returns whichever comes first in the view tree. The crossing journey can
    /// live with that because a crossing *is* a pane swap and it wants whatever is in front now. The
    /// journeys §7k added act on the tiled board in place, and picking one at random gave a run whose
    /// three measurements reported 8 views, then 0, then 1 — three different boards, none of them
    /// measured twice.
    private static func tiledBoard() -> CanvasBoardView? {
        let windows = ([WindowManager.shared.frontmost?.window].compactMap { $0 } + NSApp.windows)
        for window in windows {
            // On screen, too: a window keeps every tab's pane mounted, and a tiled board in a hidden
            // pane has a display link that never ticks — 24 of 24 measurements abandoned at 0 frames
            // (2026-11-27) on a "2 tiles" board nobody could see while the bench's own sat in front.
            let boards = window.contentView.map(everyBoard) ?? []
            if let board = boards.first(where: { $0.isTiled && Self.isShowing($0) }) { return board }
        }
        return frontBoard()
    }

    /// Whether the run under way has folded the sidebar away, for the measurement's label.
    private static var sidebarOff = false

    /// The window's split view controller, wherever it sits under the window's content controller.
    private static func splitController(in controller: NSViewController?) -> ProjectSplitViewController? {
        guard let controller else { return nil }
        if let split = controller as? ProjectSplitViewController { return split }
        for child in controller.children {
            if let found = splitController(in: child) { return found }
        }
        return nil
    }

    /// Whether a board is in a pane that is actually up, rather than mounted and hidden.
    private static func isShowing(_ board: CanvasBoardView) -> Bool {
        !board.isHiddenOrHasHiddenAncestor && !board.visibleRect.isEmpty
    }

    private static func everyBoard(_ view: NSView) -> [CanvasBoardView] {
        if let board = view as? CanvasBoardView { return [board] }
        return view.subviews.flatMap(everyBoard)
    }

    /// Whether this board's window is actually being presented — **the other condition that makes a run
    /// silently worthless.**
    ///
    /// `CADisplayLink` does not tick for a window nobody can see, so every measurement is abandoned
    /// after 0 frames, which reads in the log like a bench firing too fast rather than like a window
    /// behind another app. That is the same failure the screen lock produces and it deserves the same
    /// treatment: say so and decline, rather than write down numbers that describe nothing.
    private static func isHidden(_ board: CanvasBoardView) -> Bool {
        guard let window = board.window else { return true }
        return window.isMiniaturized || !window.occlusionState.contains(.visible)
    }

    /// The board in the front window, wherever it is in its view tree.
    ///
    /// Searched for rather than reached through the window controller, which would mean opening up
    /// `ProjectWindowController.split` and `CanvasPaneController.scroll` — two private properties made
    /// internal for the benefit of a bench. A dev-only tool should not be why a boundary moves.
    private static func frontBoard() -> CanvasBoardView? {
        let window = WindowManager.shared.frontmost?.window ?? NSApp.mainWindow ?? NSApp.keyWindow
        // The one on screen first, for the reason `tiledBoard` gives — the crossing bench measured
        // nothing at all the same day, which this is the likeliest cause of.
        let boards = window?.contentView.map(everyBoard) ?? []
        return boards.first(where: isShowing) ?? boards.first
    }
}
