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
@Observable
final class CanvasHeaderModel {
    /// The board's name — the canvas file, without its extension.
    var title = ""
    var mode: CanvasMode = .view
    /// The web card you have stepped into, if any.
    var page: Page?
    var find = Find()
    /// Bumped by ⌘L to put the keyboard in the address field with the address selected, the way a
    /// browser does. A token rather than a flag, for the reason `Find.focusToken` is one: pressing it
    /// again while the field is already open has to mean something.
    var addressFocusToken = 0
    /// What a tiled view is showing, long and short — "6 of 43 cards" and "6/43". Nil when the board is
    /// showing itself.
    ///
    /// It has to say something. A board showing six of forty-three cards, with the rest hidden and the
    /// lines between them gone, looks exactly like a board most of which has been deleted — and the
    /// moment you think that is the moment you stop trusting the feature.
    var tiling: (long: String, short: String)?
    /// What ⌘Return would do to the board as it stands — the same sentence the View menu and the
    /// contextual menu use. See `CanvasTiling.commandTitle`.
    ///
    /// **The button no longer wears this as a tooltip**, and did. A tooltip that changes with the
    /// selection is one you cannot have read before you act on it: it appears a second after you have
    /// stopped moving, by which time you have either clicked or gone somewhere else. What it was
    /// telling you — how many cards are about to become a workspace — the menus say in a place you are
    /// already reading. This is now the title of that menu item and nothing else.
    var tileTitle = "Create Workspace"
    /// Whether ⌘Return has anything to do. Dim on a canvas with nothing selected — a workspace is made
    /// out of a selection or not at all.
    var canTile = false
    /// The focused tile's controls, or nil when there is no one tile to act on: an untiled board, a
    /// workspace of one tile, or several tiles picked at once. See `CanvasTileCapsule`.
    var focusedTile: TileControls?
    /// How many cards the `…` is about — a focused tile, a page stepped into, or the selection — and
    /// zero when there is no card menu to open. See `CanvasCardActions.target`.
    var cards = 0
    /// A folder card's layout, when the `…` is about folder cards and nothing else. See `FolderControls`.
    var folder: FolderControls?
    /// Bumped to open the `…` from the keyboard, against the button, exactly as a click would.
    var cardActionsToken = 0

    /// The one capsule that is about what you are *in* — see `CanvasTileCapsule`.
    ///
    /// **Two facts, one piece of glass.** They were two capsules, and the split was drawn at the wrong
    /// joint: a tile and the thing inside it are not two scopes you switch between, they are one place
    /// described twice. On a web tile both were up at once, about the same object, each with its own
    /// `…` menu — two overflow buttons four points apart, which is a menu nobody can aim at.
    ///
    /// Either half can be absent and the capsule is still there for the other: a page with no focused
    /// tile is an engaged card on an untiled board, and a focused tile with no page is every tile that
    /// isn't a web card.
    ///
    /// **And with neither, for selected cards**, as their `…`: the menu is the cards' own contextual
    /// menu (`CanvasBoardView.cardActionsMenu`), so a folder or a note selected on the board has as much
    /// in it as a tile does, and six selected cards have what a right-click on them has. Nil only when
    /// there is no card to act on — nothing selected, or a line.
    var focus: Focus? {
        guard page != nil || focusedTile != nil || cards > 0 else { return nil }
        return Focus(page: page, tile: focusedTile, folder: folder, cards: max(cards, 1))
    }

    /// What the focused-tile capsule draws: the controls for whatever kind of thing you are in, and the
    /// verbs the tile itself answers to.
    struct Focus: Equatable {
        var page: Page?
        var tile: TileControls?
        var folder: FolderControls?
        /// How many cards the `…` acts on, which its tooltip says.
        var cards = 1
    }

    /// A folder card's run in the capsule: the one setting you change often enough to want outside a
    /// submenu, as the Finder keeps its view buttons in the toolbar rather than only in View.
    ///
    /// **One toggle, drawn as where it goes**, the way maximize is: two views is a switch, not a choice
    /// of four. `view` is what the cards show now — several folder cards set differently read as list,
    /// so the button offers icons, and a click makes them agree.
    struct FolderControls: Equatable {
        var view: CanvasFolderView
    }

    var titlebar = TitlebarButtonMetrics.unmeasured
    /// How much of the window the controls can spend. See `CanvasHeaderModel.Room`.
    var room = Room.full

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
    /// tell you whose password field you are looking at. What never goes: Add and the options menu.
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
        ///
        /// A `hitWidth` and a `gap` wider than it was, because Reload moved inside it: the row is the
        /// width it always was, and the field is where the button's room went.
        var addressWidth: CGFloat {
            switch self {
            case .full: return 266
            case .tight: return 176
            case .minimal: return 130
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
        /// How far the load has got, 0…1, and zero when nothing is loading.
        ///
        /// Reload becoming Stop already says a load is happening; this says how it is going, which is
        /// the difference between a card that is slow and a card that is stuck. Rounded by the card
        /// before it gets here, so a value that hasn't moved a twentieth doesn't redraw the row.
        var progress: Double = 0
        /// Whether the page arrived over a connection nobody can read.
        ///
        /// Shown only when false — see `CanvasAddressField`. A lock on every page is furniture; the
        /// state worth a mark is the one the password argument is about.
        var isSecure: Bool = true
        /// The site's own icon, if the app already has it. Nil is ordinary and draws nothing.
        var icon: NSImage?
        /// Where Back would take you, nearest first. Empty disables the menu behind the button and
        /// leaves an ordinary Back.
        var back: [Step] = []

        /// One page in the back list.
        struct Step: Equatable {
            var title: String
            var address: String
        }
    }

    /// What the header knows about the one tile the commands are about.
    ///
    /// A view model of `CanvasBoardView.focusedTile` and the three questions its verbs ask — a tile in a
    /// grid has no master to become, and a tile in a grid of both rows and columns has no run to pin
    /// along. The conditions live here rather than in the capsule so the capsule is a drawing of a
    /// state rather than a second copy of the board's rules.
    struct TileControls: Equatable {
        var isMaximized = false
        /// A card on the board rather than a tile in a workspace: it fills the window alone, and
        /// restoring puts the board back. See `CanvasBoardView.maximizeCard`.
        var isCard = false
    }

    struct Find: Equatable {
        var isShowing = false
        var query = ""
        var summary = ""
        /// Bumped to pull the keyboard back into the field — a second ⌘F is "search again".
        var focusToken = 0
        /// What this search will actually look inside.
        ///
        /// **Find follows what you have stepped into** — the board, a page, or a project card's task
        /// list — and the field said "Find on canvas" whichever of the three it was about to do. One
        /// placeholder, three truths, and the two it was wrong about are the two where the answer
        /// "nothing matches" would otherwise look like a broken search.
        var scope: Scope = .canvas

        enum Scope: Equatable {
            case canvas, page, tasks

            var placeholder: String {
                switch self {
                case .canvas: "Find on canvas"
                case .page: "Find on page"
                case .tasks: "Find in tasks"
                }
            }
        }
    }

    /// **The pill has no readout, and had one.**
    ///
    /// It used to say which workspace was up, or how many cards were tiled while there was no name to
    /// say — and it handed that to the tab bar the moment there was a bar, which is where the reflow
    /// came from: leaving a tiled view renamed a chip, inserted a chip and moved the pill's contents,
    /// all in one act. §7i settles it in the other direction. The canvas is a permanent chip and every
    /// workspace is a chip, so the row already answers "which of this board's places am I in" at all
    /// times, and it answers it in one place. What the pill keeps is the project's name and the way
    /// back to the board, both of which are true at a constant width.
    // MARK: What the controls do. Supplied by the window controller.

    /// The `+`: open what can be added to the board, against the view given — see `addMenu`.
    @ObservationIgnored
    var showAddMenu: (NSView) -> Void = { _ in }
    @ObservationIgnored
    var setMode: (CanvasMode) -> Void = { _ in }
    @ObservationIgnored
    var zoomIn: () -> Void = {}
    @ObservationIgnored
    var zoomOut: () -> Void = {}
    @ObservationIgnored
    var zoomToFit: () -> Void = {}
    @ObservationIgnored
    var zoomActualSize: () -> Void = {}
    @ObservationIgnored
    var pageBack: () -> Void = {}
    @ObservationIgnored
    var pageForward: () -> Void = {}
    @ObservationIgnored
    var pageReload: () -> Void = {}
    @ObservationIgnored
    var pageStop: () -> Void = {}
    @ObservationIgnored
    var pageHome: () -> Void = {}
    @ObservationIgnored
    var pageAdoptAddress: () -> Void = {}
    /// Back by more than one, from the menu behind the Back button. The argument is how many pages.
    @ObservationIgnored
    var pageBackTo: (Int) -> Void = { _ in }
    /// Send the page to an address typed into the header's field. Navigation only — it does not touch
    /// what the board has saved for the card, which is what Pin is for.
    @ObservationIgnored
    var pageGo: (String) -> Void = { _ in }
    /// Every page the address field may suggest, board cards first — see `CanvasAddressSuggestions`.
    /// Asked for when the field opens rather than kept up to date, since it is read once per edit.
    @ObservationIgnored
    var addressCandidates: () -> [CanvasAddressSuggestions.Candidate] = { [] }
    @ObservationIgnored
    var findChanged: (String) -> Void = { _ in }
    @ObservationIgnored
    var findClosed: () -> Void = {}
    @ObservationIgnored
    var findCommitted: () -> Void = {}
    @ObservationIgnored
    var tile: () -> Void = {}
    @ObservationIgnored
    var setArrangement: (CanvasTiling.Arrangement) -> Void = { _ in }
    @ObservationIgnored
    var sizeColumnsToContent: () -> Void = {}
    /// The focused tile's verbs — see `CanvasTileCapsule`.
    @ObservationIgnored
    var maximizeTile: () -> Void = {}
    /// The `…`: open what the tile or card you are in can be told, against the view given — the board's
    /// own contextual menu for it (`CanvasBoardView.cardActionsMenu`).
    @ObservationIgnored
    var showCardActions: (NSView) -> Void = { _ in }
    /// Switch the folder cards the `…` is about between list and icons — see `FolderControls`.
    @ObservationIgnored
    var toggleFolderView: () -> Void = {}
}

// MARK: - The pill

/// What board you are looking at. The counterpart of the project window's project pill.
///
/// **A name, and nothing else.** It has carried, at various points, a tiled count, a workspace menu and
/// a ✕, and every one of them has now gone to the row of tabs — which is where "which of this board's
/// places am I in" belongs, because the row is the list of places (§7i). The ✕ was the last to go and
/// the least defensible by the end: it meant "show the canvas", and the canvas is a permanent chip
/// three inches to the right of it. A control that duplicates a control beside it is not an escape
/// hatch, it is a second thing to explain.
///
/// What is left has one useful property: it never changes width, so nothing in the header moves when
/// you switch between the board and a workspace.
///
/// **And no glass, in any state.** "Non-interactive items like custom titles… should avoid the glass
/// material" (WWDC25, *Build an AppKit app with the new design*): glass in this header means *these are
/// controls*, and a name is not one. What keeps it legible over cards panning under it is the board's
/// soft edge (`CanvasSoftEdge`). So the pill is identical on the board and in every workspace —
/// same inset, same place, same nothing behind it — which is what the first complaint about this header
/// asked for. docs/header-chrome.md Q1.
struct CanvasTitlePill: View {
    var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Text(model.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(HeaderChrome(active: controlActiveState).contentOpacity)
            // A text inset rather than the pill's old island inset: with nothing drawn around the name,
            // fourteen points was a gap beside the traffic lights with no reason to be there.
            .padding(.horizontal, HeaderMetrics.textInset)
            .padding(.vertical, HeaderMetrics.pillInset.vertical)
            .animation(Motion.animation(.easeOut(duration: 0.18)), value: controlActiveState)
            .accessibilityLabel(Text(model.title))
            .modifier(TitlebarDrop(model: model))
    }
}

// MARK: - The capsule

/// Everything you do to the board.
///
/// Reading order is how you are looking at it, then what you can do to it: the mode, find, add, and
/// the view options that hold the mode, the tiling and the zoom commands.
///
/// The page you have stepped into used to be in here too, as a group of items behind a divider, for
/// two reasons it isn't. Everything left in this capsule acts on the board, and a hairline is too quiet
/// a way to say that five of the items didn't. And the group appeared and disappeared *inside* the row,
/// so stepping into a card slid Add and the options menu sideways under a pointer already on its way to
/// one of them.
///
/// It went to a capsule of its own, and from there into the focused tile's — see `CanvasTileCapsule`,
/// which is the capsule for whatever you are standing in. This one is the board, and is the only one of
/// the two that is always there.
struct CanvasControlCapsule: View {
    var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState
    /// The find field coming and going — see `HeaderPresence`. Opening, the capsule snaps to make room
    /// and the field materializes in it; closing, the field fades where it stands and only then does
    /// the capsule close up and the magnifier come back. docs/header-chrome.md Q2.
    @State private var find = HeaderPresence<Bool>()

    var body: some View {
        // The same glass over the board and over a workspace — see `headerBacking(in:)`. Named, because
        // this capsule changes width too — ⌘F puts a field in it — and the container has to know it is
        // still the same piece of glass afterwards.
        HeaderCapsule(chrome: HeaderChrome(active: controlActiveState), glass: "controls") {
            if find.shown != nil {
                Group {
                    findField
                    HeaderDivider()
                }
                .headerMaterialized(find.materialized)
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
            // Gone while the field is up: the field is find, and a button beside it that opens find is
            // a second control for the thing you are already doing. ⌘F still pulls the keyboard back.
            // Back only once the field has gone, so the two are never in the capsule together.
            if find.shown == nil {
                HeaderSymbolButton(symbol: "magnifyingglass", help: "Find on this canvas") {
                    model.find.isShowing = true
                    model.find.focusToken &+= 1
                }
            }
            addMenu
            optionsMenu
        }
        // Nothing here animates its width. Find opening and the field narrowing with the window both
        // change it, and a capsule that animates its own width throws its own glyphs sideways for a
        // fifth of a second, out from under the pointer on its way to one of them. The capsule snaps;
        // the field materializes where it lands. See `HeaderChromeMotionTests`.
        .headerPresence(of: model.find.isShowing ? true : nil, in: $find)
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
                    // What it will actually search, which is not always the canvas. See `Find.Scope`.
                    placeholder: model.find.scope.placeholder,
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

    /// The `+`: what can go on this board, as the board's own menu builds it (`CanvasBoardView.addMenu`).
    ///
    /// **AppKit's menu, not a SwiftUI one**, for the reason `HeaderMenuButton` gives and two of its own.
    /// A SwiftUI `Menu` is built from state published ahead of time, so the pane had to keep a copy of
    /// the board's cards in step with every edit; built as it opens, the list is simply current. And a
    /// SwiftUI menu cannot say which item the pointer is on, which is what the card preview beside
    /// Add Card from Canvas needs (`CanvasCardPreview`). It also draws the cards' icons, which the
    /// SwiftUI copy asked for and did not get.
    private var addMenu: some View {
        HeaderMenuButton(symbol: "plus", help: "Add to this canvas", open: model.showAddMenu)
    }

    private var optionsMenu: some View {
        Menu {
            // This menu is called View options and holds the mode and the four zooms, all of which it
            // turns off while tiled — so the one view option big enough to disable the others was the
            // one thing not in it. First, because it is the largest of them.
            Button(model.tileTitle, action: model.tile).disabled(!model.canTile)
            Menu("Arrange Tiles") {
                // Commands rather than a setting, so nothing is ticked — see
                // `CanvasBoardView.setArrangement`.
                ForEach(CanvasTiling.Arrangement.allCases, id: \.self) { arrangement in
                    Button(arrangement.title) { model.setArrangement(arrangement) }
                }
                Divider()
                Button("Size Columns to Content", action: model.sizeColumnsToContent)
                    .disabled(model.tiling == nil)
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
        .headerHoverHighlight()
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
    var model: CanvasHeaderModel
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
