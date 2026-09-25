import AppKit

/// A question put up over the tile that asked it, rather than as a sheet pulled down over the window.
///
/// **A sheet belongs to the window, and a board is many things at once.** A page's `confirm()` in one
/// tile came down over all of them — the call in the next tile, the note beside it — and held the whole
/// window until it was answered, while saying nothing about which tile was asking. Safari answers a
/// page's dialog over that tab alone; this answers it over that tile alone. The tile dims and waits, and
/// everything else on the board, and every other window, carries on.
///
/// **Over the window when the tile is too small** to hold the panel with room around it: the window
/// dims instead, and the tile that asked is ringed, so the question still says whose it is.
///
/// **Drawn here, not by `NSAlert`**, which can only be a sheet or app-modal. It looks like one — an
/// icon, a bold title, the words, an accessory, the buttons, on a raised panel — and answers like one:
/// Return is the first button, Escape the Cancel.
///
/// **Not in the card**, which is scaled with the board and would scale the panel's text with it. In the
/// view that holds the board — the nearest scroll view's superview — or the window's content when there
/// is no board (a satellite), placed over wherever the anchor is drawn and following it: a tile resized
/// or scrolled, a tab put behind another (the panel hides with it), a card lent to a window and taken
/// back (the panel goes where it went). A card that goes altogether answers Cancel, since every one of
/// these has a caller waiting on its answer.
@MainActor
final class CanvasTileAlert: NSView {
    /// Something that asks from different places at different times — a card, which is on the board or
    /// out in a window of its own — and says where it is now. Asked again at every look, so a question
    /// follows the card rather than the view it was first put over.
    @MainActor
    protocol Asker: NSView {
        var alertAnchor: NSView { get }
    }

    struct Content {
        var title: String
        var message: String = ""
        var icon: NSImage?
        var accessory: NSView?
        var initialFirstResponder: NSView?
        /// In `NSAlert`'s order: the first is the default, and one titled Cancel is what Escape presses.
        var buttons: [String]
    }

    /// Every panel up, so a test (and the app) can find them.
    private(set) static var open: [CanvasTileAlert] = []

    /// Put `content` up over `anchor`, answering with the index of the button pressed. Nil when the
    /// anchor is in no window, which is the caller's to handle — there is nothing to put it over.
    @discardableResult
    static func present(_ content: Content, over asker: NSView,
                        then finish: @escaping (Int) -> Void) -> CanvasTileAlert? {
        let anchor = (asker as? Asker)?.alertAnchor ?? asker
        guard anchor.window != nil, let host = host(for: anchor) else { return nil }
        let alert = CanvasTileAlert(content, anchor: asker, finish: finish)
        alert.move(to: host)
        open.append(alert)
        alert.focus()
        alert.fadeIn()
        return alert
    }

    /// Where a panel over `anchor` goes: the view holding the board it is on, or its window's content.
    static func host(for anchor: NSView) -> NSView? {
        var view = anchor.superview
        while let current = view {
            if let scroll = current as? NSScrollView, let holder = scroll.superview { return holder }
            view = current.superview
        }
        return anchor.window?.contentView
    }

    private weak var asker: NSView?
    /// Where the panel is over now: the asker, or where the asker says it is.
    var anchor: NSView? { (asker as? Asker)?.alertAnchor ?? asker }
    private let content: Content
    private var finish: ((Int) -> Void)?
    let panel = NSView()
    private let glass = NSVisualEffectView()
    private(set) var buttons: [NSButton] = []
    /// Where the dimming is, in this view's coordinates: the anchor, or all of this view when the panel
    /// didn't fit.
    private(set) var region: NSRect = .zero
    /// The anchor's rectangle, for the ring when the panel is over the whole host.
    private(set) var ring: NSRect?
    private var watches: [NSObjectProtocol] = []
    private var checker: Timer?
    private var windowlessChecks = 0

    private init(_ content: Content, anchor: NSView, finish: @escaping (Int) -> Void) {
        self.content = content
        self.asker = anchor
        self.finish = finish
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The index Escape answers with: the button titled Cancel, else the last.
    var cancelIndex: Int { content.buttons.firstIndex(of: "Cancel") ?? max(0, content.buttons.count - 1) }

    // MARK: Answering

    /// Press button `index`: the panel goes and the caller hears.
    func answer(_ index: Int) {
        guard let finish else { return }
        self.finish = nil
        let anchorWindow = anchor?.window
        close()
        // The key focus goes back to what was asking, so typing picks up where the page left it.
        if let anchor, anchorWindow === anchor.window, !anchor.isHiddenOrHasHiddenAncestor {
            anchorWindow?.makeFirstResponder(Self.focusTarget(in: anchor))
        }
        finish(index)
    }

    private func close() {
        checker?.invalidate()
        checker = nil
        watches.forEach(NotificationCenter.default.removeObserver)
        watches = []
        Self.open.removeAll { $0 === self }
        removeFromSuperview()
    }

    /// The deepest view in `anchor` that takes the keys — a page, typically — or the anchor itself.
    private static func focusTarget(in anchor: NSView) -> NSView {
        var queue = [anchor]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view !== anchor, view.acceptsFirstResponder, !(view is NSControl) { return view }
            queue += view.subviews
        }
        return anchor
    }

    @objc private func pressed(_ sender: NSButton) { answer(sender.tag) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: answer(0)                  // Return, Enter
        case 53: answer(cancelIndex)            // Escape
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Following the anchor

    private func move(to host: NSView) {
        removeFromSuperview()
        translatesAutoresizingMaskIntoConstraints = true
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self, positioned: .above, relativeTo: nil)
        watch()
        follow()
    }

    /// Follow the anchor on every change that moves it, and look in on it a few times a second for the
    /// changes nothing announces: a tab going behind another, a card lent to a window or taken back.
    private func watch() {
        watches.forEach(NotificationCenter.default.removeObserver)
        watches = []
        var watched: [(NSNotification.Name, NSView)] = []
        var view: NSView? = anchor
        while let current = view, current !== superview {
            current.postsFrameChangedNotifications = true
            watched.append((NSView.frameDidChangeNotification, current))
            if let clip = current as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                watched.append((NSView.boundsDidChangeNotification, clip))
            }
            view = current.superview
        }
        for (name, object) in watched {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.follow() }
            })
        }
        if checker == nil {
            checker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookIn() }
            }
        }
    }

    /// The anchor went: into another window (follow it there), out of sight (hide with it), or out of
    /// every window for good (answer Cancel — twice running, so a card between two windows isn't lost).
    func lookIn() {
        guard let anchor, anchor.window != nil else {
            windowlessChecks += 1
            if windowlessChecks >= 2 { answer(cancelIndex) }
            return
        }
        windowlessChecks = 0
        if anchor.window !== window || !isDescendantOfHost(anchor), let host = Self.host(for: anchor), host !== superview {
            move(to: host)
            focus()
            return
        }
        follow()
    }

    private func isDescendantOfHost(_ anchor: NSView) -> Bool {
        guard let superview else { return false }
        return anchor.isDescendant(of: superview)
    }

    /// Place the dimming and the panel over where the anchor is drawn now.
    func follow() {
        guard let anchor, anchor.window === window, superview != nil else { return }
        isHidden = anchor.isHiddenOrHasHiddenAncestor
        // Its own bounds too: a view isn't clipped to them, and its visible rect can run past them.
        let over = convert(anchor.visibleRect.intersection(anchor.bounds), from: anchor).intersection(bounds)
        let size = panel.fittingSize
        let room = NSSize(width: size.width + 2 * Self.margin, height: size.height + 2 * Self.margin)
        if over.width >= room.width, over.height >= room.height {
            region = over
            ring = nil
        } else {
            region = bounds
            ring = over.isEmpty ? nil : over
        }
        panel.frame = NSRect(x: (region.midX - size.width / 2).rounded(),
                             y: (region.midY - size.height / 2).rounded(),
                             width: size.width, height: size.height)
        needsDisplay = true
    }

    /// Room kept around the panel inside the tile before it gives up and goes over the window.
    static let margin: CGFloat = 16

    // MARK: Taking the keys

    private func focus() {
        guard let window else { return }
        if let first = content.initialFirstResponder, first.window === window {
            window.makeFirstResponder(first)
        } else {
            window.makeFirstResponder(self)
        }
    }

    // MARK: Drawing and clicks

    /// Clicks in the dimming are the panel's: the tile underneath is waiting. Everywhere else is the
    /// board's, as if the panel weren't there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let local = superview.map({ convert(point, from: $0) }), region.contains(local) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) { focus() }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.isDark
        let radius: CGFloat = ring == nil ? 9 : 0
        NSColor.black.withAlphaComponent(dark ? 0.4 : 0.22).setFill()
        NSBezierPath(roundedRect: region, xRadius: radius, yRadius: radius).fill()
        if let ring {
            let path = NSBezierPath(roundedRect: ring.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func fadeIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    // MARK: The panel

    private func build() {
        panel.wantsLayer = true
        panel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .withinWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = NSColor.separatorColor.cgColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(glass)

        var rows: [NSView] = []
        if let icon = content.icon {
            let image = NSImageView(image: icon)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 40),
                                         image.heightAnchor.constraint(equalToConstant: 40)])
            rows.append(image)
        }
        let title = NSTextField(wrappingLabelWithString: content.title)
        title.font = .boldSystemFont(ofSize: 13)
        title.alignment = .center
        title.preferredMaxLayoutWidth = Self.width - 32
        rows.append(title)
        if !content.message.isEmpty {
            let message = NSTextField(wrappingLabelWithString: content.message)
            message.font = .systemFont(ofSize: 11)
            message.alignment = .center
            message.preferredMaxLayoutWidth = Self.width - 32
            message.isSelectable = true
            rows.append(message)
        }
        if let accessory = content.accessory {
            if accessory.translatesAutoresizingMaskIntoConstraints {
                let size = accessory.frame.size
                accessory.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([accessory.widthAnchor.constraint(equalToConstant: size.width),
                                             accessory.heightAnchor.constraint(equalToConstant: size.height)])
            }
            answerFields(in: accessory)
            rows.append(accessory)
        }

        buttons = content.buttons.enumerated().map { index, name in
            let button = NSButton(title: name, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.controlSize = .large
            if index == 0 { button.keyEquivalent = "\r" }
            if index == cancelIndex, index != 0 { button.keyEquivalent = "\u{1b}" }
            return button
        }
        // Two side by side, the default on the right, as an alert lays them out; more than two, stacked.
        let row = NSStackView(views: buttons.count == 2 ? buttons.reversed() : buttons)
        row.orientation = buttons.count == 2 ? .horizontal : .vertical
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        for button in buttons where buttons.count != 2 {
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: rows.last!)
        stack.addArrangedSubview(row)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: panel.topAnchor), glass.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: panel.leadingAnchor), glass.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            panel.widthAnchor.constraint(equalToConstant: Self.width),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        addSubview(panel)
    }

    static let width: CGFloat = 272

    /// Return in a field is the default button and Escape is Cancel, as in an alert: a field would
    /// otherwise keep both to itself.
    private func answerFields(in view: NSView) {
        if let field = view as? NSTextField, field.isEditable { field.delegate = self }
        view.subviews.forEach(answerFields(in:))
    }
}

extension CanvasTileAlert: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): answer(0); return true
        case #selector(NSResponder.cancelOperation(_:)): answer(cancelIndex); return true
        default: return false
        }
    }
}
