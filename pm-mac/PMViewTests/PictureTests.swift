import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Pictures are read and decoded off main, and views are handed pixels — see `Pictures.swift`.
///
/// The report this answers: 2026-11-05, another Mac, the main thread 8.7 s in the GIF decoder inside
/// Core Animation's commit, because a card handed `NSImageView` an `NSImage(data:)` and the decode ran
/// where it was first drawn.
@MainActor
final class PictureTests: XCTestCase {
    private var folder: URL!
    private var reader: (@Sendable (URL) -> Data?)!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reader = PictureStore.reader
    }

    override func tearDownWithError() throws {
        PictureStore.reader = reader
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// A GIF of `count` solid frames, `side` square, each shown for `delay`.
    private func gif(frames count: Int, side: Int, delay: Double = 0.05) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                         count, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: Double(index % 2), green: 0.5, blue: 1 - Double(index % 2), alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary:
                                           [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssert(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func waitForLanding(_ url: URL, maxSide: Int = PictureDecode.screenSide,
                                timeout: TimeInterval = 5) -> PictureLookup {
        let landed = expectation(description: "landed")
        var answer = PictureStore.shared.picture(at: url, maxSide: maxSide, owner: self) { landed.fulfill() }
        if case .loading = answer { wait(for: [landed], timeout: timeout) } else { landed.fulfill() }
        answer = PictureStore.shared.picture(at: url, maxSide: maxSide)
        return answer
    }

    // MARK: Decoding

    func testAnAnimatedGIFDecodesToEveryFrameWithItsDelays() throws {
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: 4, side: 64, delay: 0.2)))
        XCTAssertEqual(picture.frames.count, 4)
        XCTAssertEqual(picture.delays.count, 4)
        XCTAssertEqual(picture.duration, 0.8, accuracy: 0.01)
        XCTAssert(picture.isAnimated)
        XCTAssertEqual(picture.size, NSSize(width: 64, height: 64))
    }

    /// The browsers' rule: a GIF that asks for 0 ms means 100 ms, or it plays as a blur.
    func testANoDelayGIFPlaysAtATenthOfASecond() throws {
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: 2, side: 16, delay: 0)))
        XCTAssertEqual(picture.delays, [0.1, 0.1])
    }

    /// An animation whose frames would hold more than the budget is decoded smaller, not refused, and
    /// not decoded at full size.
    func testAHeavyAnimationIsDecodedInsideTheBudget() throws {
        let frames = 24, side = 1600   // 24 × 1600² × 4 ≈ 245 MB at full size
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: frames, side: side)))
        XCTAssertEqual(picture.frames.count, frames)
        // Plus row padding: a bitmap's rows are aligned to 64 bytes.
        let rows = try XCTUnwrap(picture.frames.first).height
        XCTAssertLessThanOrEqual(picture.cost, PictureDecode.animationBudget + frames * rows * 64)
        XCTAssertLessThan(try XCTUnwrap(picture.frames.first).width, side)
        XCTAssertEqual(picture.size, NSSize(width: side, height: side), "the drawn size is the file's, not the decode's")
    }

    func testAStillIsNeverDecodedPastTheSideAsked() throws {
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: 1, side: 900), maxSide: 300))
        XCTAssertEqual(try XCTUnwrap(picture.frames.first).width, 300)
        XCTAssertFalse(picture.isAnimated)
    }

    func testBytesThatArentAPictureAreNone() {
        XCTAssertNil(PictureDecode.picture(from: Data("not a picture".utf8)))
    }

    // MARK: The store

    /// The property that matters: a read or decode that never returns doesn't hold the main thread, and
    /// doesn't hold anyone else's picture either.
    func testAStuckReadLeavesMainAndOtherPicturesFree() throws {
        let stuck = try write(gif(frames: 2, side: 32), as: "stuck.gif")
        let fine = try write(gif(frames: 2, side: 32), as: "fine.gif")
        let release = DispatchSemaphore(value: 0)
        PictureStore.reader = { url in
            if url.lastPathComponent == "stuck.gif" { release.wait() }
            return try? Data(contentsOf: url)
        }
        defer { release.signal() }

        let start = Date()
        guard case .loading = PictureStore.shared.picture(at: stuck) else { return XCTFail("answered without reading") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "the lookup waited on the read")

        guard case .ready(let picture) = waitForLanding(fine) else { return XCTFail("the other picture never landed") }
        XCTAssertEqual(picture.frames.count, 2)
        guard case .loading = PictureStore.shared.picture(at: stuck) else { return XCTFail("the stuck one landed") }
    }

    func testAFileChangedInPlaceIsDecodedAgainAndShowsTheOldOneMeanwhile() throws {
        let url = try write(gif(frames: 1, side: 40), as: "changing.gif")
        guard case .ready(let first) = waitForLanding(url) else { return XCTFail("never landed") }

        try gif(frames: 1, side: 80).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        guard case .loading(let meanwhile) = PictureStore.shared.picture(at: url) else {
            return XCTFail("the change wasn't seen")
        }
        XCTAssert(meanwhile === first, "nothing shown while the new version decodes")
        guard case .ready(let second) = waitForLanding(url) else { return XCTFail("never landed") }
        XCTAssertEqual(second.size.width, 80)
    }

    func testAMissingFileIsMissingWithoutAskingTheQueue() {
        guard case .missing = PictureStore.shared.picture(at: folder.appendingPathComponent("nope.png")) else {
            return XCTFail("a missing file went to be read")
        }
    }

    // MARK: The view

    /// An animation plays as a keyframe animation over the decoded frames — the render server's work,
    /// not a decode per frame on main.
    func testThePictureViewPlaysAnAnimationFromItsFrames() throws {
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: 3, side: 32, delay: 0.1)))
        let view = CanvasPictureView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.picture = picture
        let animation = try XCTUnwrap(view.pictureLayer.animation(forKey: "frames") as? CAKeyframeAnimation)
        XCTAssertEqual(animation.values?.count, 3)
        XCTAssertEqual(animation.keyTimes?.map(\.doubleValue) ?? [], [0, 1.0 / 3, 2.0 / 3], accuracy: 0.001)
        XCTAssertEqual(animation.duration, 0.3, accuracy: 0.001)
        XCTAssert(view.pictureLayer.contents as AnyObject? === picture.frames.first)
    }

    func testAStillHasNoAnimation() throws {
        let picture = try XCTUnwrap(PictureDecode.picture(from: gif(frames: 1, side: 32)))
        let view = CanvasPictureView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.picture = picture
        XCTAssertNil(view.pictureLayer.animation(forKey: "frames"))
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

/// No new place hands a view an undecoded picture of user content. `NSImage(contentsOf:)` and
/// `NSImage(data:)` defer the decode to the first draw, which is on main; user pictures go through
/// `PictureStore` / `PictureDecode`. A site that is fine as it is says why with a `// picture:` comment
/// on its line or the three above.
final class PictureGuardTests: XCTestCase {
    private static let lazy = try! NSRegularExpression(
        pattern: #"NSImage(\.init)?\((contentsOf|data|contentsOfFile|byReferencing)"#)

    func testUserPicturesAreDecodedOffMain() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PM")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Pictures.swift" }
        XCTAssertGreaterThan(files.count, 50, "didn't find the app's sources at \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard Self.lazy.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { continue }
                guard !lines[max(0, index - 3)...index].contains(where: { $0.contains("// picture:") }) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssert(offenders.isEmpty, """
            Decode through PictureStore or PictureDecode off main, or say why not with `// picture:`:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
