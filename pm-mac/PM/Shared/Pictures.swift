import AppKit
import ImageIO
import Observation

/// Pictures from files and bytes: read and decoded off the main thread, handed to views as pixels.
///
/// - `NSImage(contentsOf:)` and `NSImage(data:)` decode nothing. The decode happens the first time the
///   image is drawn — for a layer's contents, inside Core Animation's commit, on the main thread.
/// - A large or malformed picture holds that decode indefinitely: 2026-11-05, a report from another
///   Mac, the main thread 8.7 s inside the GIF decoder under `CA::Layer::prepare_contents`.
/// - The same theme as the cloud reads (see `CloudFile`): work whose cost is set by the file, not by
///   the app, done on the thread that draws.
/// - So: user pictures come through `PictureStore` (cached, observed) or `PictureDecode` on a
///   background queue. Views get `Picture`, whose frames are already-decoded bitmaps.
/// - `PictureGuardTests` fails the build's tests on a new `NSImage(contentsOf:)` / `NSImage(data:)`
///   outside this file.
final class Picture: @unchecked Sendable {
    /// Decoded bitmaps. One for a still; the frames, in order, for an animation.
    let frames: [CGImage]
    /// Seconds each frame shows. Empty for a still.
    let delays: [TimeInterval]
    /// Points, from the file's pixels and resolution — what `NSImage.size` reported.
    let size: NSSize
    /// A drawing the file describes rather than pixels (SVG, PDF). No frames.
    let vector: NSImage?
    /// Bytes the frames hold, for the cache's budget.
    let cost: Int

    init(frames: [CGImage], delays: [TimeInterval], size: NSSize, vector: NSImage? = nil) {
        self.frames = frames
        self.delays = delays
        self.size = size
        self.vector = vector
        cost = frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } + (vector == nil ? 0 : 64 * 1024)
    }

    var isAnimated: Bool { frames.count > 1 && delays.count == frames.count }
    var duration: TimeInterval { delays.reduce(0, +) }

    /// The still: the vector drawing, or the first frame at the picture's point size. For SwiftUI,
    /// menus, drags and the pasteboard.
    var image: NSImage {
        if let vector { return vector }
        guard let first = frames.first else { return NSImage(size: size) }
        return NSImage(cgImage: first, size: size)
    }
}

/// Bytes into a `Picture`. Nonisolated and synchronous: callers are background queues.
enum PictureDecode {
    /// The longest side a still is decoded at. A card or a note never shows one larger than a screen.
    static let screenSide = 2560
    /// Bytes an animation's frames may hold together. Past it the frames are decoded smaller; past
    /// `smallestAnimatedSide` the picture is a still of its first frame.
    static let animationBudget = 64 * 1024 * 1024
    static let smallestAnimatedSide = 240
    static let mostFrames = 600

    nonisolated static func picture(contentsOf url: URL, maxSide: Int = screenSide,
                                    reader: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Picture? {
        reader(url).flatMap { picture(from: $0, maxSide: maxSide) }
    }

    nonisolated static func picture(from data: Data, maxSide: Int = screenSide) -> Picture? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return vector(from: data) }

        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let pixels = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let size = NSSize(width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi)
        let longest = Int(max(pixels.width, pixels.height))

        let count = CGImageSourceGetCount(source)
        let delays = count > 1 && count <= mostFrames ? frameDelays(source, count: count) : nil
        if let delays {
            // The side that keeps every frame inside the budget, never larger than a still's.
            let perFrame = Double(animationBudget) / Double(count)
            let fits = Int((perFrame / 4 / Double(pixels.width * pixels.height)).squareRoot() * Double(longest))
            let side = min(longest, maxSide, fits)
            if side >= min(longest, smallestAnimatedSide) {
                var frames: [CGImage] = []
                frames.reserveCapacity(count)
                for index in 0..<count {
                    guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                          let drawn = bitmap(frame, side: side) else { break }
                    frames.append(drawn)
                }
                if frames.count == count { return Picture(frames: frames, delays: delays, size: size) }
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, maxSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let still = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let drawn = bitmap(still, side: max(still.width, still.height)) else { return nil }
        return Picture(frames: [drawn], delays: [], size: size)
    }

    /// Each frame's delay, or nil when the file is several images rather than an animation (a HEIC
    /// collection). The browsers' rule for a delay under 11 ms: 100 ms.
    nonisolated private static func frameDelays(_ source: CGImageSource, count: Int) -> [TimeInterval]? {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        var delays: [TimeInterval] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let (inner, unclamped, clamped) = containers.first(where: { properties[$0.0] != nil }),
                  let frame = properties[inner] as? [CFString: Any] else { return nil }
            let delay = (frame[unclamped] as? Double) ?? (frame[clamped] as? Double) ?? 0.1
            delays.append(delay < 0.011 ? 0.1 : delay)
        }
        return delays
    }

    /// `image` drawn into a plain bitmap no longer than `side` on its longest edge. A bitmap holds
    /// pixels, not a decoder: Core Animation shows it without calling back into ImageIO.
    nonisolated static func bitmap(_ image: CGImage, side: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Double(side) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// SVG and PDF: no pixels to decode, drawn by AppKit at whatever size is asked.
    nonisolated private static func vector(from data: Data) -> Picture? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return Picture(frames: [], delays: [], size: image.size, vector: image)
    }
}

/// What a lookup in `PictureStore` found.
enum PictureLookup {
    case ready(Picture)
    /// Being read and decoded. The file's previous version meanwhile, when it had one.
    case loading(Picture?)
    /// Not there, or not a picture.
    case missing
    /// Online-only: not read, because reading downloads it. See `CloudFile`.
    case inCloud

    var picture: Picture? {
        switch self {
        case .ready(let picture): return picture
        case .loading(let previous): return previous
        case .missing, .inCloud: return nil
        }
    }
}

/// Pictures of files, by path, version and size. Asked on main, answered at once from memory; a miss
/// reads and decodes on `queue` and lands a turn later.
///
/// - Observed: a SwiftUI body or `ObservationRelay` that looked something up is asked again when any
///   picture lands. AppKit callers pass `whenReady` instead.
/// - The version is `stat`'s modification date and size — `stat` answers for an online-only file
///   without downloading it.
/// - Concurrent queue: a decode that never returns holds its own thread, not everyone's.
@MainActor
@Observable
final class PictureStore {
    static let shared = PictureStore()

    nonisolated static let queue = DispatchQueue(label: "Folio.picture-decodes", qos: .userInitiated,
                                                 attributes: .concurrent)

    /// Bumped as each picture lands. Read by every lookup, so observers redraw.
    private(set) var landed = 0

    @ObservationIgnored private let cache: NSCache<NSString, Picture> = {
        let cache = NSCache<NSString, Picture>()
        cache.totalCostLimit = 384 * 1024 * 1024
        return cache
    }()
    /// Keys that decoded to nothing. Strings, so kept without a limit worth worrying about.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var inFlight: [String: [AnyHashable: @MainActor () -> Void]] = [:]
    /// The last key each path and size was ready at — what shows while a newer version decodes.
    @ObservationIgnored private var previous: [String: String] = [:]

    /// How a file is read. A test stands in a slow or stuck one.
    @ObservationIgnored nonisolated(unsafe) static var reader: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }

    /// The picture of `url`, or what is happening to it.
    /// - `owner`: one `whenReady` per owner per load, so asking again while it's out doesn't pile up.
    func picture(at url: URL, maxSide: Int = PictureDecode.screenSide,
                 owner: AnyObject? = nil, whenReady: (@MainActor () -> Void)? = nil) -> PictureLookup {
        _ = landed
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return .inCloud }
        let base = "\(url.path)\t\(maxSide)"
        let key = "\(base)\t\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)\t\(info.st_size)"
        if let hit = cache.object(forKey: key as NSString) { return .ready(hit) }
        if failed.contains(key) { return .missing }
        let earlier = previous[base].flatMap { cache.object(forKey: $0 as NSString) }

        let owned: AnyHashable = owner.map { AnyHashable(ObjectIdentifier($0)) } ?? AnyHashable(UUID())
        if inFlight[key] != nil {
            if let whenReady { inFlight[key]?[owned] = whenReady }
            return .loading(earlier)
        }
        inFlight[key] = whenReady.map { [owned: $0] } ?? [:]
        let reader = Self.reader
        Self.queue.async {
            let picture = PictureDecode.picture(contentsOf: url, maxSide: maxSide, reader: reader)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.land(picture, key: key, base: base) }
            }
        }
        return .loading(earlier)
    }

    private func land(_ picture: Picture?, key: String, base: String) {
        if let picture {
            cache.setObject(picture, forKey: key as NSString, cost: picture.cost)
            previous[base] = key
        } else {
            failed.insert(key)
        }
        let waiting = inFlight.removeValue(forKey: key) ?? [:]
        landed &+= 1
        for job in waiting.values { job() }
    }

    /// Decode bytes already in memory — a drop, a paste — off main.
    nonisolated static func decode(_ data: Data, maxSide: Int = PictureDecode.screenSide,
                                   then answer: @escaping @MainActor (Picture?) -> Void) {
        queue.async {
            let picture = PictureDecode.picture(from: data, maxSide: maxSide)
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(picture) } }
        }
    }
}
