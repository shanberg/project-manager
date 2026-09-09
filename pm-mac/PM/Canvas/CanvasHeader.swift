import AppKit
import SwiftUI

/// A board's chrome: a pill naming it at the leading edge, the controls at the trailing one, and nothing
/// at all in between.
///
/// This replaces an `NSToolbar` carrying a View/Edit segmented control, an Add pull-down, a search
/// field and — while a web card was engaged — four browser buttons. All of it was permanently occupying
/// a band across the top of every board, and a board wants that band: it is where the cards you are
/// reading are.
///
/// The shape is the project window's, deliberately and to the letter — same `HeaderChrome` states, same
/// material, same measured clearance under the traffic lights. A canvas is a document window in the same
/// app and should not be a second idea of what a window looks like.
///
/// **Views that hug their contents rather than one strip**, and that is what makes the band usable. A
/// single header view spanning the window would hit-test its whole width and swallow every click in the
/// top 48 points of the board — including on the cards up there. A pill at one end and the capsules at
/// the other leave the space between them as what it looks like: board.
@MainActor
final class CanvasHeaderModel: ObservableObject {
    /// The board's name — the canvas file, without its extension.
    @Published var title = ""
    @Published var mode: CanvasMode = .view
    /// The web card you have stepped into, if any.
    @Published var page: Page?
    @Published var find = Find()
    /// Bumped by ⌘L to put the keyboard in the address field with the address selected, the way a
    /// browser does. A token rather than a flag, for the reason `Find.focusToken` is one: pressing it
    /// again while the field is already open has to mean something.
    @Published var addressFocusToken = 0
    /// What a tiled view is showing, long and short — "6 of 43 cards" and "6/43". Nil when the board is
    /// showing itself.
    ///
    /// It has to say something. A board showing six of forty-three cards, with the rest hidden and the
    /// lines between them gone, looks exactly like a board most of which has been deleted — and the
    /// moment you think that is the moment you stop trusting the feature.
    @Published var tiling: (long: String, short: String)?
    /// The name of the workspace that is up, or nil while it is an unnamed one.
    ///
    /// **What the readout says instead of the count, when there is one.** The two never compete: the
    /// count answers "how much of the board am I seeing", which matters most immediately after an ad-hoc
    /// ⌘Return — exactly when there is no name — so the readout ends up saying which *kind* of workspace
    /// you are in by which of the two it is showing. The count is still in the tooltip.
    @Published var workspace: String?
    /// Every named workspace on this board, for the readout's menu.
    @Published var workspaces: [String] = []
    /// What ⌘Return would do to the board as it stands — the same sentence the View menu and the
    /// contextual menu use. See `CanvasTiling.commandTitle`.
    ///
    /// Published rather than asked for on demand because it depends on the selection, and the button
    /// that carries it has a tooltip that has to be right before you click rather than after.
    /// Defaulted to the empty-selection wording rather than a placeholder, because that is the true
    /// answer for a board nobody has clicked yet — the state this starts in.
    @Published var tileTitle = "Fill Window with Visible Cards"
    /// The arrangement in force, or nil when the board is showing itself.
    @Published var arrangement: CanvasTiling.Arrangement?
    @Published var titlebar = TitlebarButtonMetrics.unmeasured
    /// How much of the window the controls can spend. See `CanvasHeaderModel.Room`.
    @Published var room = Room.full

    /// How much room the header's controls have, and therefore what they can afford to say.
    ///
    /// The trailing chrome grew: a page capsule holding an address and up to five buttons, then the
    /// board's own capsule with a find field, the word "Connecting", and four controls. All of that at
    /// once on a narrow window runs into the title pill, and the pill is the piece that gives way — so
    /// the window ends up naming the board it is showing with two letters and an ellipsis.
    ///
    /// The fix is an order of precedence rather than more space: state you are *in* outlasts state you
    /// can *read elsewhere*. The page and the find field are things you asked for a moment ago and are
    /// acting on now. So the mode label goes first, and the address field narrows rather than leaving —
    /// an address bar with no address in it is not an address bar, and it is the only place a card can
    /// tell you whose password field you are looking at. What never goes: the renderer switch, Add, and
    /// the options menu.
    ///
    /// The tiled count is measured here too, but it isn't in the control capsule any more — it belongs
    /// to the pill, which is where "what am I looking at" is answered. It shortens to a bare fraction
    /// rather than leaving, because the pill has a title to compress before it needs to drop anything.
    ///
    /// Breakpoints on the window rather than a fitting pass, because the chrome is in a hosting view
    /// sized to its own contents and would report that it fits at any width. Deliberate numbers beat a
    /// measurement that cannot fail.
    enum Room {
        case full, tight, minimal

        init(width: CGFloat) {
            switch width {
            case 900...: self = .full
            case 680..<900: self = .tight
            default: self = .minimal
            }
        }

        var showsModeLabel: Bool { self == .full }
        /// How wide the address field is allowed to get. Enough for a real host at every width — a
        /// truncated middle still shows you the end of the domain, which is the half that matters.
        var addressWidth: CGFloat {
            switch self {
            case .full: return 240
            case .tight: return 150
            case .minimal: return 104
            }
        }
        var findWidth: CGFloat { self == .full ? 170 : 120 }
        /// The tiled readout in full ("6 of 43 cards") or short ("6/43").
        var showsLongTilingSummary: Bool { self == .full }
    }

    /// What the header knows about the one card whose page is live under your hands.
    ///
    /// The address is here rather than on the card because a card carries no chrome, and because this
    /// is the only card whose address can cost you anything: it is the one taking your clicks and your
    /// keystrokes. During a single sign-on you are handed between hosts, and a password field is only
    /// safe to type into if you can see whose it is — so the host is stated at full size, in the window
    /// frame, next to the controls that drive it, which is where a browser puts it too.
    struct Page: Equatable {
        var host: String
        /// Where the page actually is, in full — what the address field puts under your cursor when you
        /// click into it. The host is what it *shows*; a host is not something you can edit back into an
        /// address, so both are needed.
        var liveAddress: String
        /// The address written on the board, shown when the page has left it.
        var savedAddress: String
        var wandered: Bool
        var canGoBack: Bool
        var canGoForward: Bool
        /// Mid-navigation. Turns Reload into Stop, which is the only feedback a live page gives you
        /// that anything is happening at all — a card is drawn as its old page until the new one paints.
        var isLoading: Bool
        /// How old what you are looking at is, when the card knows.
        var age: String?
    }

    struct Find: Equatable {
        var isShowing = false
        var query = ""
        var summary = ""
        /// Bumped to pull the keyboard back into the field — a second ⌘F is "search again".
        var focusToken = 0
    }

    /// Whether this board is one face of a project window, and how to turn it over.
    ///
    /// Set when a project window is rendering its project as a board — and then the header carries the
    /// *same* `RendererSwitch` the task list's header carries, in the same place, so the control doesn't
    /// move when you use it.
    ///
    /// It was a lone button here and a different lone button there, each findable only once you were
    /// already on the other side of it and neither saying there was another side.
    @Published var showsRendererSwitch = false
    /// Whether the pill wears the tiled readout.
    ///
    /// Off in a window whose tab bar is showing, where the tab holding this board wears it instead —
    /// see `ProjectTabItem.detail`. One fact in one place: the pill speaks for the window, and with
    /// several tabs up "6 of 43 cards" is true of exactly one of them.
    @Published var showsTilingSummary = true
    /// Whether the `+` offers the project's own note — true only on a project's board that hasn't got
    /// it. Kept in step with the document by `CanvasPaneController.documentChanged`; the board owns the
    /// question (`CanvasBoardView.offersProjectNoteCard`).
    @Published var offersProjectNote = false
    var setRenderer: (ProjectRenderer) -> Void = { _ in }

    // MARK: What the controls do. Supplied by the window controller.

    var addCard: () -> Void = {}
    var addFrame: () -> Void = {}
    var addLink: () -> Void = {}
    var addFile: () -> Void = {}
    var addProjectNote: () -> Void = {}
    var setMode: (CanvasMode) -> Void = { _ in }
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var zoomActualSize: () -> Void = {}
    var pageBack: () -> Void = {}
    var pageForward: () -> Void = {}
    var pageReload: () -> Void = {}
    var pageStop: () -> Void = {}
    var pageHome: () -> Void = {}
    var pageAdoptAddress: () -> Void = {}
    /// Send the page to an address typed into the header's field. Navigation only — it does not touch
    /// what the board has saved for the card, which is what Pin is for.
    var pageGo: (String) -> Void = { _ in }
    var findChanged: (String) -> Void = { _ in }
    var findClosed: () -> Void = {}
    var findCommitted: () -> Void = {}
    var leaveTiling: () -> Void = {}
    var tile: () -> Void = {}
    var setArrangement: (CanvasTiling.Arrangement) -> Void = { _ in }
    var goToWorkspace: (String) -> Void = { _ in }
    var nameWorkspace: () -> Void = {}
    var renameWorkspace: () -> Void = {}
    var duplicateWorkspace: () -> Void = {}
    var deleteWorkspace: () -> Void = {}
}

// MARK: - The pill

/// What board you are looking at. The counterpart of the project window's project pill.
struct CanvasTitlePill: View {
    @ObservedObject var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var chrome: HeaderChrome { HeaderChrome(active: controlActiveState, hovering: hovering) }

    var body: some View {
        HStack(spacing: 6) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            // A tiled view is a state of the thing this pill names, so this is where it goes.
            //
            // It was a caption and a bordered "Done" button in the control capsule, where it was the
            // single worst-fitting thing in the row: a sentence and a bezelled button among borderless
            // glyphs. No amount of equal padding makes those siblings. The pill answers "what am I
            // looking at", and "6 of 43 cards" is precisely an answer to that — while the ✕ is the
            // Finder's own idiom for leaving a temporary, filtered state.
            if let tiling = model.tiling, model.showsTilingSummary {
                Text(verbatim: "·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                workspaceMenu(tiling)
                Button(action: model.leaveTiling) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Leave the tiled view")
                .accessibilityLabel(Text("Leave the tiled view"))
            }
        }
        .opacity(chrome.contentOpacity)
        .padding(.horizontal, HeaderMetrics.pillInset.horizontal)
        .padding(.vertical, HeaderMetrics.pillInset.vertical)
        .headerBacking(chrome, in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: model.tiling?.long)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: model.showsTilingSummary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(model.showsTilingSummary
            ? (model.tiling.map { "\(model.title), tiled, \(model.workspace ?? $0.long)" }
                ?? model.title)
            : model.title))
        .modifier(TitlebarDrop(model: model))
    }

    /// **The workspace, where the readout used to be.**
    ///
    /// This slot already answered "what am I looking at" for a tiled board, and a workspace is the
    /// honest answer to it — the count was what the pill said while the thing it was describing had no
    /// name to give. So a named workspace says its name, an unnamed one keeps the count, and the count
    /// is in the tooltip either way.
    ///
    /// A menu rather than a label, because the list belongs where the answer is: naming one is the only
    /// visible confirmation that naming did anything, and switching between them should not mean
    /// opening a tab. The ✕ beside it is already a control, so this region was interactive before this.
    @ViewBuilder private func workspaceMenu(_ tiling: (long: String, short: String)) -> some View {
        Menu {
            // The unnamed one is listed only while you are in it, ticked and inert: it is where you
            // are, and there is nowhere to go — an unnamed workspace is the one that is up or it is
            // nothing at all. Drawing it is how "ephemeral unless named" stops being merely true and
            // becomes something you can see, with the count beside it saying what it is made of.
            if model.workspace == nil {
                Toggle("Untitled · \(tiling.short)", isOn: .constant(true)).disabled(true)
            }
            if !model.workspaces.isEmpty {
                Divider()
                // Ticked where you are, so the list says where you are as well as where you could go.
                // Toggles rather than a Picker, following the arrangement options in this same header.
                ForEach(model.workspaces, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { name == model.workspace },
                                               set: { _ in model.goToWorkspace(name) }))
                }
            }
            Divider()
            // The same items a chip carries, because this *is* the chip until there is a bar to hold
            // one — see `WorkspaceCommands`.
            WorkspaceCommands(name: model.workspace,
                              nameIt: model.nameWorkspace,
                              rename: model.renameWorkspace,
                              duplicate: model.duplicateWorkspace,
                              delete: model.deleteWorkspace)
        } label: {
            Text(model.workspace
                 ?? (model.room.showsLongTilingSummary ? tiling.long : tiling.short))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .layoutPriority(1)
        .help(model.workspace.map { "\($0) — \(tiling.long)" } ?? tiling.long)
    }
}

// MARK: - The capsule

/// Everything you do to the board.
///
/// Reading order is how you are looking at it, then what you can do to it: the mode, tile, find, add,
/// and the view options that hold the mode and the zoom commands.
///
/// The page you have stepped into used to be in here too, as a group of items behind a divider. It is
/// its own capsule now — see `CanvasPageCapsule` — for two reasons. Everything left in this capsule acts
/// on the board, and a hairline is too quiet a way to say that five of the items didn't. And the group
/// appeared and disappeared *inside* the row, so stepping into a card slid Add and the options menu
/// sideways under a pointer already on its way to one of them.
struct CanvasControlCapsule: View {
    @ObservedObject var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var chrome: HeaderChrome { HeaderChrome(active: controlActiveState, hovering: hovering) }

    var body: some View {
        HeaderCapsule(chrome: chrome) {
            if model.showsRendererSwitch {
                RendererSwitch(renderer: .canvas) { model.setRenderer($0) }
                HeaderDivider()
            }
            if model.find.isShowing {
                findField
                HeaderDivider()
            }
            if model.mode == .connect, model.room.showsModeLabel {
                // A word rather than a segmented control, and only in the mode that isn't the default.
                // The board announces connect mode loudly enough by itself — every card grows the four
                // dots you drag lines from — so this is a confirmation rather than the only signal, and
                // a control that is present always to say something that is true rarely is chrome.
                Text("Connecting")
                    .foregroundStyle(.secondary)
                    .headerCaption()
                    .help("Cards are showing the dots you drag lines from")
            }
            // The way *in* to a tiled view, and until now the only thing this feature had no way in
            // from. The window carried one piece of tiling chrome — the ✕ in the pill — which is to
            // say the only control on screen was the one that leaves, and you cannot learn a feature
            // exists from its dismiss button.
            //
            // Permanent rather than appearing with a selection, which was the obvious objection and
            // turns out not to apply: with nothing selected ⌘Return tiles what is on screen, so on any
            // board with a card on it this button is live and means something. There is no state where
            // it would sit dimmed, and so no reason to make the row twitch by hiding it. It keeps its
            // place at every width for the same reason Add and the options menu do — it is a command,
            // not a readout, and the readout is the pill's job.
            HeaderSymbolButton(symbol: "rectangle.split.2x2", help: model.tileTitle, action: model.tile)
            HeaderSymbolButton(symbol: "magnifyingglass", help: "Find on this canvas") {
                model.find.isShowing = true
                model.find.focusToken &+= 1
            }
            addMenu
            optionsMenu
        }
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: model.find.isShowing)
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: model.room)
    }

    // MARK: Find

    /// A field inside the capsule rather than a bar of its own.
    ///
    /// A Mac find bar normally goes in a strip under the toolbar, which is where the project window's
    /// is — but that window has a bar to put it under, and this one deliberately has none. A second
    /// floating strip over the board would be a bar reintroduced for one occasional errand, so find
    /// grows out of the capsule that is already there and shrinks back into it.
    private var findField: some View {
        SearchField(text: Binding(get: { model.find.query },
                                  set: { model.find.query = $0; model.findChanged($0) }),
                    placeholder: "Find on canvas",
                    focusToken: model.find.focusToken,
                    onCancel: model.findClosed,
                    onCommit: model.findCommitted)
            .frame(width: model.room.findWidth)
            .headerItem()
            .overlay(alignment: .trailing) {
                if !model.find.summary.isEmpty {
                    Text(model.find.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.trailing, 22)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Menus

    private var addMenu: some View {
        Menu {
            // The board's right-click menu offers the same four; both read their names from
            // `CanvasAddCommand` so the two can't drift into "Card" here and "New Card" there again.
            Button(CanvasAddCommand.card.title, action: model.addCard)
            // The one of the four a tiled view cannot take. A frame is a container of cards rather
            // than a card, so there is no tile it could become — adding one from here would be an edit
            // made entirely behind the view. The board's own menu dims it for the same reason; the
            // other three now work while tiled and go on the end of the arrangement.
            Button(CanvasAddCommand.frame.title, action: model.addFrame)
                .disabled(model.tiling != nil)
            Button(CanvasAddCommand.link.title, action: model.addLink)
            Button(CanvasAddCommand.file.title, action: model.addFile)
            // Conditional, and the board's right-click menu makes the same test — the item is the board
            // saying something is missing, so it has nothing to say once it is back.
            if model.offersProjectNote {
                Button(CanvasAddCommand.projectNote.title, action: model.addProjectNote)
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
        .help("Add to this canvas")
    }

    private var optionsMenu: some View {
        Menu {
            // This menu is called View options and holds the mode and the four zooms, all of which it
            // turns off while tiled — so the one view option big enough to disable the others was the
            // one thing not in it. First, because it is the largest of them.
            Button(model.tileTitle, action: model.tile)
            Menu("Arrange Tiles") {
                ForEach(CanvasTiling.Arrangement.allCases, id: \.self) { arrangement in
                    Toggle(arrangement.title, isOn: Binding(get: { model.arrangement == arrangement },
                                                            set: { _ in model.setArrangement(arrangement) }))
                }
            }
            Divider()
            Toggle("Connect Cards", isOn: Binding(get: { model.mode == .connect },
                                                  set: { model.setMode($0 ? .connect : .view) }))
                .disabled(model.tiling != nil)
            Divider()
            Group {
                Button("Zoom In", action: model.zoomIn)
                Button("Zoom Out", action: model.zoomOut)
                Button("Actual Size", action: model.zoomActualSize)
                Button("Zoom to Fit", action: model.zoomToFit)
            }
            .disabled(model.tiling != nil)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
        .help("View options")
    }

}

/// Drops a piece of header chrome to sit level with the traffic lights, wherever the system has put
/// them.
///
/// Centred on the piece's own measured height rather than on half a line: the pill and the capsules are
/// not the same height, and a fixed drop levels whichever one it was written for and hangs the other
/// below the buttons.
///
/// **Applied once per hosting view, never to a piece inside one.** The trailing view holds two capsules
/// in a row, and a drop on one of them is padding that only that capsule carries — which is not a piece
/// sitting lower, it is a row whose two halves disagree about where the top of the row is. The pill has
/// its own because it is its own view, and taller.
struct TitlebarDrop: ViewModifier {
    @ObservedObject var model: CanvasHeaderModel
    @State private var height: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear.preference(key: CanvasHeaderHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(CanvasHeaderHeightKey.self) { if let h = $0, h > 0 { height = h } }
            .padding(.top, max(0, model.titlebar.buttonCenterY - height / 2))
    }
}

private struct CanvasHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}
