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

    /// How often it asks while paused. A resumption is stamped at the latest input a check sees, so
    /// this decides how early in a return the new span begins — and a short return (a prompt typed
    /// to an agent) has to read as a return rather than a touch (`AttentionLog.awayBlip`). Nobody is
    /// typing while this runs, so it costs a timer and nothing else.
    private static let pausedTick: TimeInterval = 5

    /// The project a `began` is on record for, or nil when nothing is.
    private var open: (key: String, project: String)?
    /// Whether that span has already been ended by a pause. A paused span is still `open` — coming
    /// back to the same project resumes it — but it must not be ended twice.
    private var paused = false
    /// When the paused span ended — its back-dated last input. A resumption needs input after it.
    private var pausedAt: Date?
    private var timer: Timer?
    /// When an app on the not-work list came to the front, while one still is.
    private var elsewhereSince: Date?
    /// Whether the log already says so for this stretch in the app — as the pause itself, or as a
    /// marker inside a pause that was already going.
    private var markedElsewhere = false

    /// Apps that mean you've stopped working, by bundle identifier (docs/away-time.md). This Mac's
    /// habit rather than a fact about any project, so `UserDefaults`, like `showsDurationsKey`.
    static let notWorkAppsKey = "PMNotWorkApps"

    static var notWorkApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: notWorkAppsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: notWorkAppsKey) }
    }

    /// How long a not-work app has to stay in front before it ends the span. A glance — checking a
    /// message, closing a window — is shorter, and splitting a span for it would put a gap in the
    /// day for nothing; the glance counts as the work it interrupted.
    private static let elsewhereGrace: TimeInterval = 60

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

    // MARK: What it reads — replaceable, so the rules can run on a test's clock

    /// Now. `Date()` in the app.
    var clock: () -> Date = { Date() }
    /// Seconds since anyone touched the machine. The HID idle timer in the app.
    var idle: () -> TimeInterval = { AttentionKeeper.systemIdleSeconds() }
    /// The not-work list, as `notWorkApps` has it.
    var notWork: () -> [String] = { AttentionKeeper.notWorkApps }
    /// The focused task's text, as colour on a span (D1). Set by the app, which has the store; nil is
    /// fine and costs nothing.
    var focusedTask: () -> String? = { nil }
    /// Whether it runs its own timer. Off in tests, which call `check()` themselves.
    var schedulesTimers = true

    init() {}

    // MARK: Being told things

    /// Start watching. Called once, from `applicationDidFinishLaunching`.
    func start() {
        schedule(every: Self.tick)

        // Leaving the machine, as against not touching it (docs/away-time.md). The display sleeping on
        // its own timer is deliberately *not* here: reading an agent's output with a dark screen a
        // tap away is still being at the computer, and the idle check covers it either way.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                              queue: .main) { _ in
            Task { @MainActor in self.leave(why: "slept") }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                              queue: .main) { _ in
            Task { @MainActor in self.leave(why: "locked") }
        }
        // The screen lock isn't a workspace notification. Waking is deliberately not observed: the
        // next check sees input and resumes on its own, and an unlock with nobody typing afterwards
        // isn't work.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.leave(why: "locked") }
        }

        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                              queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            Task { @MainActor in self.frontmostChanged(to: bundle) }
        }
        frontmostChanged(to: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Whether the app in front is one you've said isn't work. Only the answer is kept — never which
    /// app it was, here or in the log.
    func frontmostChanged(to bundle: String?) {
        if let bundle, notWork().contains(bundle) {
            // One not-work app to another is the same stretch, so the first one's moment stands.
            if elsewhereSince == nil { elsewhereSince = clock() }
        } else {
            elsewhereSince = nil
            markedElsewhere = false
        }
    }

    private func schedule(every interval: TimeInterval) {
        guard schedulesTimers, timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.check() }
        }
        // Generous tolerance: nothing here is time-critical, and a timer that lets the system coalesce
        // it is a timer that doesn't wake the CPU on its own account.
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// `focused.json` now names `key` — the one chokepoint the app learns that through
    /// (`AppDelegate.syncFocusedStore`), whoever moved it.
    func focusMoved(to key: String?) {
        guard key != open?.key else { return }
        let now = clock()
        // End the outgoing span at the last input rather than at this moment: switching projects after
        // twenty minutes away is twenty minutes that weren't spent on either of them.
        end(why: "switched", at: lastAlive(now))
        guard let key, let project = PMFiles.projectName(fromKey: key) else { return }
        open = (key, project)
        paused = false
        pausedAt = nil
        schedule(every: Self.tick)
        // Focusing a project from inside a not-work app starts its time there, not before: the
        // pause that follows mustn't be back-dated past this span's own `began`.
        if elsewhereSince != nil {
            elsewhereSince = now
            markedElsewhere = false
        }
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
    func check() {
        guard let span = open else { return }
        let now = clock()
        if let since = elsewhereSince {
            // In an app that isn't work. Never a resumption, whatever the input says: typing in a news
            // reader is still reading the news.
            guard !markedElsewhere, now.timeIntervalSince(since) >= Self.elsewhereGrace else { return }
            if paused {
                // Already quiet when the app came up. Say so inside the gap, so it reads as neither
                // quiet focus nor an away to ask about.
                AttentionLog.ended(project: span.project, key: span.key, why: "elsewhere", source: "app",
                                   at: since)
            } else {
                // Ended at the moment the app came to the front, which the notification gave exactly.
                pause(why: "elsewhere", at: since)
            }
            markedElsewhere = true
            return
        }
        let idle = self.idle()
        if idle > AttentionLog.attentionPause {
            pause(why: "paused", at: now.addingTimeInterval(-idle))
        } else if paused, let open, let pausedAt, now.addingTimeInterval(-idle) > pausedAt {
            // Input *since* the pause, not merely a recent last input: a span ended by a lock seconds
            // after the last keystroke still has that keystroke under ten minutes old, and resuming on
            // it wrote a return nobody made — the log's 0-minute sleep/resume pairs.
            // Back at it. A fresh span rather than an extension of the last one, so the gap is simply
            // absent from the day's total instead of being counted as work (D3).
            //
            // It starts at the last input we can prove, which loses up to one tick of a resumption
            // that's been going a while. That's the right direction to be wrong in: this feature
            // never claims time it can't show its working for.
            paused = false
            self.pausedAt = nil
            schedule(every: Self.tick)
            AttentionLog.began(project: open.project, key: open.key, task: focusedTaskText(),
                               why: "resumed", source: "app", at: now.addingTimeInterval(-idle))
        }
    }

    private func pause(why: String, at when: Date? = nil) {
        guard !paused, open != nil else { return }
        let when = when ?? lastAlive()
        end(why: why, at: when, keepingOpen: true)
        paused = true
        pausedAt = when
        schedule(every: Self.pausedTick)
    }

    /// A lock, a lid or a sleep. Ends the span like a pause; if a pause already has, it's still
    /// written, as a marker inside the gap — quiet with a lock in it isn't quiet (docs/away-time.md),
    /// and the ten-minute pause is usually on record before the lock that explains it.
    func leave(why: String) {
        guard let span = open else { return }
        if paused {
            AttentionLog.ended(project: span.project, key: span.key, why: why, source: "app", at: clock())
        } else {
            pause(why: why)
        }
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
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        // `~0` is `kCGAnyInputEventType`: the keyboard, the mouse and the trackpad together, rather
        // than one of them.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    private func lastAlive(_ now: Date? = nil) -> Date {
        (now ?? clock()).addingTimeInterval(-idle())
    }

    private func focusedTaskText() -> String? { focusedTask() }

    /// Whether the log's last line is already a `began` for this project, written just now — which
    /// means the focus came through `project.focus` and the dispatcher has recorded it.
    private func alreadyBegan(key: String, within seconds: TimeInterval, of now: Date) -> Bool {
        guard let last = AttentionLog.lastEvent(), last.event == .began, last.key == key,
              let at = DoneLog.date(last.at) else { return false }
        return abs(now.timeIntervalSince(at)) <= seconds
    }
}
