import AppKit

/// Notices the main thread stuck and keeps a `sample` of it — so a freeze on another Mac comes back
/// with its cause instead of a description.
///
/// - A background thread asks main to answer every quarter second. Unanswered for `threshold`, it runs
///   `/usr/bin/sample` on Folio for `sampleSeconds` while the freeze is still on, into
///   `~/.config/pm/hangs/`. One sample per freeze; the newest `kept` are kept.
/// - Uptime, not wall time: a Mac asleep is not a frozen app.
/// - On in every build. It writes nothing until something freezes; `PMHangWatchdogOff` turns it off.
/// - The reports made 2026-11-05 by hand (`sample`, Activity Monitor) are what this automates.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    init() {}

    static var folder: URL { PMFiles.configDir.appendingPathComponent("hangs", isDirectory: true) }
    /// Where this one writes. A test points it somewhere of its own.
    var folder = HangWatchdog.folder
    var threshold: TimeInterval = 3
    var sampleSeconds = 3
    var kept = 10

    /// How a sample is taken. A test stands in one that records instead.
    var sampler: (_ seconds: Int, _ file: URL) -> Void = { seconds, file in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds), "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private let lock = NSLock()
    /// Uptime at main's last answer, in nanoseconds.
    private var answered = DispatchTime.now().uptimeNanoseconds
    private var asked = false
    /// Whether this freeze has been sampled — reset when main answers.
    private var sampled = false
    private var stalledSince: UInt64?
    private var thread: Thread?

    func start() {
        guard thread == nil, !UserDefaults.standard.bool(forKey: "PMHangWatchdogOff") else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Folio.hang-watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            tick(now: DispatchTime.now().uptimeNanoseconds)
        }
    }

    /// One look: ask main to answer if it isn't being asked, and sample if it hasn't for too long.
    /// Internal for tests, which drive the clock themselves.
    func tick(now: UInt64) {
        lock.lock()
        if !asked {
            asked = true
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.answer() }
            return
        }
        let waited = TimeInterval(now &- answered) / 1_000_000_000
        let take = waited >= threshold && !sampled
        if take { sampled = true; stalledSince = answered }
        lock.unlock()
        guard take else { return }
        record(waited: waited)
    }

    /// Main's answer. Internal for tests.
    func answer() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let since = stalledSince
        answered = now
        asked = false
        sampled = false
        stalledSince = nil
        lock.unlock()
        if let since {
            Log.write("main thread answered after \(String(format: "%.1f", TimeInterval(now &- since) / 1_000_000_000))s")
        }
    }

    private func record(waited: TimeInterval) {
        let folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("folio-hang-\(stamp).txt")
        Log.write("main thread unanswered for \(String(format: "%.1f", waited))s; sampling to \(file.lastPathComponent)")
        sampler(sampleSeconds, file)
        prune(folder)
    }

    private func prune(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("folio-hang-") } ?? []
        let newestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in newestFirst.dropFirst(kept) { try? FileManager.default.removeItem(at: file) }
    }
}
