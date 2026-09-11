import AppKit
import SwiftUI

/// The window's trailing chrome: the board's controls, and — while you are inside a web card — the
/// page's, in a capsule of their own beside them.
///
/// **One hosting view holding two capsules**, rather than two views the pane would have to position.
/// The pair has to stay a pair: the control capsule is pinned to the window's trailing edge and the page
/// capsule grows away from it leftward, which is the whole point of splitting them — stepping into a
/// card must not move Add and the options menu. Two separately-constrained views would have to agree
/// about a gap and about which of them collapses, and that agreement is what an `HStack` already is.
///
/// **A capsule arrives by materializing, and the row never animates.** It had a transition once — a
/// blur replace, over an animated row — and the animation was doing the exact thing the split was there
/// to prevent. A stack lays its children out from its leading edge, and that edge is what moves when the
/// row changes width: Auto Layout takes the origin from `intrinsicContentSize`, which is the settled
/// size and arrives in one step, while SwiftUI interpolates the offsets over the duration. Two clocks
/// for one number. Measured, because it is not obvious from either side — switching between a project
/// tile and a web tile threw the whole row 174 points sideways and slid it back over a fifth of a
/// second. See `HeaderChromeMotionTests`, which also measures the way out that would have kept the
/// animation: a fixed box with the capsules right-aligned in it never moves, and hit-tests the whole
/// band, which is the thing this header is islands to avoid.
///
/// The rule that follows, and it holds one level down too: **nothing in this chrome animates a change
/// that alters its own width.** Opacity, a swapped glyph, a colour, glass coming in — those are free, and
/// they are what is left. So a capsule that comes and goes is a `HeaderPresence`: the row snaps to make
/// room, and then the capsule materializes where it already stands.
struct CanvasHeaderTrailingChrome: View {
    @ObservedObject var model: CanvasHeaderModel
    @State private var page = HeaderPresence<CanvasHeaderModel.Page>()
    @State private var tile = HeaderPresence<CanvasHeaderModel.TileControls>()

    var body: some View {
        // **One container for the three pieces of glass**, because glass cannot sample other glass and
        // pieces in separate containers render inconsistently beside one another. Its spacing is the
        // gap *inside* a capsule, well under the gap between them, so the three stay three at rest
        // rather than pooling into one blob.
        GlassEffectContainer(spacing: HeaderMetrics.gap) {
            // Bottom-aligned, so the capsules share a baseline whatever they turn out to be. They are
            // the same height today — one row of `itemHeight` in the same inset — and centring them
            // would hide it the day one of them isn't.
            HStack(alignment: .bottom, spacing: HeaderMetrics.capsuleGap) {
                if let shown = page.shown {
                    CanvasPageCapsule(model: model, page: shown)
                        .headerMaterialized(page.materialized)
                }
                // **Between the two, so the scopes widen toward the window's edge**: the page inside a
                // card, then the tile that card is in, then the board they are all on. In a tiled view
                // the focused tile *is* the engaged card (`CanvasBoardView.tileClicked` selects and
                // engages together), so on a web tile both of these are up at once and are about the
                // same object at two scales — which is the order to read them in.
                if let shown = tile.shown {
                    CanvasTileCapsule(model: model, tile: shown)
                        .headerMaterialized(tile.materialized)
                }
                CanvasControlCapsule(model: model)
            }
            // On the row, which is always there — see `HeaderPresence`.
            .headerPresence(of: model.page, in: $page)
            .headerPresence(of: model.focusedTile, in: $tile)
        }
        // The drop belongs to the row, not to any capsule in it. See `TitlebarDrop`.
        .modifier(TitlebarDrop(model: model))
    }
}

/// The one card whose page is live under your hands, and everything you do to it.
///
/// Its own glass, its own hover state, and its own inset — because it is a different scope from
/// everything beside it. The board's capsule zooms the board, tiles the board, adds to the board; this
/// drives a web view inside one card, and the two were separated by a hairline.
///
/// **Laid out the way a browser lays this out**: the buttons that move you through history, then where
/// you are, then — only when it applies — the two ways back to where the board says you should be. The
/// address used to come first, which put the one item in the row made of words between two runs of
/// glyphs with `HeaderMetrics.gap` on each side. Four points of air around a hostname is why this felt
/// tight; the reading order is why it felt unfamiliar.
struct CanvasPageCapsule: View {
    @ObservedObject var model: CanvasHeaderModel
    let page: CanvasHeaderModel.Page
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HeaderCapsule(chrome: HeaderChrome(active: controlActiveState)) {
            HeaderSymbolButton(symbol: "chevron.left", help: "Back",
                               enabled: page.canGoBack, action: model.pageBack)
            HeaderSymbolButton(symbol: "chevron.right", help: "Forward",
                               enabled: page.canGoForward, action: model.pageForward)
            // Reload and Stop are one button because they are one question — "is this page still
            // arriving?" — and a card answers it nowhere else. A card is drawn as its *old* page until
            // the new one paints, so without this the only sign that a click did anything is the page
            // eventually changing.
            //
            // **One button in the source too**, and it was two behind an `if`. Two views swapped by a
            // condition are two identities, so the change was a removal and an insertion — a cut, no
            // matter what animation was in scope. The same button with a different symbol on it is one
            // identity, which is what lets the mark itself do the swap; see the content transition in
            // `HeaderSymbolButton`. It is the same hit area either way, so this costs the row nothing.
            HeaderSymbolButton(symbol: page.isLoading ? "xmark" : "arrow.clockwise",
                               help: page.isLoading ? "Stop loading" : "Reload",
                               action: page.isLoading ? model.pageStop : model.pageReload)

            HeaderGap()
            CanvasAddressField(page: page, width: model.room.addressWidth,
                               openToken: model.addressFocusToken, go: model.pageGo)

            // Home and Pin are the two answers to "this card is not on its own address", and there is
            // no such question when it is. Home was permanently present and permanently dimmed before —
            // a control that spends most of its life saying nothing, in the row that had least space to
            // spare. Now the pair arrives with the state it resolves, next to the address that is
            // showing you the problem.
            if page.wandered {
                HeaderGap()
                HeaderSymbolButton(symbol: "house", help: "Back to this card\u{2019}s address",
                                   action: model.pageHome)
                HeaderSymbolButton(symbol: "pin", help: "Set as this card\u{2019}s address",
                                   action: model.pageAdoptAddress)
            }
        }
        // A swapped glyph only. Home and Pin arriving, and the address field changing width with the
        // window, both change the capsule's width — and a capsule that animates its own width throws
        // the row it is in sideways. See `CanvasHeaderTrailingChrome`.
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: page.isLoading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Page controls, " + page.host))
    }
}

// MARK: - The address

/// Where the page is, and the way to send it somewhere else.
///
/// **A field rather than a caption**, which is most of what stops this feeling cramped: bare text
/// between two glyph buttons has no edges of its own, so it borrows theirs. A filled, inset, rounded box
/// gives the hostname its own space to sit in and, incidentally, says what it now is — something you can
/// click into and type.
///
/// It shows the **host** at rest and the **whole address** once you are editing it, which is what every
/// browser does and for the same reason: `example.com` is the answer to "whose page is this", and the
/// query string is only ever in the way until the moment you want to change it.
///
/// Return navigates. It does **not** change what the board has saved for the card — that is Pin's job,
/// and conflating them would mean a board quietly rewriting itself every time you looked something up
/// from one of its cards.
private struct CanvasAddressField: View {
    let page: CanvasHeaderModel.Page
    let width: CGFloat
    /// ⌘L, counted. See `CanvasHeaderModel.addressFocusToken`.
    let openToken: Int
    let go: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var focusToken = 0
    @State private var hovering = false

    var body: some View {
        ZStack {
            // **A crossfade, and the box it happens in is a fixed width.** That is the whole licence
            // for animating here: everything else in this capsule is forbidden to move because the row
            // is pinned to the window's trailing edge and grows leftward, but the address field is
            // `width` points wide whatever is inside it, so what happens in here stays in here.
            //
            // Worth drawing because the two states are not the same sentence. Clicking the chip
            // replaces `example.com` with the whole address, selected — a cut makes that read as the
            // page having navigated somewhere, which is precisely the thing it must not read as while
            // you are looking at a hostname to decide whether to type a password into it.
            //
            // A `ZStack` because that is what is being asked for: one box, two things in it, briefly
            // both. It was a `Group`, which said the same thing only by implication.
            if editing { field } else { chip }
        }
        .frame(width: width, height: HeaderMetrics.itemHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        .overlay {
            // A hairline only while wandered. At rest the fill alone is enough to read as a field, and
            // a permanent border in a row of borderless glyphs is one box too many.
            if page.wandered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
        .help(help)
        // Only over the field itself, not the capsule — a chip that lights when the pointer is anywhere
        // near it is a chip that has stopped telling you where the click lands.
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: page.wandered)
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovering)
        // Quick. The field it fades in is one you are about to type into, and a control that is still
        // arriving when your first keystroke lands is a control you have to wait for.
        .animation(Motion.animation(.easeOut(duration: 0.1)), value: editing)
        // ⌘L lands here: the same thing clicking the chip does, so there is one way in and one state
        // to be in afterwards.
        .onChange(of: openToken) { _, _ in openForEditing() }
    }

    private func openForEditing() {
        draft = page.liveAddress
        editing = true
        focusToken &+= 1
    }

    /// What it looks like when you are only reading it.
    private var chip: some View {
        Button(action: openForEditing) {
            Text(page.host)
                .font(.caption)
                .foregroundStyle(page.wandered ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Address, " + page.host))
        .accessibilityHint(Text("Edit the address this page is on"))
    }

    private var field: some View {
        CanvasAddressTextField(text: $draft, focusToken: focusToken) { typed in
            editing = false
            // Nothing typed that could be loaded leaves the page exactly where it was, rather than
            // navigating to a guess. See `CanvasAddress`.
            if let address = CanvasAddress.normalized(typed) { go(address) }
        } onCancel: {
            editing = false
        }
        .padding(.horizontal, 5)
    }

    /// The field's own ground. Brighter under the pointer, which is the only thing saying it takes a
    /// click at all — everything else in this capsule is a glyph, and a glyph reads as a button without
    /// having to be told.
    private var fill: AnyShapeStyle {
        if page.wandered {
            return AnyShapeStyle(Color.orange.opacity(hovering || editing ? 0.24 : 0.16))
        }
        return hovering || editing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)
    }

    private var help: String {
        var lines: [String] = []
        if page.wandered {
            lines.append("This card has navigated away from the address saved on the board.")
            lines.append("Saved: " + page.savedAddress)
        } else {
            lines.append(page.liveAddress)
        }
        if let age = page.age { lines.append("Loaded " + age) }
        return lines.joined(separator: "\n")
    }
}

/// A real `NSTextField`, bridged for the same reason `SearchField` is.
///
/// Return and Escape are the whole interaction here, and a SwiftUI `TextField` gives neither of them
/// reliably inside a hosting view that is floating over an AppKit board: Escape reaches the board's own
/// key handling before the field is done with it, and the field cannot say it wants the key. A delegate
/// answering `doCommandBy` can, which is the only place these two keys are unambiguous.
private struct CanvasAddressTextField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "Address"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // The field is a box of the address bar's width, not of its contents' — a long URL must scroll
        // inside it rather than push the capsule out to the width of a query string.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// The field's own height, not the item's. A text field's cell draws from the top of its frame
    /// rather than centring in it, so a field stretched to `itemHeight` puts the address a few points
    /// above where the chip had it, and clicking the chip reads as the text jumping. At its natural
    /// height the field is centred by the box around it, the same box that centres the chip.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        // Taking first responder from inside `updateNSView` re-enters SwiftUI's own update pass.
        afterCurrentUpdate {
            field.window?.makeFirstResponder(field)
            // Selected, not merely focused: clicking an address bar is nearly always about replacing
            // the address, and a caret dropped mid-hostname puts that work back on you.
            field.currentEditor()?.selectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: CanvasAddressTextField
        var lastFocusToken = -1
        /// Set by a Return, so the end-of-editing that follows it doesn't report itself as a cancel.
        private var committing = false

        init(_ parent: CanvasAddressTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                committing = true
                parent.onCommit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// Clicking away is a cancel. An address field left open over a board you have gone back to
        /// using is chrome you have to dismiss, and nothing here is worth making you dismiss it.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !committing else {
                committing = false
                return
            }
            parent.onCancel()
        }
    }
}

// MARK: - The window's tabs, in this header

/// The project window's tab bar as the board's header carries it.
///
/// A wrapper for one reason: the drop that puts a piece of this header level with the traffic lights is
/// the canvas header's own (`TitlebarDrop`, which reads measured button metrics off `CanvasHeaderModel`),
/// while the bar itself has to be the same view the task column renders and so cannot know about any of
/// that. The task column's header gets its clearance from `TitlebarClearance` on the strip as a whole
/// and needs no wrapper at all.
struct CanvasTabBar: View {
    @ObservedObject var model: CanvasHeaderModel
    @ObservedObject var tabs: ProjectTabModel

    var body: some View {
        ProjectTabBarHost(model: tabs)
            .modifier(TitlebarDrop(model: model))
    }
}
