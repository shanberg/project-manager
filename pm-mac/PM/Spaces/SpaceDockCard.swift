import AppKit
import PmLib
import SwiftUI

/// A space's flyout from the dock (docs/spaces.md § Dock): its name and Show Window; Now Playing for
/// anything making sound, with pause; then its cards, favourites and pinned first. A card opens in the
/// space; its menu sends it to a project.
struct SpaceDockCard: View {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var host: String?
        var symbol: String?
        var pinned: Bool
        var playing: Bool
        var url: String?
    }

    let spaceID: String
    let title: String
    let color: Color
    let items: [Item]
    let dismiss: () -> Void

    /// Read the space's board as it stands: the file, and whichever pages are making sound now.
    static func make(spaceID: String, dismiss: @escaping () -> Void) -> SpaceDockCard? {
        guard let space = Spaces.shared.space(spaceID), let canvas = Spaces.shared.canvas(of: spaceID) else { return nil }
        let document = (try? CanvasDocument.read(contentsOf: canvas)) ?? CanvasDocument()
        let sounding = CanvasLinkNodeView.playingCards(onCanvas: canvas)
        let items = CanvasItems.all(of: document, lookups: CanvasExistingCards.lookups()).compactMap { item -> Item? in
            guard let node = document.node(id: item.id) else { return nil }
            var host: String?, symbol: String?, url: String?
            switch item.kind {
            case .page(let h): host = h
            case .file(let s), .view(let s): symbol = s
            case .text: symbol = "text.alignleft"
            }
            if case .link(let address) = node.content { url = address }
            return Item(id: item.id, title: item.title, host: host, symbol: symbol,
                        pinned: SpaceCardMarks.isPinned(node), playing: sounding.contains(item.id), url: url)
        }
        // Pinned first, as the sidebar has them; the board's own order within each.
        let ordered = items.filter(\.pinned) + items.filter { !$0.pinned }
        return SpaceDockCard(spaceID: spaceID, title: space.title,
                             color: Color(nsColor: ProjectColor(value: space.color)?.nsColor ?? .systemGray),
                             items: ordered, dismiss: dismiss)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(items.count == 1 ? "1 card" : "\(items.count) cards").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss(); Spaces.shared.show(spaceID) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Show Window")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(items.filter(\.playing)) { item in
                HStack(spacing: 10) {
                    SpaceRowGlyph(host: item.host, symbol: item.symbol, title: item.title, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Now Playing").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { Spaces.shared.pause(item.id, in: spaceID) } label: {
                        Image(systemName: "pause.fill").font(.system(size: 12))
                            .frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain).help("Pause")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider().padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in row(item) }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 360)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: Item) -> some View {
        SpaceDockRow(item: item) {
            dismiss()
            Spaces.shared.showCard(item.id, in: spaceID)
        }
        .contextMenu {
            let projects = Array(ProjectIndex.shared.recents.prefix(8))
            if item.url != nil {
                Menu("Move to Project as a Card") {
                    ForEach(projects) { p in Button(ProjectCodes.display(p.name)) { Spaces.shared.send(item.id, in: spaceID, as: .card, to: (p.projectKey, p.name)) } }
                }
                Menu("Add to Project’s Links") {
                    ForEach(projects) { p in Button(ProjectCodes.display(p.name)) { Spaces.shared.send(item.id, in: spaceID, as: .link, to: (p.projectKey, p.name)) } }
                }
                Menu("Make a Task in Project") {
                    ForEach(projects) { p in Button(ProjectCodes.display(p.name)) { Spaces.shared.send(item.id, in: spaceID, as: .task, to: (p.projectKey, p.name)) } }
                }
            }
        }
    }
}

private struct SpaceDockRow: View {
    let item: SpaceDockCard.Item
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            SpaceRowGlyph(host: item.host, symbol: item.symbol, title: item.title, size: 16)
            Text(item.title).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 4)
            if item.playing {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityLabel("Playing")
            }
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: tap)
        .padding(.horizontal, 4)
    }
}
