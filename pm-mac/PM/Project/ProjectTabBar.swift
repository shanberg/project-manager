import SwiftUI

/// One tab, as the bar needs to draw it. A view model rather than a `ProjectTab`, because the name of
/// a tab pinned to a frame is the frame's label — a fact about the board's document, which the header
/// has no business reaching into.
struct ProjectTabItem: Identifiable, Equatable {
    let id: String
    /// What the chip says. Short: the project's name is in the pill immediately to the left, so a
    /// tab only has to say which *view* it is.
    let name: String
    /// What kind of view it is, which is what lets the name stay short — a frame called "Research"
    /// and an arrangement called "Research" are told apart by the glyph rather than by a prefix.
    let symbol: String
    /// A state of *this* view, after its name — "6/43" while it is tiled.
    ///
    /// This used to be the title pill's, and the pill's argument for it was sound while a window showed
    /// one thing: the pill answers "what am I looking at", and "6 of 43 cards" is precisely an answer
    /// to that. With tabs the pill is answering it for the window and the fact belongs to one tab —
    /// tile a board in one tab and the pill would report it over the top of a tab showing the notes.
    /// So the tab wears it, and the pill stops (see `CanvasHeaderModel.showsTilingSummary`).
    var detail: String?
}

/// A project window's tabs, as a capsule in the header band beside the title pill.
///
/// **Not a strip.** Every other Mac app puts tabs in a bar across the window, and this one cannot: the
/// header's whole design is a pill at the leading edge and the controls at the trailing one with
/// nothing in between, because a view spanning the window hit-tests its whole width and swallows every
/// click in the top of the content — which on a board is the cards up there. So the tabs are a third
/// floating island in the same band, sized to their own contents, with the same glass and the same
/// hover as the two either side of them. See `CanvasHeader`.
///
/// **Built from the header's own parts**, the way `RendererSwitch` is — and it is very nearly that
/// control with the count taken off: positions in a row, the current one lifted onto a soft backing
/// that slides between them. That is not a coincidence worth hiding. A window with one tab still shows
/// the switch and no bar; a window with several shows this, and the two should look like the same idea
/// at two sizes, because they are.
struct ProjectTabBar<AddMenu: View>: View {
    let items: [ProjectTabItem]
    let selectedID: String
    let chrome: HeaderChrome
    var select: (String) -> Void
    var close: (String) -> Void
    var leaveTiling: () -> Void
    @ViewBuilder var addMenu: () -> AddMenu

    /// The chip under the pointer, which is the only one that offers its close button. A row of tabs
    /// each carrying a permanent × is a row of things to click by accident.
    @State private var hovering: String?
    @Namespace private var backing

    var body: some View {
        HeaderCapsule(chrome: chrome) {
            ForEach(items) { item in
                chip(item)
            }
            HeaderGap()
            addMenu()
        }
        .animation(Motion.animation(.snappy(duration: 0.2)), value: selectedID)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: items)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tabs"))
    }

    private func chip(_ item: ProjectTabItem) -> some View {
        let current = item.id == selectedID
        let showsClose = items.count > 1 && (current || hovering == item.id)
        return Button { select(item.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: HeaderMetrics.iconSize - 1, weight: .medium))
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = item.detail {
                    detailBadge(detail, on: current)
                }
                // Held rather than inserted, so the name doesn't shift sideways when the pointer
                // arrives. A tab that re-lays-out under the cursor is a tab you misclick.
                closeButton(item)
                    .opacity(showsClose ? 1 : 0)
                    .allowsHitTesting(showsClose)
            }
            .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, HeaderMetrics.textInset)
            .frame(height: HeaderMetrics.itemHeight)
            .frame(maxWidth: 168)
            .contentShape(Rectangle())
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                        .matchedGeometryEffect(id: "backing", in: backing)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? item.id : (hovering == item.id ? nil : hovering) }
        .help(item.name)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    /// The tiled readout, and on the tab you are in, the way out of it.
    ///
    /// A click on the badge leaves the tiled view — the ✕ the pill used to carry, in the one place that
    /// can still hold it. It cannot be a second ✕ beside the close-tab one: two crosses on one chip
    /// meaning "leave this state" and "close this tab" is a misclick that costs you the tab. A filter
    /// token you click to clear is the other idiom for exactly this, and it is the one with room here.
    ///
    /// Only on the current tab. A background tab's readout is a fact about a board you are not looking
    /// at, and untiling one from across the bar is an action with no visible result.
    @ViewBuilder
    private func detailBadge(_ detail: String, on current: Bool) -> some View {
        let text = Text(detail)
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            // Ahead of the name in the queue for space: a truncated "6/4…" says nothing, while a
            // truncated name still names the tab.
            .layoutPriority(1)
        if current {
            Button(action: leaveTiling) {
                text.foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave the tiled view")
            .accessibilityLabel(Text("Tiled, " + detail))
            .accessibilityHint(Text("Leave the tiled view"))
        } else {
            text.foregroundStyle(.tertiary)
        }
    }

    private func closeButton(_ item: ProjectTabItem) -> some View {
        Button { close(item.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: HeaderMetrics.iconSize - 3, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Tab")
        .accessibilityLabel(Text("Close " + item.name))
    }
}

/// What the two headers watch so the bar is the same bar in both.
///
/// The bar has to render in the task column's header *and* in the board's, in the same place, for the
/// reason `RendererSwitch` gives: a control that jumps from one end of the window to the other as you
/// use it is not one control. Those are two separate view hierarchies — one SwiftUI, one a hosting view
/// over an AppKit board — so what they share is this, one per window, owned by the split controller.
@MainActor
final class ProjectTabModel: ObservableObject {
    @Published var items: [ProjectTabItem] = []
    @Published var selectedID: String = ""
    /// Frames and arrangements the board could open in a tab, for the add menu. Empty while the window
    /// is showing something that isn't a board, and empty for a board that has neither.
    @Published var frames: [ProjectTabItem] = []
    @Published var arrangements: [String] = []

    /// One tab is no tabs — see `ProjectTabSet.showsBar`.
    var showsBar: Bool { items.count > 1 }

    var select: (String) -> Void = { _ in }
    var close: (String) -> Void = { _ in }
    var openNotes: () -> Void = {}
    var openBoard: () -> Void = {}
    var openFrame: (String) -> Void = { _ in }
    var openArrangement: (String) -> Void = { _ in }
    /// Leave the tiled view on the board the current tab is showing — the badge on its chip.
    var leaveTiling: () -> Void = {}
}

/// The bar as both headers put it on screen: the window's tabs, and the menu that adds one.
///
/// Nothing at all while the window has a single tab. One tab is no tabs — the window this app has
/// always had — and a bar reporting "1 of 1" above it is chrome with nothing to say. Getting the second
/// tab is therefore not this control's job: it is View ▸ New Tab, and Open in New Tab on a frame.
struct ProjectTabBarHost: View {
    @ObservedObject var model: ProjectTabModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    var body: some View {
        if model.showsBar {
            ProjectTabBar(items: model.items,
                          selectedID: model.selectedID,
                          chrome: HeaderChrome(active: controlActiveState, hovering: hovering),
                          select: model.select,
                          close: model.close,
                          leaveTiling: model.leaveTiling,
                          addMenu: { addMenu })
                .onHover { hovering = $0 }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Notes", action: model.openNotes)
            Button("Canvas", action: model.openBoard)
            if !model.frames.isEmpty {
                Section("Frames") {
                    ForEach(model.frames) { frame in
                        Button(frame.name) { model.openFrame(frame.id) }
                    }
                }
            }
            if !model.arrangements.isEmpty {
                Section("Arrangements") {
                    ForEach(model.arrangements, id: \.self) { name in
                        Button(name) { model.openArrangement(name) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New Tab")
        .accessibilityLabel(Text("New Tab"))
    }
}
