import AppKit
import SwiftUI

/// Where the links on a card are drawn, so the board can follow one — or carry it off — without the
/// card having to be stepped into first.
///
/// **A link is the one thing on a card that belongs to the pointer before the card does.** A card
/// refuses clicks until you step in (`CanvasNodeView.takesItsOwnClicks`), which is right for rows and
/// checkboxes and wrong for a link: following one cost a click spent stepping in, and nothing under the
/// pointer said a link was there at all. So the board answers a press on a link itself, in every mode
/// and whether or not the card is stepped into — a click opens it, and a drag carries it out onto the
/// board as a card of its own, or into a tiled view as a tile. Links are small, so the card is still
/// easy to pick up by anything else.
///
/// **SwiftUI knows where they are, and says so here.** A link in a note is a run inside one `Text`,
/// with no view of its own to hit-test and — it turned out — nothing in the accessibility tree either,
/// so each link run is marked (`CanvasLinkMark`) and the text's own layout is read back for where the
/// marked runs landed. A brief's link row is a view, and reports its frame. Both go into the card's
/// `CanvasLinkZones`, measured in `space`, which is the card's hosting view's own coordinates.
///
/// **Off a board nothing reports.** The registry arrives through the environment and only a card puts
/// one there, so the project window draws the same views and they behave exactly as they always have.
@MainActor
final class CanvasLinkZones {
    /// The coordinate space every zone is measured in. `canvasLinkZones(_:)` names it on the root of a
    /// card's hosting view, so a zone's rectangle is a rectangle in that view.
    static let space = "canvasLinkZones"

    struct Zone: Equatable {
        let url: URL
        let rect: CGRect
    }

    /// Per reporter, so one piece of text leaving takes only its own links with it.
    private var zones: [UUID: [Zone]] = [:]

    func set(_ reported: [Zone], for reporter: UUID) {
        zones[reporter] = reported.isEmpty ? nil : reported
    }

    func clear(_ reporter: UUID) {
        zones[reporter] = nil
    }

    func removeAll() {
        zones = [:]
        lists = [:]
    }

    // MARK: Lists that reorder

    /// A list of links on the card that can be dragged into a new order — a project's `## Links` (canvas
    /// backlog 14). A press on one of its links is still the board's, as every link is; a drag that stays
    /// on the list moves the link along it, and one that leaves carries it off as a card.
    struct List {
        /// Each row by its place among the links that move, in `space`.
        var rows: [Int: CGRect] = [:]
        /// How many there are now, so a row reported before the list shrank is not read.
        var count = 0
        var move: (Int, Int) -> Void = { _, _ in }

        /// The rows there are, in order.
        var ordered: [CGRect] { (0..<count).compactMap { rows[$0] } }
    }

    private var lists: [UUID: List] = [:]

    func setList(_ id: UUID, count: Int, move: @escaping (Int, Int) -> Void) {
        lists[id, default: List()].count = count
        lists[id]?.move = move
    }

    func setRow(_ id: UUID, slot: Int, rect: CGRect) {
        lists[id, default: List()].rows[slot] = rect
    }

    func clearList(_ id: UUID) {
        lists[id] = nil
    }

    /// The reorderable row drawn at `point`, in `space`: which list, and its place in it.
    func row(at point: CGPoint) -> (list: UUID, slot: Int)? {
        for (id, list) in lists {
            for (slot, rect) in list.rows where slot < list.count && rect.insetBy(dx: -1, dy: -1).contains(point) {
                return (id, slot)
            }
        }
        return nil
    }

    func list(_ id: UUID) -> List? { lists[id] }

    /// The link drawn at `point`, in `space`.
    ///
    /// A point's grace around each rectangle: a run's typographic bounds are exactly as tall as the
    /// line, and a press on the underline's lower edge is a press on the link.
    func link(at point: CGPoint) -> URL? {
        for reported in zones.values {
            if let zone = reported.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }) {
                return zone.url
            }
        }
        return nil
    }
}

/// A link run in a `Text`, marked so the text's layout can say where it went. See `linkMarkedText`.
struct CanvasLinkMark: TextAttribute {
    let url: URL
}

/// `attributed` as one `Text`, with every link run marked by `CanvasLinkMark`.
///
/// It draws exactly as `Text(attributed)` does — the pieces are the same runs with the same attributes,
/// the link among them, so a click in the project window still follows it. Split only at the links'
/// edges, and not split at all when there are none, which is most of the prose in a note.
func linkMarkedText(_ attributed: AttributedString) -> Text {
    let pieces = attributed.runs[\.link]
    guard pieces.contains(where: { $0.0 != nil }) else { return Text(attributed) }
    var text = Text(verbatim: "")
    for (url, range) in pieces {
        var piece = Text(AttributedString(attributed[range]))
        if let url { piece = piece.customAttribute(CanvasLinkMark(url: url)) }
        text = Text("\(text)\(piece)")
    }
    return text
}

extension EnvironmentValues {
    /// The card this view is drawn on, when it is drawn on one. See `CanvasLinkZones`.
    @Entry var canvasLinkZones: CanvasLinkZones? = nil
}

extension View {
    /// Make this the root of a card's links: hand `zones` down to everything that draws one, and name
    /// the space they are measured in.
    ///
    /// Filling the hosting view, so the space's origin is the hosting view's corner however small the
    /// content is — a root the hosting view centred would put every zone off by the margin.
    func canvasLinkZones(_ zones: CanvasLinkZones) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(CanvasLinkZones.space))
            .environment(\.canvasLinkZones, zones)
    }

    /// Report where this text's marked links were drawn — see `linkMarkedText` — to the card it is on.
    func reportsLinkZones() -> some View {
        modifier(TextLinkZones())
    }

    /// Make this the list the rows inside it belong to: `count` rows that move, and what moving one does.
    func reordersLinks(_ list: UUID, count: Int, move: @escaping (Int, Int) -> Void) -> some View {
        modifier(LinkListRegistration(list: list, count: count, move: move))
    }

    /// Report this view as the `slot`th row of a list that reorders — see `reordersLinks`.
    func reportsLinkRow(_ list: UUID, slot: Int) -> some View {
        modifier(LinkRowZone(list: list, slot: slot))
    }

    /// Report this whole view as a link to `url`, to the card it is on.
    func reportsLinkZone(_ url: URL) -> some View {
        modifier(ViewLinkZone(url: url))
    }
}

/// Reads the text's layout for the runs `linkMarkedText` marked. Re-read whenever the geometry moves —
/// scrolling included, since the space is named outside the card's scroll view — so a zone is always
/// where its link is now.
private struct TextLinkZones: ViewModifier {
    @Environment(\.canvasLinkZones) private var registry
    @State private var id = UUID()

    @ViewBuilder func body(content: Content) -> some View {
        if let registry {
            content.backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: Self.zones(in: layouts, proxy: proxy), initial: true) { _, now in
                            registry.set(now, for: id)
                        }
                        .onDisappear { registry.clear(id) }
                }
            }
        } else {
            content
        }
    }

    private static func zones(in layouts: [Text.LayoutKey.AnchoredLayout],
                              proxy: GeometryProxy) -> [CanvasLinkZones.Zone] {
        let base = proxy.frame(in: .named(CanvasLinkZones.space)).origin
        return layouts.flatMap { anchored in
            let origin = proxy[anchored.origin]
            return anchored.layout.flatMap { line in
                line.compactMap { run in
                    run[CanvasLinkMark.self].map {
                        CanvasLinkZones.Zone(url: $0.url,
                                             rect: run.typographicBounds.rect
                                                .offsetBy(dx: base.x + origin.x, dy: base.y + origin.y))
                    }
                }
            }
        }
    }
}

private struct ViewLinkZone: ViewModifier {
    let url: URL
    @Environment(\.canvasLinkZones) private var registry
    @State private var id = UUID()

    @ViewBuilder func body(content: Content) -> some View {
        if let registry {
            content.background {
                GeometryReader { proxy in
                    let zone = CanvasLinkZones.Zone(url: url,
                                                    rect: proxy.frame(in: .named(CanvasLinkZones.space)))
                    Color.clear
                        .onChange(of: zone, initial: true) { _, now in registry.set([now], for: id) }
                        .onDisappear { registry.clear(id) }
                }
            }
        } else {
            content
        }
    }
}

private struct LinkListRegistration: ViewModifier {
    let list: UUID
    let count: Int
    let move: (Int, Int) -> Void
    @Environment(\.canvasLinkZones) private var registry

    @ViewBuilder func body(content: Content) -> some View {
        if let registry {
            content
                .onChange(of: count, initial: true) { _, now in registry.setList(list, count: now, move: move) }
                .onDisappear { registry.clearList(list) }
        } else {
            content
        }
    }
}

private struct LinkRowZone: ViewModifier {
    let list: UUID
    let slot: Int
    @Environment(\.canvasLinkZones) private var registry

    @ViewBuilder func body(content: Content) -> some View {
        if let registry {
            content.background {
                GeometryReader { proxy in
                    let rect = proxy.frame(in: .named(CanvasLinkZones.space))
                    Color.clear
                        .onChange(of: rect, initial: true) { _, now in registry.setRow(list, slot: slot, rect: now) }
                }
            }
        } else {
            content
        }
    }
}
