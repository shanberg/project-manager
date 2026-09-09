import SwiftUI
import UniformTypeIdentifiers

/// One tab, as the bar needs to draw it. A view model rather than a `ProjectTab`, because the name of
/// a tab pinned to a frame is the frame's label — a fact about the board's document, which the header
/// has no business reaching into.
struct ProjectTabItem: Identifiable, Equatable {
    let id: String
    /// What the chip says, and the whole of what it says. Short: the project's name is in the pill
    /// immediately to the left, so a tab only has to name which *view* it is.
    ///
    /// A chip used to carry a glyph and a "6/43" badge either side of this. The glyph told a frame
    /// called "Research" apart from a workspace called "Research" — a collision that is rare, that the
    /// chip's own menu resolves, and that cost every chip in the row a symbol to guard against. The
    /// badge said how many cards were tiled, which the board underneath is already showing you at full
    /// size. Both were true and neither was needed, and a row of tabs is read at a glance or not at all.
    let name: String
    /// Whether this tab is showing a workspace — named or not. What the chip hangs the workspace's own
    /// commands off, and what makes its label editable: a board you tiled is in a workspace whether or
    /// not you have named it yet.
    var isWorkspace = false
    /// The name of that workspace, or nil for the unnamed one. See `WorkspaceCommands`.
    var workspaceName: String?
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
/// **Built from the header's own parts**, and very nearly the renderer switch this replaced: positions
/// in a row, the current one lifted onto a soft backing that slides between them. That switch had two
/// positions and named a project's two faces; this has as many as you have opened and names them all,
/// which is what a project turned out to have instead of two faces.
struct ProjectTabBar<AddMenu: View>: View {
    let items: [ProjectTabItem]
    let selectedID: String
    let chrome: HeaderChrome
    var select: (String) -> Void
    var close: (String) -> Void
    /// Put a tab at an index — a drag along the row. See `TabReorder`.
    var move: (String, Int) -> Void
    var leaveTiling: () -> Void
    /// The workspace verbs, on the chip of the workspace they act on — see `WorkspaceCommands`.
    var nameWorkspace: (String) -> Void
    var renameWorkspace: (String) -> Void
    var duplicateWorkspace: (String) -> Void
    var deleteWorkspace: (String) -> Void
    /// A label edited in place, by tab id and the typed name. Naming or renaming, depending on what the
    /// chip was — see `ProjectSplitViewController.renameTab`.
    var renameTab: (String, String) -> Void
    @ViewBuilder var addMenu: () -> AddMenu

    /// The chip under the pointer, which is the only one that offers its close button. A row of tabs
    /// each carrying a permanent × is a row of things to click by accident.
    @State private var hovering: String?
    /// The chip being dragged along the row, if one is.
    @State private var dragging: String?
    /// The chip whose label is being typed into, if one is.
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
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
        return Group {
            if editing == item.id {
                // Not inside the button while the field is up: a `Button` swallows the clicks that
                // would put the caret where you aimed it, and dragging the chip you are editing is not
                // a gesture anybody means.
                content(item, current: current, showsClose: false)
            } else {
                Button { select(item.id) } label: {
                    content(item, current: current, showsClose: showsClose)
                }
                .buttonStyle(.plain)
                // **Rename where the name is.** Double-clicking a label to edit it is what the Finder,
                // the sidebar and every tab bar with names in it do, and under
                // docs/canvas-workspaces.md §7c the chip *is* the workspace — so this is the shortest
                // path to the one verb you reach for most. The menu keeps its item: a rename you can
                // only reach by knowing to try is not discoverable.
                //
                // Only the tab you are in, and only a workspace. A double-click on a background chip
                // is a click that arrived at a tab you had not switched to yet, and the tabs that are
                // not workspaces are named after what they show rather than by you.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard current, item.isWorkspace else { return }
                    beginEditing(item)
                })
                .onDrag {
                    dragging = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
            }
        }
        .onDrop(of: [.text],
                delegate: TabReorder(target: item, items: items, dragging: $dragging, move: move))
        // **A workspace's commands live on the workspace.** Right-click is where a Mac keeps the verbs
        // for the thing under the pointer, and it keeps them off the board's tile menu, which is for
        // what you do to a tile — docs/canvas-workspaces.md §7c. Offered on every workspace chip and
        // not only the current one: renaming the one you are not looking at is a fair thing to want,
        // and the chip is the only place it is named.
        .contextMenu {
            if item.isWorkspace {
                WorkspaceCommands(name: item.workspaceName,
                                  nameIt: { nameWorkspace(item.id) },
                                  rename: { item.workspaceName.map(renameWorkspace) },
                                  duplicate: { item.workspaceName.map(duplicateWorkspace) },
                                  delete: { item.workspaceName.map(deleteWorkspace) })
                Divider()
                // The way out of the tiled view, which the chip's badge used to carry as a ✕ and which
                // the pill only carries while there is no bar. On the current tab alone: `leaveTiling`
                // acts on the board that is up, so on any other chip it would untile something you
                // cannot see.
                if current {
                    Button("Leave Tiled View", action: leaveTiling)
                }
            }
            Button("Close Tab") { close(item.id) }.disabled(items.count == 1)
        }
        .onHover { hovering = $0 ? item.id : (hovering == item.id ? nil : hovering) }
        // **The current tab holds its name longest.** When the row has to give something up, the chips
        // you are not looking at give it up first; a row where every name shortens together is a row
        // where the one you are in has stopped saying which it is. On the chip rather than inside the
        // button's label, because this is the child of the bar's own row and only a child of that row
        // has any say in how it is shared.
        .layoutPriority(current ? 1 : 0)
        .help(item.name)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    private func content(_ item: ProjectTabItem, current: Bool, showsClose: Bool) -> some View {
        HStack(spacing: 4) {
            if editing == item.id {
                editor(item)
            } else {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        // **A chip is as wide as its name.** There used to be a flat 168pt ceiling here, which
        // truncated "Detective Depictions" in a window with room for three more of it — a cap that
        // fired on the name's length rather than on the room available, which is the one thing a cap
        // in a header should never do. The room is what decides now: the bar sizes to its contents and
        // is squeezed against the trailing controls when there is not enough (see
        // `CanvasPaneController`, where it is the thing that gives way), and only then does a label
        // truncate.
        //
        // The current tab holds its name longest — see the layout priority on `chip`.
        .contentShape(Rectangle())
        .background {
            if current {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary)
                    .matchedGeometryEffect(id: "backing", in: backing)
            }
        }
    }

    /// The label, while it is being typed into.
    ///
    /// Return commits and Escape abandons, and so does clicking away — committing, because that is what
    /// an editable label on this Mac does and because the alternative is losing what you typed to a
    /// click you did not mean as a decision.
    private func editor(_ item: ProjectTabItem) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.caption)
            .focused($editorFocused)
            .frame(minWidth: 56)
            .onSubmit { endEditing(item, keeping: true) }
            .onExitCommand { endEditing(item, keeping: false) }
            .onChange(of: editorFocused) { _, focused in
                if !focused { endEditing(item, keeping: true) }
            }
    }

    private func beginEditing(_ item: ProjectTabItem) {
        draft = item.workspaceName ?? ""
        editing = item.id
        editorFocused = true
    }

    /// Guarded on `editing`, because ending an edit blurs the field and the blur would otherwise end it
    /// a second time — which after Escape would commit the thing Escape just refused.
    private func endEditing(_ item: ProjectTabItem, keeping: Bool) {
        guard editing == item.id else { return }
        editing = nil
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keeping, !name.isEmpty, name != item.workspaceName else { return }
        renameTab(item.id, name)
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

/// Dragging a chip along the row, which is how a row of tabs gets an order that is yours.
///
/// The move happens as the drag crosses a chip rather than when it is let go, so the row shows the
/// order you are making instead of promising it with an insertion line — `ProjectTabSet.move` is
/// already "that one goes *there*", and the bar's own animation carries it across.
private struct TabReorder: DropDelegate {
    let target: ProjectTabItem
    let items: [ProjectTabItem]
    @Binding var dragging: String?
    var move: (String, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id,
              let to = items.firstIndex(where: { $0.id == target.id })
        else { return }
        move(dragging, to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    /// Nothing is read out of the drop: the row was reordered on the way in, and the id it carries was
    /// only ever how a chip says which one it is.
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// What the two headers watch so the bar is the same bar in both.
///
/// The bar has to render in the task column's header *and* in the board's, in the same place: a control
/// that jumps from one end of the window to the other as you use it is not one control. Those are two
/// separate view hierarchies — one SwiftUI, one a hosting view
/// over an AppKit board — so what they share is this, one per window, owned by the split controller.
@MainActor
final class ProjectTabModel: ObservableObject {
    @Published var items: [ProjectTabItem] = []
    @Published var selectedID: String = ""
    /// Frames and workspaces the board could open in a tab, for the add menu. Empty while the window
    /// is showing something that isn't a board, and empty for a board that has neither.
    @Published var frames: [ProjectTabItem] = []
    @Published var workspaces: [String] = []

    /// One tab is no tabs — see `ProjectTabSet.showsBar`.
    var showsBar: Bool { items.count > 1 }

    var select: (String) -> Void = { _ in }
    var close: (String) -> Void = { _ in }
    /// Put a tab at an index — the drag along the bar.
    var move: (String, Int) -> Void = { _, _ in }
    var openNotes: () -> Void = {}
    var openBoard: () -> Void = {}
    var openFrame: (String) -> Void = { _ in }
    var openWorkspace: (String) -> Void = { _ in }
    /// The workspace verbs — see `WorkspaceCommands`. By **name**, because a workspace is the same
    /// workspace whichever chip you reached it from and the window has to find every chip on it either
    /// way. Naming is the exception and goes by tab id: an unnamed workspace has no name to route by,
    /// and it is the pane holding it that knows the tiling being named.
    var nameWorkspace: (String) -> Void = { _ in }
    var renameWorkspace: (String) -> Void = { _ in }
    var duplicateWorkspace: (String) -> Void = { _ in }
    var deleteWorkspace: (String) -> Void = { _ in }
    /// A chip's label, typed rather than picked. By tab id, because it covers both naming and renaming
    /// and only the tab knows which it was.
    var renameTab: (String, String) -> Void = { _, _ in }
    /// Go to the tab already showing this workspace, and say whether there was one.
    var selectWorkspace: (String) -> Bool = { _ in false }
    /// Leave the tiled view on the board the current tab is showing — the item on its chip's menu.
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
                          move: model.move,
                          leaveTiling: model.leaveTiling,
                          nameWorkspace: model.nameWorkspace,
                          renameWorkspace: model.renameWorkspace,
                          duplicateWorkspace: model.duplicateWorkspace,
                          deleteWorkspace: model.deleteWorkspace,
                          renameTab: model.renameTab,
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
            if !model.workspaces.isEmpty {
                Section("Workspaces") {
                    ForEach(model.workspaces, id: \.self) { name in
                        Button(name) { model.openWorkspace(name) }
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

/// The verbs on a workspace, wherever one is shown.
///
/// **Written once because there are two places to show it and one of them is a stand-in.** A chip is a
/// workspace's home in the window (docs/canvas-workspaces.md §7c) — but one tab is no tabs, so a window
/// showing a single board has no bar and no chip, and the title pill's readout carries the same menu
/// until a second tab makes the bar appear. That is the handoff the readout itself already makes; these
/// items follow it rather than being written out twice.
///
/// **Name and Rename are one item**, for the reason `CanvasBoardView.saveTilingAsWorkspace` gives: a
/// workspace that has a name cannot be named again, and letting Name run on a named one would leave the
/// old one behind and put you in a second — a duplicate arrived at by picking the wrong item. Duplicate
/// is right below it, asked for on purpose.
struct WorkspaceCommands: View {
    /// The workspace's name, or nil for an unnamed one — which has nothing to duplicate or delete,
    /// because there is nothing kept to make a copy of or to forget.
    let name: String?
    var nameIt: () -> Void
    var rename: () -> Void
    var duplicate: () -> Void
    var delete: () -> Void

    var body: some View {
        if let name {
            Button("Rename “\(name)”…", action: rename)
            Button("Duplicate “\(name)”…", action: duplicate)
            Divider()
            Button("Delete “\(name)”", action: delete)
        } else {
            Button("Name This Workspace…", action: nameIt)
        }
    }
}
