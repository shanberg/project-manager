import AppKit
import PmLib

/// Folio's half of the attention log (docs/time-tracking.md D3, D4): the thing that watches the
/// machine and writes the edges of a span.
///
/// **Why it has to be the app.** `project.focus` appends a `began` from whichever surface called it,
/// so the log knows where attention *went* without Folio running at all. What no headless call can
/// know is when it stopped — you don't tell PM you've gone to lunch. Only something long-lived,
/// watching the machine, can see that, so only the app ever writes an `ended` with a real clock
/// behind it. Without it every span is inferred and capped at an hour; with it they're measured.
///
/// **It watches the machine, not the app.** `CGEventSource.secondsSinceLastEventType` is time since
/// any input anywhere — Obsidian, a browser, a terminal, another Space. PM's claim is about the
/// project you're working on rather than about whether its own window is frontmost, so a morning in
/// Obsidian counts in full and Folio being ignored for an hour costs nothing. (This API reads the
/// HID idle timer; unlike an event tap it needs no accessibility grant.)
///
/// **Every edge is back-dated.** An `ended` is stamped at the last input, never at the moment the
/// pause was noticed, so how often this polls decides when the record is *written* and never what it
/// says. That's what lets the tick be slow and the answer still be exact.
@MainActor
final class AttentionKeeper {
    static let shared = AttentionKeeper()

    /// How often the machine is asked whether anyone is still there. Slow on purpose: every edge is
    /// back-dated, so the only thing this costs is how stale the log is allowed to be, and the report
    /// closes an unwritten span itself.
    private static let tick: TimeInterval = 60

    /// The project a `began` is on record for, or nil when nothing is.
    private var open: (key: String, project: String)?
    /// Whether that span has already been ended by a pause. A paused span is still `open` — coming
    /// back to the same project resumes it — but it must not be ended twice.
    private var paused = false
    private var timer: Timer?

    /// Whether a sitting says how long it ran (docs/time-tracking.md D6).
    ///
    /// **Off by default, and the default is the point.** Folio refuses a column of durations beside
    /// every sitting — it reads as a timesheet, and nobody asked for one. This is for the weeks when
    /// you need to know, and it stays out of the way the rest of the time. In `UserDefaults` rather
    /// than pm config: the file is the same either way, so it's a fact about this Mac's reading of it.
    static let showsDurationsKey = "PMShowsSittingDuration"

    static var showsDurations: Bool {
        UserDefaults.standard.bool(forKey: showsDurationsKey)
    }

    private init() {}

    // MARK: Being told things

    /// Start watching. Called once, from `applicationDidFinishLaunching`.
    func start() {
        let timer = Timer(timeInterval: Self.tick, repeats: true) { _ in
            Task { @MainActor in self.check() }
        }
        // Generous tolerance: nothing here is time-critical, and a timer that lets the system coalesce
        // it is a timer that doesn't wake the CPU on its own account.
        timer.tolerance = Self.tick / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.pause(why: "slept") }
            }
        }
        // The screen lock isn't a workspace notification. Waking is deliberately not observed: the
        // next tick sees input and resumes on its own, and an unlock with nobody typing afterwards
        // isn't work.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.pause(why: "slept") }
        }
    }

    /// `focused.json` now names `key` — the one chokepoint the app learns that through
    /// (`AppDelegate.syncFocusedStore`), whoever moved it.
    func focusMoved(to key: String?) {
        guard key != open?.key else { return }
        let now = Date()
        // End the outgoing span at the last input rather than at this moment: switching projects after
        // twenty minutes away is twenty minutes that weren't spent on either of them.
        end(why: "switched", at: lastAlive(now))
        guard let key, let project = PMFiles.projectName(fromKey: key) else { return }
        open = (key, project)
        paused = false
        // `project.focus` writes its own `began` when the focus came through the contract. Two in a
        // row would be a stray span of a few seconds against this project — small, and wrong for no
        // reason.
        guard !alreadyBegan(key: key, within: 10, of: now) else { return }
        AttentionLog.began(project: project, key: key, task: focusedTaskText(), source: "app", at: now)
    }

    /// Quitting. The last chance to write an edge, so the span doesn't have to be inferred.
    func stop() {
        timer?.invalidate()
        timer = nil
        end(why: "quit", at: lastAlive())
    }

    // MARK: Watching

    /// Has anybody touched this machine lately, and does the open span still stand?
    private func check() {
        guard open != nil else { return }
        let now = Date()
        let idle = idleSeconds()
        if idle > AttentionLog.attentionPause {
            pause(why: "paused", at: now.addingTimeInterval(-idle))
        } else if paused, let open {
            // Back at it. A fresh span rather than an extension of the last one, so the gap is simply
            // absent from the day's total instead of being counted as work (D3).
            //
            // It starts at the last input we can prove, which loses up to one tick of a resumption
            // that's been going a while. That's the right direction to be wrong in: this feature
            // never claims time it can't show its working for.
            paused = false
            AttentionLog.began(project: open.project, key: open.key, task: focusedTaskText(),
                               why: "resumed", source: "app", at: now.addingTimeInterval(-idle))
        }
    }

    private func pause(why: String, at when: Date? = nil) {
        guard !paused, open != nil else { return }
        end(why: why, at: when ?? lastAlive(), keepingOpen: true)
        paused = true
    }

    /// Write the `ended` for the open span. `keepingOpen` is a pause, which can still be resumed;
    /// otherwise attention has actually left.
    private func end(why: String, at when: Date, keepingOpen: Bool = false) {
        guard let span = open else { return }
        // Already ended by a pause: the span on record is closed, and closing it again would put an
        // edge in the log at a moment nothing happened.
        if !paused {
            AttentionLog.ended(project: span.project, key: span.key, why: why, source: "app", at: when)
        }
        if !keepingOpen {
            open = nil
            paused = false
        }
    }

    /// Seconds since anyone last touched the machine — any input, in any app.
    private func idleSeconds() -> TimeInterval {
        // `~0` is `kCGAnyInputEventType`: the keyboard, the mouse and the trackpad together, rather
        // than one of them.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    private func lastAlive(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(-idleSeconds())
    }

    /// The focused task, as colour on the span (D1). Read from the store the app already has rather
    /// than off disk; nil is fine and costs nothing.
    private func focusedTaskText() -> String? {
        (NSApp.delegate as? AppDelegate)?.store.focusedTodo?.text
    }

    /// Whether the log's last line is already a `began` for this project, written just now — which
    /// means the focus came through `project.focus` and the dispatcher has recorded it.
    private func alreadyBegan(key: String, within seconds: TimeInterval, of now: Date) -> Bool {
        guard let last = AttentionLog.lastEvent(), last.event == .began, last.key == key,
              let at = DoneLog.date(last.at) else { return false }
        return abs(now.timeIntervalSince(at)) <= seconds
    }
}
