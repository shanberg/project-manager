import AppKit
import SwiftUI

/// The canvas window's chrome: a pill naming the board at the leading edge, a capsule of controls at
/// the trailing one, and nothing at all in between.
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
/// **Two views rather than one strip**, and that is what makes the band usable. A single header view
/// spanning the window would hit-test its whole width and swallow every click in the top 48 points of
/// the board — including on the cards up there. A pill and a capsule that each hug their own contents
/// leave the space between them as what it looks like: board.
@MainActor
final class CanvasHeaderModel: ObservableObject {
    /// The board's name — the canvas file, without its extension.
    @Published var title = ""
    @Published var zoom: Double = 1
    @Published var mode: CanvasMode = .view
    /// The web card you have stepped into, if any.
    @Published var page: Page?
    @Published var find = Find()
    /// What a tiled view is showing, long and short — "6 of 43 cards" and "6/43". Nil when the board is
    /// showing itself.
    ///
    /// It has to say something. A board showing six of forty-three cards, with the rest hidden and the
    /// lines between them gone, looks exactly like a board most of which has been deleted — and the
    /// moment you think that is the moment you stop trusting the feature.
    @Published var tiling: (long: String, short: String)?
    @Published var titlebar = TitlebarButtonMetrics.unmeasured
    /// How much of the window the controls can spend. See `CanvasHeaderModel.Room`.
    @Published var room = Room.full

    /// How much room the capsule has, and therefore what it can afford to say.
    ///
    /// The capsule grew: it can hold the live page's host and four buttons, the tiled view's count and
    /// its way out, a find field, the zoom, the word "Editing", and three controls. All of that at once
    /// on a narrow window runs into the title pill, and the pill is the piece that gives way — so the
    /// window ends up naming the board it is showing with two letters and an ellipsis.
    ///
    /// The fix is an order of precedence rather than more space: state you are *in* outlasts state you
    /// can *read elsewhere*. The page group and the find field are things you asked for a moment ago and
    /// are acting on now. The zoom is a number the board itself shows you by being at that zoom. So the
    /// zoom goes first, then the mode label, then the host's words — its buttons stay, because they are
    /// the only way to drive the page. What never goes: the renderer switch, Add, and the options menu.
    ///
    /// The tiled count is measured here too, but it isn't in this capsule any more — it belongs to the
    /// pill, which is where "what am I looking at" is answered. It shortens to a bare fraction rather
    /// than leaving, because the pill has a title to compress before it needs to drop anything.
    ///
    /// Breakpoints on the window rather than a fitting pass, because the capsule is in a hosting view
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

        var showsZoom: Bool { self == .full }
        var showsModeLabel: Bool { self == .full }
        var showsPageHost: Bool { self != .minimal }
        var hostWidth: CGFloat { self == .full ? 220 : 120 }
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
        /// The address written on the board, shown when the page has left it.
        var savedAddress: String
        var wandered: Bool
        var canGoBack: Bool
        var canGoForward: Bool
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
    /// Nil in a canvas window, which has no task list to switch to. Set when a project window is
    /// rendering its project as a board — and then the header carries the *same* `RendererSwitch` the
    /// task list's header carries, in the same place, so the control doesn't move when you use it.
    ///
    /// It was a lone button here and a different lone button there, each findable only once you were
    /// already on the other side of it and neither saying there was another side.
    @Published var showsRendererSwitch = false
    var setRenderer: (ProjectRenderer) -> Void = { _ in }

    // MARK: What the controls do. Supplied by the window controller.

    var addCard: () -> Void = {}
    var addFrame: () -> Void = {}
    var addLink: () -> Void = {}
    var addFile: () -> Void = {}
    var setMode: (CanvasMode) -> Void = { _ in }
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var zoomActualSize: () -> Void = {}
    var pageBack: () -> Void = {}
    var pageForward: () -> Void = {}
    var pageReload: () -> Void = {}
    var pageHome: () -> Void = {}
    var pageAdoptAddress: () -> Void = {}
    var pageEditAddress: () -> Void = {}
    var findChanged: (String) -> Void = { _ in }
    var findClosed: () -> Void = {}
    var findCommitted: () -> Void = {}
    var leaveTiling: () -> Void = {}
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
            if let tiling = model.tiling {
                Text(verbatim: "·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(model.room.showsLongTilingSummary ? tiling.long : tiling.short)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(model.tiling.map { "\(model.title), tiled, \($0.long)" } ?? model.title))
        .modifier(TitlebarDrop(model: model))
    }
}

// MARK: - The capsule

/// Everything you do to the board, and — while you are inside a web card — everything you do to its
/// page.
///
/// Reading order is what is live, then how you are looking at it, then what you can add: the page group
/// (only when there is a page), the zoom, find, add, and the view options that hold the mode and the
/// rest of the zoom commands.
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
            if let page = model.page {
                pageGroup(page)
                HeaderDivider()
            }
            if model.find.isShowing {
                findField
                HeaderDivider()
            }
            // The zoom percentage used to read in the window's subtitle, which a hidden title takes
            // with it. Quiet and monospaced so it can change under your eye without the row twitching
            // — the same treatment the project header's progress count gets.
            // Hidden while tiled: the tiles fill the window at whatever zoom they were laid out at, and
            // a percentage you cannot change and did not choose is a number for its own sake.
            if model.tiling == nil, model.room.showsZoom {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .headerCaption()
                    .help("Zoom")
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
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: model.page)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: model.find.isShowing)
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: model.room)
        .modifier(TitlebarDrop(model: model))
    }

    // MARK: The page you have stepped into

    @ViewBuilder private func pageGroup(_ page: CanvasHeaderModel.Page) -> some View {
        // The host's words are the first thing in this group to go, and its buttons are the last: the
        // buttons are the only way to drive the page, while the address is also on the page itself. It
        // holds on longer than anything else that is only informative, though — a wandered card is the
        // one thing here that can cost you something.
        if model.room.showsPageHost || page.wandered {
            Text(page.host)
                .foregroundStyle(page.wandered ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: model.room.hostWidth)
                .headerCaption()
                .help(pageHelp(page))
        }
        HeaderSymbolButton(symbol: "chevron.left", help: "Back",
                           enabled: page.canGoBack, action: model.pageBack)
        HeaderSymbolButton(symbol: "chevron.right", help: "Forward",
                           enabled: page.canGoForward, action: model.pageForward)
        HeaderSymbolButton(symbol: "arrow.clockwise", help: "Reload", action: model.pageReload)
        HeaderSymbolButton(symbol: "house", help: "Back to this card\u{2019}s address",
                           enabled: page.wandered, action: model.pageHome)
        if page.wandered {
            // Only once the page has actually gone somewhere else — on a card sitting on its own
            // address this would be an offer to change nothing.
            HeaderSymbolButton(symbol: "pin", help: "Set as this card\u{2019}s address",
                               action: model.pageAdoptAddress)
        }
    }

    private func pageHelp(_ page: CanvasHeaderModel.Page) -> String {
        var lines: [String] = []
        if page.wandered {
            lines.append("This card has navigated away from the address saved on the board.")
            lines.append("Saved: " + page.savedAddress)
        }
        if let age = page.age { lines.append("Loaded " + age) }
        return lines.isEmpty ? page.host : lines.joined(separator: "\n")
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
            Button("Card", action: model.addCard)
            Button("Frame", action: model.addFrame)
            Button("Link\u{2026}", action: model.addLink)
            Button("File\u{2026}", action: model.addFile)
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
/// Centred on the piece's own measured height rather than on half a line: the pill and the capsule are
/// not the same height, and a fixed drop levels whichever one it was written for and hangs the other
/// below the buttons.
private struct TitlebarDrop: ViewModifier {
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
