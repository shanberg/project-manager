import AppKit
import PmLib

/// A project's texture, as drawn: a 1-bit tile, feathered into the top-left of the board's ground and
/// inked in the project's colour. See `ProjectTexture` for what's stored, and `CanvasColorWash`, which
/// draws it just above the wash.
///
/// **One bit, on purpose.** The patterns are the classic 8×8 desktop kind, and an image is brought down
/// to the same thing — Atkinson-dithered, the MacPaint look — so a photo reads as an engraving rather
/// than a picture fighting the cards, and every texture, built-in or not, is one family.
///
/// **The feather is dithered too.** A pattern pixel shows only where an 8×8 Bayer threshold is under the
/// fall-off's strength there, so the pattern breaks up into scattered dots toward its edge rather than
/// fading. An alpha fade over a 1-bit pattern looks like a blurred screenshot of one.
///
/// **Whole points, never smoothed.** A pattern pixel is the style's `pixel` points square, drawn
/// nearest-neighbour from a bitmap with one pixel per cell, and anchored at the view's origin so a
/// resize doesn't make it swim.
///
/// **Reach is a length sized to the pane**, not a measurement: short, medium or long. Each is a share
/// of the pane held between a floor and a ceiling in points — the floor so a texture set on a wide
/// screen is still there in a small panel, the ceiling so a long one doesn't swallow a wide screen. It's
/// an ellipse from the corner, a little taller in proportion than it is wide, so it reads as a corner
/// rather than a band.
enum CanvasTexture {
    /// What a board is handed: the tile, and how to lay it on.
    struct Spec: Equatable {
        let tile: Tile
        let style: ProjectTextureStyle
    }

    /// A pattern's cells, row-major. `true` is ink.
    struct Tile: Equatable {
        let width: Int
        let height: Int
        let bits: [Bool]

        func isInk(_ x: Int, _ y: Int) -> Bool { bits[(y % height) * width + (x % width)] }
    }

    /// The ink's strength at the corner. Dark takes a fifth more, as the wash does, for the same reason:
    /// a colour over near-black reads weaker than the same alpha over near-white.
    static func alpha(_ style: ProjectTextureStyle, dark: Bool) -> Double {
        Double(style.strength) / 100 * (dark ? 1.2 : 1)
    }

    /// The fall-off's radii for a pane of `size`. Never more than the pane, however high the floor.
    static func reach(_ style: ProjectTextureStyle, in size: CGSize) -> CGSize {
        let (share, floor, ceiling): (CGFloat, CGFloat, CGFloat) = switch style.reach {
        case .short: (0.3, 140, 380)
        case .medium: (0.5, 220, 660)
        case .long: (0.75, 320, 1000)
        }
        // Height is held in a little closer than width: a window is wider than it is tall.
        let width = min(max(size.width * share, floor), ceiling, size.width)
        let height = min(max(size.height * share * 1.1, floor * 0.7), ceiling * 0.7, size.height * 1.1)
        return CGSize(width: width, height: height)
    }

    // MARK: Resolving

    /// What a board is handed for a project's texture and style. Nil for none, and for an image that
    /// isn't there or won't decode — a missing texture draws nothing rather than complaining from the
    /// background.
    @MainActor
    static func spec(for texture: ProjectTexture?, style: ProjectTextureStyle, notesPath: String?) -> Spec? {
        tile(for: texture, cells: style.tile, notesPath: notesPath).map { Spec(tile: $0, style: style) }
    }

    /// The tile alone — for the settings sheet, which draws swatches rather than a board.
    @MainActor
    static func tile(for texture: ProjectTexture?, cells: Int, notesPath: String?) -> Tile? {
        switch texture {
        case nil: return nil
        case .named(let name): return tile(rows: rows(name))
        case .image:
            guard let notesPath, let url = texture?.imageURL(notesPath: notesPath) else { return nil }
            // Keyed on the modification date too, so replacing the file in place is seen on the next read.
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            let key = "\(url.path)|\(date?.timeIntervalSinceReferenceDate ?? 0)|\(cells)"
            if let hit = imageTiles[key] { return hit }
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let tile = dithered(image, cells: cells) else { return nil }
            imageTiles[key] = tile
            return tile
        }
    }

    @MainActor private static var imageTiles: [String: Tile] = [:]

    /// A built-in pattern's eight rows, most significant bit leftmost.
    static func rows(_ name: ProjectTexture.Name) -> [UInt8] {
        switch name {
        case .dither: return [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        case .checker: return [0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55]
        case .stipple: return [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00]
        case .dots: return [0x80, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]
        case .hatch: return [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]
        case .cross: return [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81]
        case .grid: return [0xff, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]
        case .bricks: return [0xff, 0x80, 0x80, 0x80, 0xff, 0x08, 0x08, 0x08]
        case .weave: return [0xf8, 0x74, 0x22, 0x47, 0x8f, 0x17, 0x22, 0x71]
        case .scales: return [0x80, 0x80, 0x41, 0x3e, 0x08, 0x08, 0x14, 0xe3]
        case .waves: return [0x00, 0x00, 0x18, 0x24, 0xc3, 0x00, 0x00, 0x00]
        case .shingle: return [0x01, 0x02, 0x04, 0x08, 0x10, 0x28, 0x44, 0x82]
        }
    }

    static func tile(rows: [UInt8]) -> Tile {
        Tile(width: 8, height: rows.count,
             bits: rows.flatMap { row in (0..<8).map { row >> (7 - $0) & 1 == 1 } })
    }

    /// An image brought down to `cells` on its long side — the tile size — then Atkinson-dithered to one
    /// bit. Dark is ink; transparency counts as light, so a cut-out shape is the shape and not its box.
    static func dithered(_ image: CGImage, cells: Int) -> Tile? {
        let scale = min(1, Double(cells) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        var levels = (0..<width * height).map { Double(bytes[$0]) }
        var bits = [Bool](repeating: false, count: width * height)
        // Atkinson passes on only six eighths of the error, which is what keeps its highlights and
        // shadows clean rather than speckled.
        let spread = [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let light = levels[i] >= 128
                bits[i] = !light
                let error = (levels[i] - (light ? 255 : 0)) / 8
                for (dx, dy) in spread {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny < height { levels[ny * width + nx] += error }
                }
            }
        }
        return Tile(width: width, height: height, bits: bits)
    }

    // MARK: Drawing

    static let bayer: [Int] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// The texture over `reach`, one bitmap pixel per cell of `pixel` points — premultiplied sRGB, first
    /// row at the top. The fall-off is the wash's smootherstep over an elliptical distance from the corner.
    static func image(tile: Tile, ink: (Double, Double, Double), alpha: Double, pixel: CGFloat, reach: CGSize) -> CGImage? {
        let columns = Int((reach.width / pixel).rounded(.up))
        let rows = Int((reach.height / pixel).rounded(.up))
        guard columns > 0, rows > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let channels = [ink.0 * alpha, ink.1 * alpha, ink.2 * alpha, alpha].map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        // In cells rather than points: the same ellipse, without a multiply per cell.
        let radiusX = Double(reach.width / pixel), radiusY = Double(reach.height / pixel)
        for y in 0..<rows {
            let dy = (Double(y) + 0.5) / radiusY
            for x in 0..<columns where tile.isInk(x, y) {
                let dx = (Double(x) + 0.5) / radiusX
                let strength = CanvasColorWash.strength(at: (dx * dx + dy * dy).squareRoot())
                guard (Double(bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64 < strength else { continue }
                let base = (y * columns + x) * 4
                pixels.replaceSubrange(base..<base + 4, with: channels)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The ink for a colour: the colour pulled toward the text, so it reads as texture on the wash
    /// rather than as a second colour. No colour inks in the text colour itself.
    static func ink(for rgb: (Double, Double, Double)?, dark: Bool) -> (Double, Double, Double) {
        guard let rgb else { return dark ? (1, 1, 1) : (0, 0, 0) }
        if dark { return (rgb.0 + (1 - rgb.0) * 0.35, rgb.1 + (1 - rgb.1) * 0.35, rgb.2 + (1 - rgb.2) * 0.35) }
        return (rgb.0 * 0.7, rgb.1 * 0.7, rgb.2 * 0.7)
    }

    /// Decoration, so it steps aside for anyone who has asked the screen to be plainer.
    @MainActor
    static var isSuppressed: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
