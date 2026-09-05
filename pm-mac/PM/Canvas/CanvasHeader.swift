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
    @Published var titlebar = TitlebarButtonMetrics.unmeasured

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

    /// Commands an owner puts at the top of the options menu — a project window's way back to its task
    /// list. Empty in a canvas window, which has nothing else to be.
    @Published var extraOptions: [ExtraCommand] = []

    struct ExtraCommand: Identifiable {
        let id = UUID()
        var title: String
        var run: () -> Void
    }

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
}

// MARK: - The pill

/// What board you are looking at. The counterpart of the project window's project pill.
struct CanvasTitlePill: View {
    @ObservedObject var model: CanvasHeaderModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var chrome: HeaderChrome { HeaderChrome(active: controlActiveState, hovering: hovering) }

    var body: some View {
        Text(model.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(chrome.contentOpacity)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .headerBacking(chrome, in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: chrome)
            .accessibilityLabel(Text(model.title))
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
        HStack(spacing: 2) {
            if let page = model.page {
                pageGroup(page)
                divider
            }
            if model.find.isShowing {
                findField
                divider
            }
            // The zoom percentage used to read in the window's subtitle, which a hidden title takes
            // with it. Quiet and monospaced so it can change under your eye without the row twitching
            // — the same treatment the project header's progress count gets.
            Text("\(Int((model.zoom * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 4)
                .help("Zoom")
            if model.mode == .edit {
                // A word rather than a segmented control, and only in the mode that isn't the default.
                // The board announces edit mode loudly enough by itself — every card grows the four
                // dots you drag lines from — so this is a confirmation rather than the only signal, and
                // a control that is present always to say something that is true rarely is chrome.
                Text("Editing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .help("This board is in edit mode")
            }
            button("magnifyingglass", "Find on this canvas") {
                model.find.isShowing = true
                model.find.focusToken &+= 1
            }
            addMenu
            optionsMenu
        }
        .opacity(chrome.contentOpacity)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .headerBacking(chrome, in: Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: chrome)
        .animation(.snappy(duration: 0.2), value: model.page)
        .animation(.snappy(duration: 0.2), value: model.find.isShowing)
        .modifier(TitlebarDrop(model: model))
    }

    // MARK: The page you have stepped into

    @ViewBuilder private func pageGroup(_ page: CanvasHeaderModel.Page) -> some View {
        Text(page.host)
            .font(.caption)
            .foregroundStyle(page.wandered ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220)
            .padding(.horizontal, 5)
            .help(pageHelp(page))
        button("chevron.left", "Back", enabled: page.canGoBack, action: model.pageBack)
        button("chevron.right", "Forward", enabled: page.canGoForward, action: model.pageForward)
        button("arrow.clockwise", "Reload", action: model.pageReload)
        button("house", "Back to this card\u{2019}s address",
               enabled: page.wandered, action: model.pageHome)
        if page.wandered {
            // Only once the page has actually gone somewhere else — on a card sitting on its own
            // address this would be an offer to change nothing.
            button("pin", "Set as this card\u{2019}s address", action: model.pageAdoptAddress)
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
            .frame(width: 170)
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
        .frame(width: 22)
        .help("Add to this canvas")
    }

    private var optionsMenu: some View {
        Menu {
            if !model.extraOptions.isEmpty {
                ForEach(model.extraOptions) { command in
                    Button(command.title, action: command.run)
                }
                Divider()
            }
            Toggle("Edit Mode", isOn: Binding(get: { model.mode == .edit },
                                              set: { model.setMode($0 ? .edit : .view) }))
            Divider()
            Button("Zoom In", action: model.zoomIn)
            Button("Zoom Out", action: model.zoomOut)
            Button("Actual Size", action: model.zoomActualSize)
            Button("Zoom to Fit", action: model.zoomToFit)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("View options")
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 15)
            .padding(.horizontal, 4)
    }

    /// One control in the capsule: a symbol at the size and weight the others use, in a hit area big
    /// enough to click without aiming. Shared so the buttons can't drift apart — the same reasoning as
    /// the project header's `headerButton`.
    private func button(_ symbol: String, _ help: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
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
