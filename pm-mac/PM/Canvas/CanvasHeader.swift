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
    /// What ⌘Return would do to the board as it stands — the same sentence the View menu and the
    /// contextual menu use. See `CanvasTiling.commandTitle`.
    ///
    /// **The button no longer wears this as a tooltip**, and did. A tooltip that changes with the
    /// selection is one you cannot have read before you act on it: it appears a second after you have
    /// stopped moving, by which time you have either clicked or gone somewhere else. What it was
    /// telling you — how many cards are about to become a workspace — the menus say in a place you are
    /// already reading. This is now the title of that menu item and nothing else.
    @Published var tileTitle = "Create Workspace"
    /// Whether ⌘Return has anything to do. Dim on a canvas with nothing selected — a workspace is made
    /// out of a selection or not at all.
    @Published var canTile = false
    /// The focused tile's controls, or nil when there is no one tile to act on: an untiled board, a
    /// workspace of one tile, or several tiles picked at once. See `CanvasTileCapsule`.
    @Published var focusedTile: TileControls?
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

    /// What the header knows about the one tile the commands are about.
    ///
    /// A view model of `CanvasBoardView.focusedTile` and the three questions its verbs ask — a tile in a
    /// grid has no master to become, and a tile in a grid of both rows and columns has no run to pin
    /// along. The conditions live here rather than in the capsule so the capsule is a drawing of a
    /// state rather than a second copy of the board's rules.
    struct TileControls: Equatable {
        var isMaximized = false
        /// Whether Make This the Master Tile means anything: master-and-stack, and not already it.
        var canPromote = false
        /// What Pin is called, or nil where there is no run to pin along. See
        /// `CanvasBoardView.pinTileTitle`.
        var pinTitle: String?
    }

    struct Find: Equatable {
        var isShowing = false
        var query = ""
        var summary = ""
        /// Bumped to pull the keyboard back into the field — a second ⌘F is "search again".
        var focusToken = 0
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
    /// Whether the `+` offers the project's own note — true only on a project's board that hasn't got
    /// it. Kept in step with the document by `CanvasPaneController.documentChanged`; the board owns the
    /// question (`CanvasBoardView.offersProjectNoteCard`).
    @Published var offersProjectNote = false

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
    var tile: () -> Void = {}
    var setArrangement: (CanvasTiling.Arrangement) -> Void = { _ in }
    /// The focused tile's verbs — see `CanvasTileCapsule`.
    var maximizeTile: () -> Void = {}
    var promoteTile: () -> Void = {}
    var pinTile: () -> Void = {}
    var removeTile: () -> Void = {}
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
struct CanvasTitlePill: View {
    @ObservedObject var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var chrome: HeaderChrome { HeaderChrome(active: controlActiveState, hovering: hovering) }

    /// Whether a workspace is up. The pill is the same pill either way; what changes is whether it is
    /// wearing anything.
    private var tiled: Bool { model.tiling != nil }

    var body: some View {
        Text(model.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(chrome.contentOpacity)
            // **The leading inset moves to the trailing side rather than going away.**
            //
            // Without glass around it the inset is not padding, it is a name that starts fourteen
            // points inside its own island while every other piece of chrome in the band starts at
            // its edge. So the name goes flush. But the pill's *width* has to be the same number in
            // both states, because the tab row is pinned to its trailing anchor — take fourteen points
            // off each side and that is a change of `intrinsicContentSize`, which Auto Layout settles
            // in one frame: the whole row of chips jumps twenty-eight points leftward and the name's
            // animation is lost with it, since SwiftUI does not interpolate a layout whose hosting
            // view is being resized under it. Both halves of that are measured in
            // `HeaderChromeMotionTests`.
            //
            // Total horizontal inset is `pillInset.horizontal * 2` whatever mode is up. What that buys
            // is the whole transition: nothing in the header moves, and the name is free to slide
            // inside a box that is standing still.
            .padding(.leading, tiled ? 0 : HeaderMetrics.pillInset.horizontal)
            .padding(.trailing, HeaderMetrics.pillInset.horizontal * (tiled ? 2 : 1))
            // Vertical stays symmetric and stays put. It is invisible without the capsule — `TitlebarDrop`
            // centres this view on the traffic lights whatever it measures — so removing it would move
            // nothing and cost the pill its hit area.
            .padding(.vertical, HeaderMetrics.pillInset.vertical)
            // **No glass over a tiled board**, for the reason the control capsule drops its own: tiles
            // are panels with their own edges on a plain ground, so the separation the backing exists
            // to draw has already been made. The canvas keeps it — there the name sits over cards
            // panning under it. It crossfades; see `headerBacking(_:in:showing:)`.
            .headerBacking(chrome, in: Capsule(), showing: !tiled)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
            // Safe *because* of the arithmetic above: this animates where the name sits inside the
            // pill, not how wide the pill is.
            .animation(Motion.animation(.easeOut(duration: 0.18)), value: tiled)
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
        // **No glass over a tiled board.** The backing is there to hold these glyphs legible over cards
        // panning under them; tiles are panels with their own edges on a plain ground, so the header is
        // over the ground and the separation has already been made. A second one on top of it reads as
        // two surfaces arguing about which is in front. See `headerBacking(_:in:showing:)`.
        HeaderCapsule(chrome: chrome, backed: model.tiling == nil) {
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
            HeaderSymbolButton(symbol: "magnifyingglass", help: "Find on this canvas") {
                model.find.isShowing = true
                model.find.focusToken &+= 1
            }
            addMenu
            optionsMenu
        }
        .onHover { hovering = $0 }
        // Opacity only. Find opening and the field narrowing with the window both change this
        // capsule's width — and a capsule that animates its own width throws its own glyphs sideways
        // for a fifth of a second, out from under the pointer on its way to one of them. Which is the failure this capsule was split out to fix, arriving by another
        // door. See `CanvasHeaderTrailingChrome` and `HeaderChromeMotionTests`.
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
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
            Button(model.tileTitle, action: model.tile).disabled(!model.canTile)
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
