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
    /// A chip used to carry a glyph and a "6/43" badge either side of this, and then — for the one
    /// kind of chip that had no name of its own — a count after it. All three are gone. The glyph told
    /// a frame called "Research" apart from a workspace called "Research", a collision that is rare and
    /// that the chip's own menu resolves. The badge and the count said how many cards were tiled, which
    /// the board underneath is showing you at full size. A row of tabs is read at a glance or not at
    /// all, and none of the three survived being read at a glance.
    let name: String
    /// The workspace this chip is, or nil for the three chips that are not one.
    ///
    /// **Not a flag and a name any more.** There used to be an `isWorkspace` beside this for the chips
    /// that were a workspace without being a named one; every workspace has a name now
    /// (docs/canvas-workspaces.md §7i), so the name is the test.
    var workspaceName: String?
    /// The canvas — drawn as a glyph and nothing else, because it is the one tab that is not a name.
    ///
    /// It is always the first chip, it never closes, and it does not move. What it shows is the board
    /// every other chip is a narrowing of, so a word for it would be a word for "here", said in a row
    /// whose whole job is to say which of several places you are in.
    var isCanvas = false
    /// Whether this chip offers a Close at all. False for the canvas and for every workspace — see
    /// `ProjectTabSet.close`.
    var closable = true
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
    /// The workspace verbs, on the chip of the workspace they act on — see `WorkspaceCommands`.
    var renameWorkspace: (String) -> Void
    var duplicateWorkspace: (String) -> Void
    var deleteWorkspace: (String) -> Void
    /// A label edited in place, by tab id and the typed name. Naming or renaming, depending on what the
    /// chip was — see `ProjectSplitViewController.renameTab`.
    var renameTab: (String, String) -> Void
    @ViewBuilder var addMenu: () -> AddMenu

    /// The chip under the pointer, which is the only one that offers its close button. A row of tabs
    /// each carrying a permanent × is a row of things to click by accident — **the current one
    /// included**, which it was not. The chip you are working in is the one your pointer is nearest and
    /// the one whose ✕ costs the most to hit, and it was the only chip wearing one at all times.
    @State private var hovering: String?
    /// The row's width with nothing squeezing it, once it has been measured. See `TabRowWidthKey`.
    @State private var naturalWidth: CGFloat?
    /// The chip being dragged along the row, if one is.
    @State private var dragging: String?
    /// The chip whose label is being typed into, if one is.
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @Namespace private var backing

    var body: some View {
        HeaderCapsule(chrome: chrome) {
            // Nothing but the "+" while the window has one tab. One tab is still no tabs — a chip
            // saying "1 of 1" reports nothing — but the *way to get a second* is not nothing, and it
            // was the one thing this control hid: at one tab the bar drew itself away entirely, taking
            // the only visible offer of another view with it.
            if !items.isEmpty {
                row
                HeaderGap()
            }
            addMenu()
        }
        .animation(Motion.animation(.snappy(duration: 0.2)), value: selectedID)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: items)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(items.isEmpty ? "New Tab" : "Tabs"))
    }

    /// The chips, which **scroll** once the window has run out of room for them.
    ///
    /// A row of names was the right answer for the handful of tabs you had opened, and §7g changed how
    /// many that is: the row now seeds a chip for every workspace the board has, so a project with
    /// eight of them arrives with eight chips and no gesture involved. The bar is the header's designated
    /// give-way (`CanvasPaneController` sets that priority), so what "give way" meant in a plain
    /// `HStack` was every name shortening to a sliver at once — a row of tabs read at a glance, with
    /// nothing left to read.
    ///
    /// So the bar keeps its size — it is still exactly as wide as its chips, `naturalWidth` being what
    /// they measure — and gives way by *clipping* rather than by squeezing, with the overflow one
    /// scroll away. A chip is as wide as its name again, and now it stays that way at any count.
    ///
    /// The selection is scrolled to, because a tab you switched to with ⌃⇥ that stayed off the end of
    /// the row would be a switch you have to go looking for.
    private var row: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: HeaderMetrics.gap) {
                    ForEach(items) { item in
                        chip(item)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TabRowWidthKey.self, value: geometry.size.width)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Its own height rather than the row's, which inside a scroll view has nothing to take one
            // from — and the chips are all exactly this tall by construction.
            .frame(height: HeaderMetrics.itemHeight)
            // Never wider than the chips it holds, so a bar with two of them is still two chips wide
            // and not a strip across the window. Narrower is the window's decision, and the only one
            // that puts this into scrolling at all.
            .frame(idealWidth: naturalWidth, maxWidth: naturalWidth)
            .onPreferenceChange(TabRowWidthKey.self) { width in
                naturalWidth = width > 0 ? width : nil
            }
            .onChange(of: selectedID) { _, id in
                withAnimation(Motion.animation(.snappy(duration: 0.2))) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
        }
    }

    private func chip(_ item: ProjectTabItem) -> some View {
        let current = item.id == selectedID
        let showsClose = item.closable && hovering == item.id
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
                    guard current, item.workspaceName != nil else { return }
                    beginEditing(item)
                })
                // The canvas does not travel — see `ProjectTabSet.move`.
                .onDrag(if: !item.isCanvas) {
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
        .contextMenu { menu(item) }
        .onHover { hovering = $0 ? item.id : (hovering == item.id ? nil : hovering) }
        // A layout priority used to sit here, so that the chips you were not looking at gave up their
        // names before the one you were. It is gone with the thing it was rationing: inside a scrolling
        // row no chip gives anything up, and the current one is scrolled to instead of being the last
        // one still legible. See `row`.
        .help(item.name)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    /// What right-clicking a chip offers, which is decided by what kind of tab it is.
    ///
    /// **Delete is where Close used to be**, on a workspace chip, and it is the only item there that
    /// takes anything away. A workspace is its chip (§7i), so there is no close that would leave the
    /// workspace anywhere — the row would simply put the chip back. What people mean by closing one is
    /// either "show me the board", which is the canvas chip a click to the left, or "I am done with
    /// this", which is Delete and asks first (`WorkspaceNamePrompt.confirmDelete`).
    @ViewBuilder private func menu(_ item: ProjectTabItem) -> some View {
        if let name = item.workspaceName {
            WorkspaceCommands(name: name,
                              rename: { renameWorkspace(name) },
                              duplicate: { duplicateWorkspace(name) },
                              delete: { deleteWorkspace(name) })
        } else if item.closable {
            Button("Close Tab") { close(item.id) }
        }
    }

    private func content(_ item: ProjectTabItem, current: Bool, showsClose: Bool) -> some View {
        HStack(spacing: 4) {
            if item.isCanvas {
                // The one chip that is a glyph. Scattered rectangles rather than a grid of them,
                // deliberately: the grid is `rectangle.split.2x2`, which is the button that *tiles*,
                // and the canvas is what a tiling is a narrowing of.
                Image(systemName: "rectangle.3.offgrid")
                    .font(.system(size: HeaderMetrics.iconSize - 1, weight: .medium))
            } else if editing == item.id {
                editor(item)
            } else {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Held rather than inserted, so the name doesn't shift sideways when the pointer arrives —
            // a tab that re-lays-out under the cursor is a tab you misclick. Only on the chips that
            // have a Close at all, which is why the workspaces in this row are as wide as their names
            // and not their names plus a gap for a control they never wear.
            if item.closable {
                closeButton(item)
                    .opacity(showsClose ? 1 : 0)
                    .allowsHitTesting(showsClose)
            }
        }
        .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, HeaderMetrics.textInset)
        .frame(height: HeaderMetrics.itemHeight)
        // **A chip is as wide as its name** — all of it, at any count. There used to be a flat 168pt
        // ceiling here, which truncated "Detective Depictions" in a window with room for three more of
        // it: a cap firing on the name's length rather than on the room available. Removing it left the
        // room deciding, which was right until §7g made the row long enough that the room decided
        // against every chip at once. Now the room decides how much of the *row* you can see and never
        // how much of a name — see `row`.
        .contentShape(Rectangle())
        .background {
            if current {
                // A capsule inside a capsule, at the strength it takes to be seen through glass. This
                // was a 5pt rounded rectangle filled `.quaternary` — the faintest fill SwiftUI has,
                // over a material, with a corner radius that shared nothing with the shape around it.
                Capsule()
                    .fill(.primary.opacity(0.09))
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
        draft = item.workspaceName ?? item.name
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

/// How wide the chips are with nothing squeezing them — what `ProjectTabBar.row` caps itself at.
///
/// `max` rather than this codebase's usual optional-and-`??`: two subtrees report into this key, the
/// measuring background and the row itself, and the row contributes the default. A width is positive
/// and zero is a meaningful floor, so the larger of the two is always the measured one — which is the
/// carve-out the rule against `value = nextValue()` names. Never spell that one here.
private struct TabRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// The frames the board could open in a tab, for the add menu. Empty while the window is showing
    /// something that isn't a board, and empty for a board with no frames on it. The workspaces used to
    /// be listed beside them and are not: every one of them has a chip (§7i), so offering to open one
    /// would be offering to open what is open.
    @Published var frames: [ProjectTabItem] = []

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
    /// Go to the canvas — what leaving a tiled view means now that the canvas is a tab of its own. The
    /// workspace is untouched and its chip is still where it was; you are simply looking at the board.
    var goToCanvas: () -> Void = {}
    /// ⌘↩ on a board that is not tiled: keep this tiling as a workspace and open its tab. False when
    /// the window could not — see `ProjectSplitViewController.tileAsWorkspace`.
    var tileAsWorkspace: (CanvasViewState.Tiling) -> Bool = { _ in false }
}

/// The bar as both headers put it on screen: the window's tabs, and the menu that adds one.
///
/// **No chips while the window has a single tab, and always the "+".** One tab is no tabs — the window
/// this app has always had — and a chip reporting "1 of 1" beside it is chrome with nothing to say.
/// That was taken one step too far: the whole control went away with the chips, so a window with one
/// tab offered nothing at all that said another view was possible. The two ways in it was documented as
/// leaving that job to were File ▸ New Tab, which is in a menu nobody opens to discover a feature, and
/// "Open in New Tab" on a frame, which had no menu item at all — `openSelectedFrameInTab` sat in this
/// app with zero callers for as long as it had existed. Both are real now; so is the "+".
struct ProjectTabBarHost: View {
    @ObservedObject var model: ProjectTabModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    var body: some View {
        ProjectTabBar(items: model.showsBar ? model.items : [],
                      selectedID: model.selectedID,
                      chrome: HeaderChrome(active: controlActiveState, hovering: hovering),
                      select: model.select,
                      close: model.close,
                      move: model.move,
                      renameWorkspace: model.renameWorkspace,
                      duplicateWorkspace: model.duplicateWorkspace,
                      deleteWorkspace: model.deleteWorkspace,
                      renameTab: model.renameTab,
                      addMenu: { addMenu })
            .onHover { hovering = $0 }
    }

    /// What "+" offers, which is **the two things that do not have a chip already**.
    ///
    /// The canvas has a permanent one and every workspace has one (docs/canvas-workspaces.md §7i), so
    /// listing either here would be offering to open what is open — a menu whose items all mean
    /// "switch", which is what the row beside it is for. What is left is the project's notes and the
    /// frames on the board, both of which are places you can be that only become a tab by asking.
    private var addMenu: some View {
        Menu {
            Button("Notes", action: model.openNotes)
            if !model.frames.isEmpty {
                Section("Frames") {
                    ForEach(model.frames) { frame in
                        Button(frame.name) { model.openFrame(frame.id) }
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
/// workspace's home in the window (docs/canvas-workspaces.md §7c) — the board's own contextual menu
/// carries the same three items for the workspace that is up, so that the verbs are also where the
/// tiles are.
///
/// **There is no "Name This Workspace…" here any more**, and its absence is the whole of §7i in one
/// menu: a workspace is made named, so there is never one sitting in front of you waiting to be given a
/// name. What that item did — turn the thing you are looking at into a keepable object — is now done by
/// the act that made it, and what is left of it is Rename.
struct WorkspaceCommands: View {
    let name: String
    var rename: () -> Void
    var duplicate: () -> Void
    var delete: () -> Void

    var body: some View {
        Button("Rename “\(name)”…", action: rename)
        Button("Duplicate “\(name)”…", action: duplicate)
        Divider()
        Button("Delete “\(name)”", action: delete)
    }
}

extension View {
    /// `onDrag`, or nothing — for the one chip in the row that does not travel.
    @ViewBuilder
    func onDrag(if enabled: Bool, _ data: @escaping () -> NSItemProvider) -> some View {
        if enabled {
            onDrag(data)
        } else {
            self
        }
    }
}
