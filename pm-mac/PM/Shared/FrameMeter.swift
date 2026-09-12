import AppKit
import QuartzCore

/// What the window actually managed to put on screen while something was moving.
///
/// **Measured from the display, not from our own clock.** Every animation in the app knows how long it
/// meant to take, and none of them know how many frames they cost — a crossing that asks for a third
/// of a second gets a third of a second whether it drew twenty frames or four. The difference between
/// those two is the entire question, and nothing inside the animation can see it: the code that sets
/// `presence` sixty times a second is being *called* sixty times a second either way.
///
/// So this counts vsyncs. A `CADisplayLink` fires once per refresh and coalesces when the main thread
/// misses one — so the gap between two consecutive callbacks, divided by the refresh interval, is the
/// number of frames the display went without new work. That is a hitch, in the only unit that matters,
/// and it needs no profiler attached.
///
/// **Off unless asked for.** Three ways in, matching `Log`: `PM_FRAME_METER=1` for a run started from a
/// terminal, `defaults write com.stuarthanberg.pm PMFrameMeterEnabled -bool YES` for an installed copy,
/// and neither by default — including in a debug build, because a meter that runs on every crossing
/// while you are working on something else is a log you learn to ignore.
///
/// Reports through `Log`, so `tail -f ~/.config/pm/pm-mac.log` while you press the key.
@MainActor
final class FrameMeter {

    /// Whether anything is measured at all. Read once — see `Log.isEnabled`, which reasons the same way.
    static let isEnabled: Bool = {
        if let flag = ProcessInfo.processInfo.environment["PM_FRAME_METER"] {
            return !["0", "false", "no", ""].contains(flag.lowercased())
        }
        return UserDefaults.standard.bool(forKey: "PMFrameMeterEnabled")
    }()

    /// Watch the next `seconds` of frames on `view`'s display, and write down what happened.
    ///
    /// **One at a time, and the newest wins.** Press ⌘Return twice in a second and the first
    /// measurement is spanning two crossings and a settle, which is a number that describes nothing.
    /// So a second request abandons the first outright rather than reporting a truncated one — the
    /// crossing you are watching is the last one you asked for.
    ///
    /// `label` is `@autoclosure` for the reason `Log.write`'s message is: the callers build it out of
    /// card counts they would otherwise have to go and count.
    ///
    /// The default window is long enough to cover more than the movement. A crossing is 0.3s, and
    /// `CanvasBoardView.settlePageBudget` lands 0.75s after it with a pass that can start and stop web
    /// renderers — which is part of what a crossing costs, arrives while you are still looking at it,
    /// and would be invisible to a meter that stopped when the cards did.
    static func measure(_ label: @autoclosure () -> String, on view: NSView, for seconds: Double = 1.2) {
        guard isEnabled else { return }
        let name = label()
        if let running = current {
            // The frame count is the diagnostic. A measurement abandoned with a sensible number of
            // frames behind it was simply interrupted; one abandoned with two or three was never
            // ticking, and the usual reason is that nothing was being presented at all — a locked
            // screen, a sleeping display, a fully occluded window. Without the count those two look
            // identical in the log and the second reads as a bench that is too eager.
            Log.write("FRAME \(running.label): abandoned after \(running.ticks.count) frames, "
                + "\(name) started")
            running.stop()
        }
        guard let window = view.window, window.screen != nil else {
            return Log.write("FRAME \(name): not measured, no screen")
        }
        let meter = FrameMeter(label: name, seconds: seconds)
        current = meter
        meter.start(on: view)
    }

    /// Time a named piece of main-thread work, and charge it to the crossing that is being measured.
    ///
    /// **Frames say how bad it is; spans say what did it.** A crossing that delivers three frames of
    /// twenty has spent its time somewhere specific, and no amount of frame counting will say where —
    /// the display link only reports the silence, not what filled it.
    ///
    /// Only work that *starts* inside the movement is counted, for the reason the phase boundary uses
    /// the same rule: a pass that begins during the animation is the animation's cost however long it
    /// runs on for.
    ///
    /// Free when nothing is being measured — one static read and a branch — so these can sit on paths
    /// that run for every card on every frame.
    static func span<T>(_ name: String, _ body: () -> T) -> T {
        guard let meter = current else { return body() }
        let start = CACurrentMediaTime()
        let value = body()
        meter.record(name, at: start, CACurrentMediaTime() - start)
        return value
    }

    private func record(_ name: String, at: CFTimeInterval, _ duration: CFTimeInterval) {
        guard at - startedAt <= Self.movement else { return }
        let existing = spans[name] ?? (0, 0)
        spans[name] = (existing.total + duration, existing.count + 1)
    }

    /// The worst of the named work, as a line fragment. Anything under a millisecond in total is left
    /// out: it is a list of suspects, not an accounting.
    private func spanReport() -> String {
        let worst = spans.filter { $0.value.total > 0.001 }
            .sorted { $0.value.total > $1.value.total }.prefix(6)
        guard !worst.isEmpty else { return "spans —" }
        return "spans " + worst.map {
            String(format: "%@ %.0fms×%d", $0.key, $0.value.total * 1000, $0.value.count)
        }.joined(separator: ", ")
    }

    /// The measurement under way, if one is. Static because the thing being measured is the window, and
    /// two meters on one window would each be counting the other's cost.
    private static var current: FrameMeter?

    private let label: String
    private let seconds: Double
    /// When the measurement began, as a time base for spans. Not the first tick: the most interesting
    /// work happens before the display has managed to show anything at all.
    private let startedAt: CFTimeInterval = CACurrentMediaTime()
    /// Named main-thread work, and what it cost inside the movement — see `span(_:_:)`.
    private var spans: [String: (total: CFTimeInterval, count: Int)] = [:]
    private var link: CADisplayLink?
    /// When each callback ran, and what the display said its refresh interval was at the time.
    fileprivate var ticks: [(at: CFTimeInterval, interval: CFTimeInterval)] = []

    private init(label: String, seconds: Double) {
        self.label = label
        self.seconds = seconds
        ticks.reserveCapacity(Int(seconds * 130) + 8)
    }

    private func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick))
        // `.common`, not `.default`: a crossing can begin inside a mouse-tracking loop — ⌘Return with
        // a drag still held, a workspace opened from a menu that is still up — and a meter that stops
        // counting exactly when the main thread is busiest would report the frames it did not miss.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let interval = link.duration > 0 ? link.duration
            : max(link.targetTimestamp - link.timestamp, 1.0 / 60)
        ticks.append((at: link.timestamp, interval: interval))
        guard let first = ticks.first, link.timestamp - first.at >= seconds else { return }
        report()
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        if FrameMeter.current === self { FrameMeter.current = nil }
    }

    /// **Two windows, not one.** The movement is 0.3s and this watches for 1.2s, so three quarters of
    /// every sample used to be the board settling rather than the board crossing — and the two are
    /// different questions with different answers. A stall inside the animation is what you see; a
    /// stall afterwards, while `applyPageBudget` starts and stops renderers, is a hitch you have
    /// already looked away from.
    ///
    /// Pooling them cost the run that mattered: dropped frames diluted three-to-one by a phase nobody
    /// was optimising came out indistinguishable across every configuration, while the worst frame —
    /// a maximum, which survives dilution — showed the difference plainly. Splitting the window is
    /// what lets the first number say what the second one had to be inferred from.
    private func report() {
        // Two ticks is one gap, and one gap is not a measurement.
        guard ticks.count > 2 else {
            return Log.write("FRAME \(label): not measured, \(ticks.count) frames")
        }
        // The refresh interval as the display reported it, taken as the median rather than the first:
        // a variable-refresh display quotes whatever it is doing at the moment it is asked, and the
        // moment this starts is the one where the main thread is about to be busy.
        let nominal = median(ticks.map(\.interval))
        let start = ticks[0].at
        // **Each gap belongs to the phase it *starts* in**, and getting this backwards silently threw
        // away the worst measurements. Assigned by where a gap *ends*, a 400ms stall beginning the
        // instant the crossing does finishes after the movement is over and is charged to the settle —
        // so the crossing phase comes back empty, the line reads `crossing —`, and the crossings that
        // were too bad to get a single frame out are the ones missing from the crossing column. That
        // is a filter that removes exactly the evidence you are looking for, and it flattered whichever
        // configuration stalled hardest.
        let gaps = zip(ticks, ticks.dropFirst()).map { (at: $0.at - start, span: $1.at - $0.at) }
        let crossing = gaps.filter { $0.at <= Self.movement }
        let settle = gaps.filter { $0.at > Self.movement }
        Log.write("FRAME \(label): \(phase("crossing", crossing, nominal)) | "
            + "\(phase("settle", settle, nominal)) | \(String(format: "%.0fHz", 1 / nominal))")
        Log.write("SPAN  \(label): \(spanReport())")
    }

    /// How long the movement itself lasts. `Motion.duration(0.3)` at both ends of a crossing — see
    /// `CanvasBoardView.settleIntoLayout` and `CanvasScrollView.fly` — plus a frame of slack, so a
    /// crossing that lands a little late is not scored against the phase after it.
    private static let movement: TimeInterval = 0.35

    /// One phase's worth of frames, as a line fragment.
    private func phase(_ name: String, _ gaps: [(at: CFTimeInterval, span: CFTimeInterval)],
                       _ nominal: CFTimeInterval) -> String {
        guard !gaps.isEmpty else { return "\(name) —" }
        // A gap of one interval is a frame delivered. Anything beyond that is frames the display spent
        // showing what it already had. Rounded, because no clock lands exactly on the interval.
        let missed = gaps.map { max(0, Int(($0.span / nominal).rounded()) - 1) }
        let dropped = missed.reduce(0, +)
        let span = gaps.map(\.span).reduce(0, +)
        return String(format: "%@ %.2fs %d of %d frames, %d dropped, worst %.0fms",
                      name, span, gaps.count + 1, gaps.count + 1 + dropped, dropped,
                      (gaps.map(\.span).max() ?? 0) * 1000)
    }

    private func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    /// Nearest-rank, which for the handful of frames a crossing lasts is the only honest kind: there is
    /// nothing to interpolate between when the sample is twenty long.
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[min(max(0, rank), sorted.count - 1)]
    }
}
