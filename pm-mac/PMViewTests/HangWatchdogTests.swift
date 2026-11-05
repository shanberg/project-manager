import XCTest

/// `HangWatchdog` notices main stuck and keeps a sample of it. Driven with a real block of the main
/// thread and, once, the real `/usr/bin/sample` — the thing that has to work on a Mac far away.
@MainActor
final class HangWatchdogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hangs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func watchdog(threshold: TimeInterval) -> HangWatchdog {
        let dog = HangWatchdog()
        dog.folder = folder
        dog.threshold = threshold
        dog.sampleSeconds = 1
        return dog
    }

    /// Ticks from a background thread while main is blocked, the way the watchdog's own thread does.
    private func block(main seconds: TimeInterval, watchedBy dog: HangWatchdog) {
        let ticking = Thread {
            let end = Date().addingTimeInterval(seconds + 0.5)
            while Date() < end {
                dog.tick(now: DispatchTime.now().uptimeNanoseconds)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        ticking.start()
        Thread.sleep(forTimeInterval: seconds)   // main, blocked
    }

    func testAFreezePastTheThresholdIsSampledOnce() {
        let dog = watchdog(threshold: 0.3)
        var taken = 0
        let lock = NSLock()
        dog.sampler = { _, _ in lock.lock(); taken += 1; lock.unlock() }
        block(main: 1.2, watchedBy: dog)
        Thread.sleep(forTimeInterval: 0.6)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(taken, 1, "one sample per freeze")
    }

    func testAShortPauseIsNotAFreeze() {
        let dog = watchdog(threshold: 1)
        var taken = 0
        dog.sampler = { _, _ in taken += 1 }
        block(main: 0.3, watchedBy: dog)
        let drained = expectation(description: "main answered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(taken, 0)
    }

    /// The real tool, on this process, while main is stuck: the report names the frame main is in.
    func testTheRealSampleNamesWhereMainIsStuck() throws {
        let dog = watchdog(threshold: 0.3)
        let done = DispatchSemaphore(value: 0)
        let real = dog.sampler
        dog.sampler = { seconds, file in real(seconds, file); done.signal() }
        block(main: 2, watchedBy: dog)
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "sample never finished")

        let reports = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let report = try String(contentsOf: try XCTUnwrap(reports.first), encoding: .utf8)
        XCTAssert(report.contains("Call graph"), "not a sample report")
        XCTAssert(report.contains("block(main:watchedBy:)") || report.contains("HangWatchdogTests"),
                  "the report doesn't show the frame main was stuck in")
    }

    func testOnlyTheNewestAreKept() throws {
        let dog = watchdog(threshold: 0.2)
        dog.kept = 2
        dog.sampler = { _, file in try? Data("x".utf8).write(to: file) }
        for _ in 0..<4 {
            block(main: 0.5, watchedBy: dog)
            let answered = expectation(description: "answered")
            DispatchQueue.main.async { answered.fulfill() }
            wait(for: [answered], timeout: 2)
            Thread.sleep(forTimeInterval: 1.1)   // a new second, a new file name
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }
}
