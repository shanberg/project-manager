import AppKit
import SwiftUI

// MARK: - The address

/// Where the page is, and the way to send it somewhere else — drawn and driven the way Safari's is.
///
/// **At rest it says whose page this is**: the site's icon and the whole address, centred in a capsule,
/// the site at full strength and the path after it lighter, with Reload at its trailing end. Reload
/// lives *inside* the field for Safari's reason — it is a verb about the address the field is naming —
/// and it gave the row a button's width back to spend on the address.
///
/// **Clicked, it is the whole address, selected and left-aligned**, ready to be replaced. Typing offers
/// pages from this Mac underneath (`CanvasAddressSuggestions`) and fills in the rest of an address after
/// the caret; ↑↓ move through the list, Return goes, Tab accepts the filled-in part, and Escape puts the
/// address back before it closes the field. Words that aren't an address are a search, on the engine
/// chosen in Settings, and go nowhere without one — see `CanvasAddress`.
///
/// Return navigates. It does **not** change what the board has saved for the card — that is Pin's job,
/// and conflating them would mean a board quietly rewriting itself every time you looked something up
/// from one of its cards.
struct CanvasAddressField: View {
    let page: CanvasHeaderModel.Page
    let width: CGFloat
    /// ⌘L, counted. See `CanvasHeaderModel.addressFocusToken`.
    let openToken: Int
    let go: (String) -> Void
    let reload: () -> Void
    let hardReload: () -> Void
    let emptyCacheAndReload: () -> Void
    let stop: () -> Void
    let candidates: () -> [CanvasAddressSuggestions.Candidate]

    @State private var editing = false
    @State private var draft = ""
    @State private var focusToken = 0
    @State private var hovering = false
    /// Read when the field opens, so a change in Settings applies to the next edit rather than to half
    /// of this one.
    @State private var engine = CanvasSearchEngine.none
    @State private var candidateList: [CanvasAddressSuggestions.Candidate] = []

    /// The room Reload takes at the trailing end, and the same again at the leading end so the host
    /// is centred in the capsule rather than in what Reload leaves of it.
    private static let buttonRoom: CGFloat = 22

    var body: some View {
        ZStack {
            // **A crossfade, and the box it happens in is a fixed width.** Everything else in this row
            // is forbidden to move because the row is pinned to the window's trailing edge and grows
            // leftward (`CanvasHeaderTrailingChrome`), but the field is `width` points wide whatever is
            // inside it, so what happens in here stays in here.
            //
            // Worth drawing because the two states are not the same sentence: a cut from `example.com`
            // to a whole address reads as the page having navigated, which is precisely the thing it
            // must not read as while you are deciding whether to type a password into it.
            if editing { field } else { chip }
        }
        .frame(width: width, height: HeaderMetrics.itemHeight)
        .background(Capsule(style: .continuous).fill(fill))
        // The load, along the bottom edge of the field, inside its curve. Two points tall in a box that
        // already exists at a fixed width, so it costs the row nothing.
        .overlay(alignment: .bottomLeading) { progressBar }
        .clipShape(Capsule(style: .continuous))
        .help(editing ? "" : help)
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovering)
        // Quick. The field it fades in is one you are about to type into, and a control that is still
        // arriving when your first keystroke lands is a control you have to wait for.
        .animation(Motion.animation(.easeOut(duration: 0.1)), value: editing)
        .animation(Motion.animation(.easeOut(duration: 0.25)), value: page.progress)
        .animation(Motion.animation(.easeOut(duration: 0.2)), value: page.isLoading)
        // ⌘L lands here: the same thing clicking the chip does, so there is one way in and one state
        // to be in afterwards.
        .onChange(of: openToken) { _, _ in openForEditing() }
    }

    private func openForEditing() {
        draft = page.liveAddress
        engine = CanvasSearchEngine.current
        candidateList = candidates()
        editing = true
        focusToken &+= 1
    }

    /// What it looks like when you are only reading it.
    private var chip: some View {
        ZStack(alignment: .trailing) {
            Button(action: openForEditing) {
                HStack(spacing: 4) {
                    sessionPill
                    mark
                    addressText
                }
                // The leading room exists to centre the host against Reload's width at the other end.
                // A pill has already taken that space and is doing the same job for the eye, so it
                // stands in for the padding rather than being added to it.
                .padding(.leading, page.session == nil ? Self.buttonRoom : 6)
                .padding(.trailing, Self.buttonRoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibleAddress))
            .accessibilityHint(Text(page.isSecure ? "Edit the address this page is on"
                                                  : "Not encrypted. Edit the address this page is on"))

            reloadButton
        }
    }

    /// The whole address, with the site at full strength and the page within it lighter.
    ///
    /// **Cut off at the tail**, because the head is the part that has to survive: a long path losing its
    /// end still says whose page this is, and a host losing its middle stops saying it.
    private var addressText: some View {
        let (origin, rest) = CanvasAddress.splitAtOrigin(page.liveAddress)
        return Text("\(Text(origin).foregroundStyle(.primary))\(Text(rest).foregroundStyle(.tertiary))")
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Reload, or Stop while the page is arriving — one button, so the swap is a glyph changing in
    /// place rather than a removal and an insertion. See `HeaderSymbolButton`.
    ///
    /// ⌥-click is a hard reload, the same ⌥ that turns Reload Page into Hard Reload in the Page menu.
    /// Right-click lists the kinds of reload, and is offered while the page is loading too: a load that
    /// is stuck on a stale file is the moment you want it.
    private var reloadButton: some View {
        Button(action: pressReload) {
            Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.secondary)
                .frame(width: Self.buttonRoom, height: HeaderMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(page.isLoading ? "Stop loading" : "Reload")
        .accessibilityLabel(Text(page.isLoading ? "Stop loading" : "Reload"))
        .contextMenu {
            Button("Reload Page", action: reload)
            Button("Hard Reload", action: hardReload)
            Button("Empty Cache and Reload", action: emptyCacheAndReload)
        }
    }

    private func pressReload() {
        if page.isLoading { return stop() }
        NSEvent.modifierFlags.contains(.option) ? hardReload() : reload()
    }

    /// Which jar this card drinks from, ahead of the address — and nothing at all for the shared
    /// session, which is nearly every card.
    ///
    /// **In the address bar, in both of its states.** This row is where the page says whose it is, and
    /// the session is the other half of that sentence: the same host signed in as somebody else is a
    /// different page in every sense that matters, and a private card is one whose sign-in nothing is
    /// keeping. The pill is drawn while you are typing too, because that is the moment the answer is
    /// worth most — see the crossfade above, which exists for the same argument about passwords.
    @ViewBuilder private var sessionPill: some View {
        if let session = page.session {
            CanvasSessionPill(name: session.name, isPrivate: session.isPrivate)
        }
    }

    /// One slot at the head of the host, and two things that want it.
    ///
    /// **Whether the connection is safe wins, because it is the rarer answer and the louder one.** A lock
    /// on every https page is furniture; the state worth a glyph is the one the whole readout exists for,
    /// a page nobody encrypted. The site's icon takes the slot the rest of the time.
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

    /// A hairline, and only while something is arriving. It fades out with the load rather than
    /// snapping to full — `estimatedProgress` sits at nine tenths for as long as it likes, and the
    /// honest signal that a page has arrived is still the page.
    @ViewBuilder private var progressBar: some View {
        if page.isLoading, page.progress > 0 {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * page.progress, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var field: some View {
        HStack(spacing: 4) {
            sessionPill
            Image(systemName: engine == .none ? "globe" : "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            CanvasAddressTextField(
                text: $draft, focusToken: focusToken, engine: engine, candidates: candidateList,
                originalAddress: page.liveAddress, boxWidth: width,
                placeholder: engine == .none ? "Enter an address"
                                             : "Search \(engine.name) or enter an address"
            ) { address in
                editing = false
                // Nothing that could be loaded leaves the page exactly where it was, rather than
                // navigating to a guess.
                if let address { go(address) }
            } onCancel: {
                editing = false
            }
        }
        .padding(.horizontal, 8)
    }

    /// The field's own ground. Brighter under the pointer, which is the only thing saying it takes a
    /// click at all — everything else in this capsule is a glyph.
    private var fill: AnyShapeStyle {
        hovering || editing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)
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
        if let session = page.session {
            lines.append(CanvasSessionPill.explanation(name: session.name, isPrivate: session.isPrivate))
        }
        return lines.joined(separator: "\n")
    }

    /// The host, and whose sign-in it is being read with — the pill is inside the button, so this is
    /// the only place VoiceOver can be told about it.
    private var accessibleAddress: String {
        guard let session = page.session else { return "Address, " + page.host }
        return "Address, \(page.host), \(session.isPrivate ? "private session" : "\(session.name) session")"
    }
}

// MARK: - The text field

/// A real `NSTextField`, bridged for the same reason `SearchField` is.
///
/// Return, Escape, Tab and the arrow keys are the whole interaction here, and a SwiftUI `TextField` gives
/// none of them reliably inside a hosting view floating over an AppKit board. A delegate answering
/// `doCommandBy` can, which is the only place these keys are unambiguous — and the inline completion
/// needs the field editor's selection, which SwiftUI does not expose at all.
private struct CanvasAddressTextField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var engine: CanvasSearchEngine
    var candidates: [CanvasAddressSuggestions.Candidate]
    /// What Escape puts back.
    var originalAddress: String
    /// The capsule's width, which the suggestions line up under.
    var boxWidth: CGFloat
    var placeholder: String
    /// Where to go, or nil for nowhere.
    var onCommit: (String?) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // The field is a box of the address bar's width, not of its contents' — a long URL must scroll
        // inside it rather than push the capsule out to the width of a query string.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    /// The field's own height, not the item's. A text field's cell draws from the top of its frame
    /// rather than centring in it, so a field stretched to `itemHeight` puts the address a few points
    /// above where the chip had it. At its natural height it is centred by the box around it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.began(with: text)
        // Taking first responder from inside `updateNSView` re-enters SwiftUI's own update pass.
        afterCurrentUpdate {
            field.window?.makeFirstResponder(field)
            // Selected, not merely focused: clicking an address bar is nearly always about replacing
            // the address, and a caret dropped mid-hostname puts that work back on you.
            field.currentEditor()?.selectAll(nil)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.hideSuggestions()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: CanvasAddressTextField
        weak var field: NSTextField?
        var lastFocusToken = -1
        /// Set by a Return or a picked row, so the end-of-editing that follows doesn't report itself as
        /// a cancel.
        private var committing = false

        /// What you typed, without whatever was filled in after it. The completion is decided against
        /// this, so it can tell typing a character from deleting one.
        private var typed = ""
        private var completion: CanvasAddressSuggestions.Completion?
        private let list = CanvasAddressSuggestionList()
        private lazy var panel = CanvasAddressSuggestionPanel(list: list) { [weak self] row in
            self?.pick(row)
        }

        fileprivate init(_ parent: CanvasAddressTextField) { self.parent = parent }

        func began(with text: String) {
            typed = text
            completion = nil
            hideSuggestions()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            let text = field.stringValue
            let length = (text as NSString).length
            // Only a keystroke that added to the end is completed. Filling back in what you just
            // deleted would make the completion impossible to get rid of.
            let appended = length > (typed as NSString).length
                && editor.selectedRange().location == length
                && !editor.hasMarkedText()
            typed = text

            let matches = CanvasAddressSuggestions.matches(text, in: parent.candidates)
            completion = appended ? CanvasAddressSuggestions.completion(for: text, from: matches) : nil
            if let completion, completion.text != text {
                field.stringValue = completion.text
                editor.selectedRange = NSRange(location: length,
                                               length: (completion.text as NSString).length - length)
            }
            parent.text = field.stringValue
            showSuggestions(matches)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                committing = true
                let address = destination(for: control.stringValue)
                hideSuggestions()
                parent.onCommit(address)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Safari's two-step Escape: the first puts the address back, the second leaves.
                if control.stringValue != parent.originalAddress {
                    control.stringValue = parent.originalAddress
                    parent.text = parent.originalAddress
                    began(with: parent.originalAddress)
                    textView.selectAll(nil)
                } else {
                    hideSuggestions()
                    parent.onCancel()
                }
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                guard !list.rows.isEmpty else { return false }
                list.move(by: selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Accept what was filled in, and keep typing after it.
                guard let completion, control.stringValue == completion.text else { return false }
                typed = completion.text
                textView.selectedRange = NSRange(location: (completion.text as NSString).length, length: 0)
                return true
            default:
                return false
            }
        }

        /// Clicking away is a cancel. An address field left open over a board you have gone back to
        /// using is chrome you have to dismiss, and nothing here is worth making you dismiss it.
        func controlTextDidEndEditing(_ notification: Notification) {
            hideSuggestions()
            guard !committing else {
                committing = false
                return
            }
            parent.onCancel()
        }

        /// Where Return goes: a row you chose, else the address that was filled in, else what the
        /// text says.
        private func destination(for text: String) -> String? {
            if list.isChosen, let row = list.selectedRow { return row.address }
            if let completion, completion.text == text { return completion.address }
            return CanvasAddress.resolved(text, engine: parent.engine)
        }

        private func pick(_ row: CanvasAddressSuggestionRow) {
            committing = true
            hideSuggestions()
            parent.onCommit(row.address)
        }

        // MARK: The list

        private func showSuggestions(_ matches: [CanvasAddressSuggestions.Suggestion]) {
            let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            // The page the completion came from is the top hit, and goes first so the highlighted row
            // and the filled-in text are the same answer.
            var pages = matches
            var rows: [CanvasAddressSuggestionRow] = []
            if completion != nil, let top = pages.firstIndex(where: {
                CanvasAddressSuggestions.completion(for: typed, from: [$0]) != nil
            }) {
                rows.append(.init(pages.remove(at: top)))
            }
            let search = parent.engine.searchAddress(for: query).map {
                CanvasAddressSuggestionRow(search: query, engine: parent.engine.name, address: $0)
            }
            if let search { rows.append(search) }
            rows += pages.map(CanvasAddressSuggestionRow.init)

            // The row lit up is the one Return would take anyway, so nothing changes by pressing it.
            let lit: Int? = if completion != nil {
                0
            } else if CanvasAddress.normalized(query) == nil, search != nil {
                rows.firstIndex { $0.isSearch }
            } else {
                nil
            }
            list.show(rows, selecting: lit)

            guard !rows.isEmpty, let field, let window = field.window else { return hideSuggestions() }
            panel.present(under: field, in: window, boxWidth: parent.boxWidth)
        }

        func hideSuggestions() {
            list.show([], selecting: nil)
            panel.dismiss()
        }
    }
}

// MARK: - The suggestions

struct CanvasAddressSuggestionRow: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var address: String
    var symbol: String
    /// Whose icon to draw, when there is one.
    var host: String?
    var isSearch = false

    init(_ suggestion: CanvasAddressSuggestions.Suggestion) {
        id = suggestion.id
        title = suggestion.title
        detail = suggestion.shownAddress
        address = suggestion.address
        symbol = suggestion.source == .board ? "square.on.square" : "clock"
        host = URL(string: suggestion.address)?.host()
    }

    init(search query: String, engine: String, address: String) {
        id = "search"
        title = query
        detail = "Search " + engine
        self.address = address
        symbol = "magnifyingglass"
        isSearch = true
    }
}

/// The rows under the field and which one is lit — shared by the field's keys and the panel's mouse.
@MainActor
@Observable
final class CanvasAddressSuggestionList {
    static let rowHeight: CGFloat = 26
    static let inset: CGFloat = 5

    private(set) var rows: [CanvasAddressSuggestionRow] = []
    private(set) var selected: Int?
    /// Whether the lit row was chosen — by an arrow key or the pointer — rather than lit by default.
    /// Only a chosen row overrides what the text says; see `Coordinator.destination`.
    private(set) var isChosen = false

    var selectedRow: CanvasAddressSuggestionRow? {
        selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    var height: CGFloat { CGFloat(rows.count) * Self.rowHeight + Self.inset * 2 }

    func show(_ rows: [CanvasAddressSuggestionRow], selecting index: Int?) {
        self.rows = rows
        selected = index
        isChosen = false
    }

    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = selected.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        selected = min(max(next, 0), rows.count - 1)
        isChosen = true
    }

    func point(at index: Int?) {
        guard let index, rows.indices.contains(index), index != selected else { return }
        selected = index
        isChosen = true
    }

    func row(atY y: CGFloat) -> Int? {
        let index = Int(floor((y - Self.inset) / Self.rowHeight))
        return y >= Self.inset && rows.indices.contains(index) ? index : nil
    }
}

/// The list's own window, hanging under the field.
///
/// **A child panel rather than a popover or an overlay.** The header's hosting view is a strip a
/// capsule tall, so anything drawn in it is clipped at the titlebar; a popover brings an arrow and takes
/// key status, which would take the keyboard out of the field you are typing in. A panel that can never
/// become key leaves the field first responder the whole time, and as a child window it moves with the
/// project window.
private final class CanvasAddressSuggestionPanel: NSPanel {
    private let list: CanvasAddressSuggestionList

    init(list: CanvasAddressSuggestionList, pick: @escaping (CanvasAddressSuggestionRow) -> Void) {
        self.list = list
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false

        let material = NSVisualEffectView()
        material.material = .menu
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true

        let rows = SuggestionRowsView(list: list, pick: pick)
        rows.frame = material.bounds
        rows.autoresizingMask = [.width, .height]
        material.addSubview(rows)
        contentView = material
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(under field: NSTextField, in window: NSWindow, boxWidth: CGFloat) {
        let onScreen = window.convertToScreen(field.convert(field.bounds, to: nil))
        // The capsule's trailing edge is the field's plus its padding; its leading edge follows. The
        // list lines up with the capsule and is never narrower than a page title needs.
        let boxMaxX = onScreen.maxX + 8
        let width = max(boxWidth, 380)
        var x = boxMaxX - boxWidth
        x = min(x, window.frame.maxX - 8 - width)
        x = max(x, window.frame.minX + 8)
        let top = onScreen.midY - HeaderMetrics.itemHeight / 2 - 6
        setFrame(NSRect(x: x, y: top - list.height, width: width, height: list.height), display: true)
        invalidateShadow()
        if parent == nil { window.addChildWindow(self, ordered: .above) }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// The rows, drawn in SwiftUI and clicked in AppKit.
///
/// **The mouse is handled here rather than by SwiftUI buttons**, because the panel is never key and a
/// SwiftUI control in a window that is not key does not reliably take the first click. The rows are a
/// fixed height, so which one is under the pointer is arithmetic.
private final class SuggestionRowsView: NSHostingView<CanvasAddressSuggestionListView> {
    private let list: CanvasAddressSuggestionList
    private let pick: (CanvasAddressSuggestionRow) -> Void

    init(list: CanvasAddressSuggestionList, pick: @escaping (CanvasAddressSuggestionRow) -> Void) {
        self.list = list
        self.pick = pick
        super.init(rootView: CanvasAddressSuggestionListView(list: list))
    }

    @MainActor required init(rootView: CanvasAddressSuggestionListView) { fatalError("init(list:pick:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(list:pick:)") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { list.point(at: row(for: event)) }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(for: event) else { return }
        pick(list.rows[index])
    }

    private func row(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return list.row(atY: isFlipped ? point.y : bounds.height - point.y)
    }
}

private struct CanvasAddressSuggestionListView: View {
    var list: CanvasAddressSuggestionList

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRowView(row: row, lit: list.selected == index)
            }
        }
        .padding(.vertical, CanvasAddressSuggestionList.inset)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SuggestionRowView: View {
    let row: CanvasAddressSuggestionRow
    let lit: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .layoutPriority(1)
            Text("\u{2014} " + row.detail)
                .font(.system(size: 13))
                .foregroundStyle(lit ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: CanvasAddressSuggestionList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(lit ? Color.accentColor : Color.clear))
    }

    @ViewBuilder private var icon: some View {
        if let host = row.host, let favicon = FaviconLoader.shared.cached(for: host) {
            Image(nsImage: favicon).resizable().interpolation(.high)
        } else {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
    }
}
