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
struct CanvasHeaderTrailingChrome: View {
    @ObservedObject var model: CanvasHeaderModel

    var body: some View {
        // Bottom-aligned, so the two capsules share a baseline whatever they turn out to be. They are
        // the same height today — one row of `itemHeight` in the same inset — and centring them would
        // hide it the day one of them isn't.
        HStack(alignment: .bottom, spacing: HeaderMetrics.capsuleGap) {
            if let page = model.page {
                CanvasPageCapsule(model: model, page: page)
                    .transition(.blurReplace)
            }
            CanvasControlCapsule(model: model)
        }
        .animation(Motion.animation(.snappy(duration: 0.22)), value: model.page == nil)
        // The drop belongs to the row, not to either capsule in it. See `TitlebarDrop`.
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
    @State private var hovering = false

    private var chrome: HeaderChrome { HeaderChrome(active: controlActiveState, hovering: hovering) }

    var body: some View {
        HeaderCapsule(chrome: chrome) {
            HeaderSymbolButton(symbol: "chevron.left", help: "Back",
                               enabled: page.canGoBack, action: model.pageBack)
            HeaderSymbolButton(symbol: "chevron.right", help: "Forward",
                               enabled: page.canGoForward, action: model.pageForward)
            // Reload and Stop are one button because they are one question — "is this page still
            // arriving?" — and a card answers it nowhere else. A card is drawn as its *old* page until
            // the new one paints, so without this the only sign that a click did anything is the page
            // eventually changing.
            if page.isLoading {
                HeaderSymbolButton(symbol: "xmark", help: "Stop loading", action: model.pageStop)
            } else {
                HeaderSymbolButton(symbol: "arrow.clockwise", help: "Reload", action: model.pageReload)
            }

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
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: page.wandered)
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: page.isLoading)
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: model.room)
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
        Group {
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: HeaderMetrics.itemHeight)
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
