import AppKit
import SwiftUI

/// The window's trailing chrome: the board's controls, and — while you are standing in something on it
/// — that thing's, in a capsule beside them.
///
/// **Two capsules, and it was three.** The third was the page's, separate from the tile's, and the split
/// was drawn at the wrong joint: a tile and the thing inside it are not two scopes you move between,
/// they are one place described twice. On a web tile both were up at once, about the same object, each
/// ending in an `…` of its own — two overflow buttons a few points apart, which is a menu nobody can
/// aim at. So the tile capsule carries the controls for whatever kind of thing the tile holds, and there
/// is one menu at the end of it. See `CanvasTileCapsule`.
///
/// **One hosting view holding the pair**, rather than two views the pane would have to position. They
/// have to stay a pair: the control capsule is pinned to the window's trailing edge and the other grows
/// away from it leftward, which is the whole point of splitting them — stepping into a card must not
/// move Add and the options menu. Two separately-constrained views would have to agree about a gap and
/// about which of them collapses, and that agreement is what an `HStack` already is.
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
    var model: CanvasHeaderModel
    @State private var focus = HeaderPresence<CanvasHeaderModel.Focus>()
    /// The container's own namespace, so each capsule can say which piece of glass it is across a
    /// change of contents — see `headerBacking`. Without it a capsule that changes width arrives as a
    /// shape the container has never seen and its material is built again from nothing, which is what
    /// flashed when you moved between tiles of different kinds.
    @Namespace private var glass

    var body: some View {
        // **One container for both pieces of glass**, because glass cannot sample other glass and
        // pieces in separate containers render inconsistently beside one another. Its spacing is the
        // gap *inside* a capsule, well under the gap between them, so the two stay two at rest rather
        // than pooling into one blob.
        GlassEffectContainer(spacing: HeaderMetrics.gap) {
            // Bottom-aligned, so the capsules share a baseline whatever they turn out to be. They are
            // the same height today — one row of `itemHeight` in the same inset — and centring them
            // would hide it the day one of them isn't.
            HStack(alignment: .bottom, spacing: HeaderMetrics.capsuleGap) {
                // **First, so the scopes widen toward the window's edge**: what you are standing in,
                // then the board it is on. In a tiled view the focused tile *is* the engaged card
                // (`CanvasBoardView.tileClicked` selects and engages together), so one capsule is
                // describing one thing — which is why it is one capsule.
                if let shown = focus.shown {
                    CanvasTileCapsule(model: model, focus: shown)
                        .headerMaterialized(focus.materialized)
                }
                CanvasControlCapsule(model: model)
            }
            // On the row, which is always there — see `HeaderPresence`.
            .headerPresence(of: model.focus, in: $focus)
        }
        // Both capsules are shapes in this container, and each carries its own name inside it.
        .environment(\.headerGlassNamespace, glass)
        // The drop belongs to the row, not to any capsule in it. See `TitlebarDrop`.
        .modifier(TitlebarDrop(model: model))
    }
}

/// The one card whose page is live under your hands, and everything you do to it.
///
/// **Items rather than a capsule**, and it was a capsule. It sat beside the tile's, which on a web tile
/// meant two pieces of glass describing the same object at two scales and each ending in its own `…`.
/// These are now the leading run of `CanvasTileCapsule`, which is where the rest of what that tile can
/// be told already lived.
///
/// **Laid out the way a browser lays this out**: the buttons that move you through history, then where
/// you are, then — only when it applies — the two ways back to where the board says you should be. The
/// address used to come first, which put the one item in the row made of words between two runs of
/// glyphs with `HeaderMetrics.gap` on each side. Four points of air around a hostname is why this felt
/// tight; the reading order is why it felt unfamiliar.
struct CanvasPageControls: View {
    var model: CanvasHeaderModel
    let page: CanvasHeaderModel.Page

    var body: some View {
        Group {
            CanvasBackButton(page: page, back: model.pageBack, backTo: model.pageBackTo)
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
    }
}

// MARK: - What a page adds to the tile's menu

/// The page's half of the focused tile's `…` — see `CanvasTileCapsule`, which owns the menu.
///
/// **Commands that were only ever on the card's own right-click menu.** Stepping into a card took that
/// menu away: a right-click inside a live page is the *page's* menu now — Open Link as New Card, Add
/// Link to Project, and WebKit's own items — which is right, and it means the card's menu is reachable
/// only by stepping out first, from the one state where you are most likely to want it.
///
/// **Menu items rather than buttons.** Copy Address and Open in Browser each measured 26pt of a row
/// whose address field is 104pt at the narrow end, and each is a thing you do once in a session. A menu
/// is the shape for commands worth reaching and not worth staring at.
///
/// The last three are per *site* rather than per page — four cards on one tracker are one sign-in — so
/// they name the card's own site and not wherever the page has wandered to.
struct CanvasPageMenuItems: View {
    var model: CanvasHeaderModel
    let page: CanvasHeaderModel.Page

    var body: some View {
        Button("Copy Address", action: model.pageCopyAddress)
        Button("Open in Browser", action: model.pageOpenInBrowser)
        Divider()
        Button("Sign In to \(page.site)\u{2026}", action: model.pageSignIn)
        Button("Sign Out of \(page.site)", action: model.pageSignOut)
        Toggle("Block Ads on \(page.site)", isOn: Binding(
            get: { page.isFiltered }, set: model.pageSetFiltered))
    }
}

// MARK: - Back, and everywhere Back has been

/// Back, with the pages behind it on a press-and-hold.
///
/// **Zero points**: it is a gesture on a button that was already in the row, which is the whole reason
/// it is here rather than in a slot of its own. It is also what every browser does, so it is a gesture
/// people arrive already knowing — the one objection being that a hidden gesture is one nobody finds,
/// which is the complaint ⌘-click had before it reached a menu. The tooltip says so.
///
/// A `Menu` with a `primaryAction` rather than a long-press gesture and a popover: this is exactly the
/// control AppKit means by that, so the click, the hold, the keyboard path and the accessibility tree
/// are all the system's rather than four things to get right by hand. With nothing behind it the menu
/// would be empty, and an empty menu opening on a hold is worse than nothing happening — so a card with
/// no history gets a plain button.
private struct CanvasBackButton: View {
    let page: CanvasHeaderModel.Page
    let back: () -> Void
    let backTo: (Int) -> Void

    var body: some View {
        if page.back.isEmpty {
            HeaderSymbolButton(symbol: "chevron.left", help: "Back",
                               enabled: page.canGoBack, action: back)
        } else {
            Menu {
                ForEach(Array(page.back.enumerated()), id: \.offset) { step, item in
                    Button(item.title) { backTo(step + 1) }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
                    .contentShape(Rectangle())
            } primaryAction: {
                back()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
            .help("Back \u{2014} hold for where you have been")
            .accessibilityLabel(Text("Back"))
        }
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
        // The load, along the bottom edge of the field, inside its corner radius.
        //
        // **Here and not in a bar of its own**, which is the only reason it is affordable: it is two
        // points tall in a box that already exists at a fixed width, so it costs the row nothing and
        // cannot move anything sideways. And it belongs to the address — what is loading is what the
        // field is naming.
        .overlay(alignment: .bottomLeading) { progressBar }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
        // Only over the field itself, not the capsule — a chip that lights when the pointer is anywhere
        // near it is a chip that has stopped telling you where the click lands.
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: page.wandered)
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovering)
        // Quick. The field it fades in is one you are about to type into, and a control that is still
        // arriving when your first keystroke lands is a control you have to wait for.
        .animation(Motion.animation(.easeOut(duration: 0.1)), value: editing)
        // The bar advances rather than jumping, and leaves rather than completing. Inside the field's
        // fixed box, so it is free of the rule against animating width in this row.
        .animation(Motion.animation(.easeOut(duration: 0.25)), value: page.progress)
        .animation(Motion.animation(.easeOut(duration: 0.2)), value: page.isLoading)
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
            HStack(spacing: 4) {
                mark
                Text(page.host)
                    .font(.caption)
                    .foregroundStyle(page.wandered ? AnyShapeStyle(Color.orange)
                                                   : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Address, " + page.host))
        .accessibilityHint(Text(page.isSecure ? "Edit the address this page is on"
                                              : "Not encrypted. Edit the address this page is on"))
    }

    /// One slot at the head of the field, and two things that want it.
    ///
    /// **Whether the connection is safe wins, because it is the rarer answer and the louder one.** A
    /// lock on every https page is furniture — a mark that is always there is a mark nobody reads —
    /// and the state actually worth a glyph is the one the whole address readout exists for: you are
    /// about to type into a field on a page nobody encrypted. The site's icon takes the slot the rest
    /// of the time, which is nearly always, and is the fastest identity available at a width where
    /// the alternative is six more characters of hostname.
    @ViewBuilder private var mark: some View {
        if !page.isSecure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .help("This page is not encrypted.")
                .accessibilityHidden(true)
        } else if let icon = page.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
        }
    }

    /// A hairline, and only while something is arriving.
    ///
    /// **It never runs backwards and never sits at the end.** `estimatedProgress` is a well-known
    /// liar — it reaches nine tenths and stays there while a page finishes doing whatever it is really
    /// doing — so this is drawn as a thing that is happening rather than as a measurement: it fades
    /// out with the load rather than snapping to full, and the honest signal that a page has arrived
    /// is still the page.
    @ViewBuilder private var progressBar: some View {
        if page.isLoading, page.progress > 0 {
            GeometryReader { geometry in
                Rectangle()
                    .fill(page.wandered ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * page.progress, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
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
/// that.
struct CanvasTabBar: View {
    var model: CanvasHeaderModel
    var tabs: ProjectTabModel

    var body: some View {
        ProjectTabBarHost(model: tabs)
            .modifier(TitlebarDrop(model: model))
    }
}
