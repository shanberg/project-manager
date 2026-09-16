import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os

/// The picture of a page a card shows when it isn't running one.
///
/// Freezing a card has always left a snapshot behind, because a board where the cards you aren't
/// looking at turn back into globes is a board that tells you less the more of it you can see. The
/// picture belonged to the *view*, though, and a view is the shortest-lived thing in this story — so
/// it was lost in the two places it was most wanted:
///
/// - **A card recycled out of the pool.** Scroll a card off the board and back and `prepareForRemoval`
///   has thrown its view away, picture and all. The card comes back as a globe and a hostname, having
///   been a page a second ago.
/// - **A relaunch.** Every board opened cold, eleven placeholders at once, and filled in over the next
///   few seconds as the budget woke them one at a time. That is the moment a board most needs to say
///   what it is, and it was the moment it said least.
///
/// So a picture is kept for the card, keyed the way the page and the resume address are —
/// `CanvasPageHandover.key(canvas:card:)` — in memory for this session and on disk for the next.
///
/// **Two per card, one for each shape a card has.** The same card is a 400pt square on the board and
/// most of a window as a tile, and a picture is the shape it was taken at. Kept as one, closing a tile
/// put a window-shaped picture in the store, and the board then showed its top-left corner in the card
/// (backlog 35). So the picture is filed by whether the card was tiled, and a card with a picture only
/// in the other shape shows its placeholder: a globe says less than a cropped page, but it is never
/// wrong about what the page looks like, and the right-shaped picture arrives the first time the page
/// is seen at that shape.
///
/// **A cache, in the directory for caches.** Derived entirely from pages PM happened to load, throwing
/// it away costs nothing worse than a board that opens as placeholders once, and it is measured in
/// megabytes — all three of which are `CanvasContentBlocker`'s reasons for putting its compiled lists
/// in the same place. Nothing here goes near the `.canvas`, for `CanvasPageTitles`' reason: looking at
/// a board must not edit it.
@MainActor
enum CanvasPageSnapshots {

    /// The picture of this card's page at this shape, if there is one.
    static func of(_ card: String, tiled: Bool) -> NSImage? {
        let card = key(card, tiled: tiled)
        if let known = memory[card] { return known.image }
        // Lazy: `NSImage` reads the file's header here and decodes when something draws it, so a board
        // building forty cards pays for the handful it can see.
        let image = NSImage(contentsOf: file(for: card))
        // Remembered either way. A card with no picture is most of them, and the miss is worth keeping
        // so that building it again doesn't go back to the disk to be told the same thing.
        memory[card] = Held(image: image)
        return image
    }

    /// Keep what this card was showing.
    ///
    /// **Up in memory now, shrunk and encoded later.** This is called from `prepareForRemoval` as well
    /// as from a pause, and that is the hot one: cards are recycled as they scroll out of view, so a
    /// scroll across a full board can hand this several pictures in a frame. Resampling and encoding
    /// them on the way through would be tens of milliseconds each on the main thread, during a scroll,
    /// which is the one place this feature could cost more than it is worth. Both halves are CoreGraphics
    /// and neither needs the main thread.
    ///
    /// The full-size image stands in for the shrunk one until it lands, which is a moment later and is
    /// the picture the card in front of you would have shown anyway.
    static func keep(_ image: NSImage, for card: String, tiled: Bool) {
        guard !card.isEmpty,
              let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let card = key(card, tiled: tiled)
        stamp &+= 1
        let mine = stamp
        memory[card] = Held(image: image, stamp: mine)
        forgetOldest()
        let file = file(for: card)
        Task.detached(priority: .utility) {
            guard let small = shrink(full) else { return }
            if let data = encode(small) { write(data, to: file) }
            await MainActor.run { settle(small, for: card, stamp: mine) }
        }
    }

    /// Swap the full-size stand-in for the one that was actually stored.
    ///
    /// **Only if nothing newer arrived.** A card frozen twice in quick succession — paused, woken,
    /// paused again — has two of these in flight, and the older one landing last would put the older
    /// picture up. The stamp is what tells them apart.
    private static func settle(_ image: CGImage, for card: String, stamp: UInt64) {
        guard memory[card]?.stamp == stamp else { return }
        let size = NSSize(width: image.width, height: image.height)
        memory[card] = Held(image: NSImage(cgImage: image, size: size), stamp: stamp)
    }

    private static var stamp: UInt64 = 0

    /// Throw this card's picture away — because its address changed, and a picture of the page it used
    /// to point at is worse than no picture at all.
    ///
    /// **Remembered as a miss rather than removed.** Deleting the file is IO and happens when it
    /// happens; removing the row would send the very next `of` back to a disk that still has the old
    /// picture on it — and the next `of` is usually immediate, because changing a card's address
    /// rebuilds the card. The miss is the answer from this moment on, whatever the disk says.
    static func forget(_ card: String) {
        for tiled in [false, true] {
            let card = key(card, tiled: tiled)
            memory[card] = Held(image: nil)
            let file = file(for: card)
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Where a card's picture at one shape is filed. The board's shape keeps the card's own key, so the
    /// pictures kept before there were two are found as the board pictures they mostly were.
    private static func key(_ card: String, tiled: Bool) -> String {
        tiled ? card + "#tile" : card
    }

    // MARK: What is kept, and how big

    private struct Held {
        var image: NSImage?
        /// Which call to `keep` this came from, so a stored picture landing late cannot overwrite a
        /// newer one. Zero for a remembered miss, which no `settle` will ever match.
        var stamp: UInt64 = 0
        var seen = Date()
    }

    private static var memory: [String: Held] = [:]

    /// How many cards are remembered in this session. Generous, because a hit is a card that draws as
    /// itself the moment it is built and a miss is a globe — but not unbounded, because these are
    /// bitmaps and a long session crosses a lot of boards.
    static let capacity = 80

    private static func forgetOldest() {
        guard memory.count > capacity else { return }
        let keeping = Set(memory.sorted { $0.value.seen > $1.value.seen }.prefix(capacity).map(\.key))
        memory = memory.filter { keeping.contains($0.key) }
    }

    /// The longest edge a stored picture is allowed, in pixels.
    ///
    /// It is a stand-in that a loaded page crosses out in a fifth of a second, so it is sized to read
    /// as the page rather than to be read: the shape of the thing, its columns, its colour, the
    /// headline if there is one. Storing a Retina tile at full size would be four megabytes a card for
    /// detail nobody looks at long enough to want.
    static let longestEdge = 1400.0

    /// CoreGraphics throughout, so this can run anywhere. `lockFocus` and `NSImage.draw` would have
    /// been shorter and are AppKit drawing, which is the main thread's.
    nonisolated private static func shrink(_ image: CGImage) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, longestEdge / max(width, height))
        guard scale < 1 else { return image }
        let wanted = (width: Int((width * scale).rounded()), height: Int((height * scale).rounded()))
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: wanted.width, height: wanted.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: wanted.width, height: wanted.height))
        return context.makeImage() ?? image
    }

    // MARK: Where they are kept

    /// JPEG rather than PNG: a screenshot of a page is a photograph as far as an encoder is concerned,
    /// and the difference on a board's worth of them is tens of megabytes against hundreds. The quality
    /// is high enough that the artefacts are invisible at the size this is drawn.
    private static let quality = 0.85

    /// The bits, encoded. Nil for an image with nothing in it, which a snapshot of a card that never
    /// painted is.
    nonisolated private static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(sink, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return out as Data
    }

    private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.stuarthanberg.pm")
            .appendingPathComponent("PageSnapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Named by a digest of the key rather than by the key itself, which is a full file path and a node
    /// id and would be both too long for a filename and full of separators.
    private static func file(for card: String) -> URL {
        let digest = SHA256.hash(data: Data(card.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = folder ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return folder.appendingPathComponent(digest).appendingPathExtension("jpg")
    }

    nonisolated private static func write(_ data: Data, to file: URL) {
        try? data.write(to: file, options: .atomic)
        sweepOnce()
    }

    /// Delete the least recently written once there are too many, once per launch.
    ///
    /// A directory with no ceiling is one that grows for as long as the app is installed, and the
    /// entries here have no natural end: the board a picture belongs to may have been deleted months
    /// ago and nothing here would know. Once per launch because the answer barely moves and a
    /// directory listing per freeze would be IO on every budget pass.
    nonisolated private static let swept = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static func sweepOnce() {
        let alreadySwept = swept.withLock { was -> Bool in
            defer { was = true }
            return was
        }
        guard !alreadySwept, let folder else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys), files.count > onDisk else { return }
        let byAge = files.map { file in
            (file, (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (file, _) in byAge.dropFirst(onDisk) { try? FileManager.default.removeItem(at: file) }
    }

    /// How many pictures survive a quit. Larger than `capacity`, because this one is measured against
    /// every board you have ever opened rather than against one session, and a picture is the whole
    /// value of a board that opens cold. Counted in files, and a card can have two, so it was doubled
    /// when the tile's picture was split from the card's.
    static let onDisk = 800
}

