import AppKit
import SwiftUI

// The sidebar's icon column: a layout's mini drawing, a card's letter badge, and the hue they share.
//
// Every icon here fills the same box (`SidebarMetrics.glyph`), so every title in the sidebar starts on
// one edge — a layout's, a card's, Notes' and Board's alike. Their sizes, radii and strokes are worked
// out from that one box rather than set one by one.

/// A colour picked for a site or a name, from a fixed set: the same host is the same hue in every row,
/// tile and layout drawing, and on every launch.
enum SidebarHue {
    /// Eight system colours, in an order where neighbours differ in hue as much as they can, so two
    /// names that hash next to each other still read as different.
    static let palette: [Color] = [.blue, .orange, .green, .purple, .red, .teal, .yellow, .pink]

    /// FNV-1a, not `hashValue`: Swift seeds that per launch, and a card mustn't change colour on relaunch.
    static func index(for key: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in key.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int(hash % UInt32(palette.count))
    }

    /// A card's: by its site, or by its title when it has none. `www.` doesn't count.
    static func index(host: String?, title: String) -> Int {
        if let host, !host.isEmpty {
            return index(for: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        return index(for: title)
    }

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

/// What a layout's icon draws: its columns, how wide each is, and its tiles top to bottom, each
/// tinted by the card it shows. Worked out once in `SpaceFrame.refresh()` from the tiling the board
/// already keeps (`CanvasWorkspaces`, cached), so drawing a row reads nothing.
struct LayoutShape: Equatable {
    enum Tint: Equatable {
        /// A note, a file, a view: no colour of its own.
        case plain
        /// A web card: its site's hue (`SidebarHue`).
        case hue(Int)
    }

    struct Column: Equatable {
        var share: Double
        var tiles: [Tint]
    }

    var columns: [Column]

    /// More than this many columns, or tiles down one, and a 16 pt drawing turns to stripes. The rest
    /// still exist; the drawing just says "many".
    static let maxColumns = 4
    static let maxTiles = 3

    static let empty = LayoutShape(columns: [Column(share: 1, tiles: [.plain])])

    /// The shape of a saved or live tiling. `tint` says what colour a card's tile is.
    init(_ tiling: CanvasViewState.Tiling?, tint: (String) -> Tint) {
        guard let tiling else { self = .empty; return }
        func share(_ size: CanvasTiling.Size) -> Double {
            // A pinned width is in points and a flexible one in shares; at this size, pinned reads as
            // one share, which is what it looks like beside its neighbours most of the time.
            if case .flexible(let value) = size, value > 0 { return value }
            return 1
        }
        var columns: [Column]
        if let saved = tiling.columns, !saved.isEmpty {
            columns = saved.map { column in
                Column(share: share(column.width), tiles: column.tiles.map { tint($0.shown) })
            }
        } else {
            // Saved before columns existed: rebuild what the arrangement would have drawn.
            let ids = tiling.ids
            switch tiling.arrangement {
            case .masterStack where ids.count > 1:
                let master = min(max(tiling.masterFraction, 0.2), 0.8)
                columns = [Column(share: master, tiles: [tint(ids[0])]),
                           Column(share: 1 - master, tiles: ids.dropFirst().map(tint))]
            default:
                // As near square as the count allows: 2 side by side, 4 as two by two, 6 as three by two.
                let across = max(1, Int(Double(ids.count).squareRoot().rounded(.up)))
                let down = max(1, (ids.count + across - 1) / across)
                columns = stride(from: 0, to: ids.count, by: down).map { start in
                    Column(share: 1, tiles: ids[start..<min(ids.count, start + down)].map(tint))
                }
            }
        }
        columns = columns.filter { !$0.tiles.isEmpty }.prefix(Self.maxColumns).map {
            Column(share: $0.share, tiles: Array($0.tiles.prefix(Self.maxTiles)))
        }
        self = columns.isEmpty ? .empty : LayoutShape(columns: columns)
    }

    init(columns: [Column]) { self.columns = columns }
}

/// A layout's icon: a small drawing of its columns and tiles, in a rounded box the size of a card's
/// icon. Plain tiles alternate two strengths of the label colour so neighbours stay apart; a web
/// card's tile wears its site's hue.
struct LayoutShapeGlyph: View {
    var shape: LayoutShape
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, box in
            let gap = max(1, size / 12)
            let radius = size * 0.28
            let frame = CGRect(origin: .zero, size: box)
            context.clip(to: Path(roundedRect: frame, cornerRadius: radius, style: .continuous))
            let total = shape.columns.reduce(0) { $0 + $1.share }
            let width = box.width - gap * CGFloat(shape.columns.count - 1)
            var x: CGFloat = 0
            var plain = 0
            for column in shape.columns {
                let w = width * CGFloat(column.share / max(total, 0.001))
                let h = (box.height - gap * CGFloat(column.tiles.count - 1)) / CGFloat(column.tiles.count)
                for (row, tint) in column.tiles.enumerated() {
                    let rect = CGRect(x: x, y: CGFloat(row) * (h + gap), width: w, height: h)
                    context.fill(Path(rect), with: .color(fill(tint, plainIndex: &plain)))
                }
                x += w + gap
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func fill(_ tint: LayoutShape.Tint, plainIndex: inout Int) -> Color {
        switch tint {
        case .hue(let index):
            return SidebarHue.color(index).opacity(scheme == .dark ? 0.85 : 0.75)
        case .plain:
            defer { plainIndex += 1 }
            let strong = plainIndex.isMultiple(of: 2)
            return Color.primary.opacity(scheme == .dark ? (strong ? 0.36 : 0.22) : (strong ? 0.24 : 0.14))
        }
    }
}

/// A card's initial on its site's hue: the hue faint behind, the letter in a deep (light mode) or pale
/// (dark mode) shade of it, and a hairline edge so it holds its shape on any wash.
struct LetterBadge: View {
    var title: String
    var hue: Int
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = SidebarHue.color(hue)
        let dark = scheme == .dark
        Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
            .foregroundStyle(color.mix(with: dark ? .white : .black, by: dark ? 0.5 : 0.4))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(dark ? 0.28 : 0.18)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
