import AppKit
import WebKit

/// A link previewed over the page, as Arc's Peek: ⇧-click a link in a space. docs/spaces.md § Browsing.
///
/// - A live page in a floating panel over the window, the window dimmed behind it.
/// - Same sign-ins, blocking and scripts as the card it came from (its configuration's store and
///   content controller).
/// - Open as Card (⌘↩) keeps it, as a new Today card in front; Esc, the close button or a click on the
///   dimmed window drops it.
/// - Links in the preview stay in the preview.
@MainActor
final class CanvasLinkPreview: NSView, WKNavigationDelegate, WKUIDelegate {
    private static weak var current: CanvasLinkPreview?

    private let web: WKWebView
    private let panel = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let keep: (String) -> Void
    /// The page it was ⇧-clicked from, which Open as Card moves the panel onto.
    private weak var source: WKWebView?
    /// Off for a Private card's preview, as for the card.
    private let recordsHistory: Bool

    static func show(_ url: URL, from source: WKWebView, keep: @escaping (String) -> Void) {
        guard let content = source.window?.contentView else { return }
        current?.close()
        let preview = CanvasLinkPreview(url: url, source: source, keep: keep)
        preview.frame = content.bounds
        preview.autoresizingMask = [.width, .height]
        content.addSubview(preview, positioned: .above, relativeTo: nil)
        preview.layoutPanel()
        current = preview
        preview.window?.makeFirstResponder(preview.web)
        preview.arrive()
    }

    /// The window dims and the panel grows from 97% out of the link you ⇧-clicked (0.2s). Under Reduce
    /// Motion, a fade only.
    private func arrive() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.isReduced ? Motion.Tempo.quick : Motion.Tempo.standard
            context.timingFunction = Motion.Curve.out
            animator().alphaValue = 1
        }
        guard !Motion.isReduced, let layer = panel.layer else { return }
        let click = panel.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let at = CGPoint(x: min(max(click.x, 0), panel.bounds.width), y: min(max(click.y, 0), panel.bounds.height))
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = Self.transform(layer, scale: CGSize(width: 0.97, height: 0.97),
                                        moving: CGPoint(x: at.x * 0.03, y: at.y * 0.03))
        grow.toValue = CATransform3DIdentity
        grow.duration = Motion.Tempo.standard
        grow.timingFunction = Motion.Curve.out
        layer.add(grow, forKey: "arrive")
    }

    /// A transform for the panel's layer that scales its bounds by `scale` from their origin and then
    /// moves them by `moving` — whatever anchor point AppKit gave the layer.
    private static func transform(_ layer: CALayer, scale: CGSize, moving: CGPoint) -> CATransform3D {
        let pivot = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let shift = CGPoint(x: moving.x + scale.width * pivot.x - pivot.x, y: moving.y + scale.height * pivot.y - pivot.y)
        return CATransform3DScale(CATransform3DMakeTranslation(shift.x, shift.y, 0), scale.width, scale.height, 1)
    }

    private init(url: URL, source: WKWebView, keep: @escaping (String) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = source.configuration.websiteDataStore
        configuration.userContentController = source.configuration.userContentController
        configuration.preferences = source.configuration.preferences
        configuration.defaultWebpagePreferences = source.configuration.defaultWebpagePreferences
        web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = source.customUserAgent
        self.keep = keep
        self.source = source
        recordsHistory = source.configuration.websiteDataStore.isPersistent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shadow = nil
        addSubview(panel)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.stringValue = url.host() ?? url.absoluteString
        let open = NSButton(title: "Open as Card", target: self, action: #selector(keepIt))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.keyEquivalent = "\r"
        open.keyEquivalentModifierMask = .command
        open.toolTip = "Keep it as a card in Today (⌘↩)"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.toolTip = "Close (Esc)"
        bar.setViews([titleLabel, NSView(), open, close], in: .leading)
        bar.identifier = NSUserInterfaceItemIdentifier("bar")
        panel.addSubview(bar)
        panel.addSubview(web)

        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutPanel()
    }

    private func layoutPanel() {
        let width = min(bounds.width - 80, 1100), height = bounds.height - 70
        panel.frame = NSRect(x: (bounds.width - width) / 2, y: 24, width: width, height: height)
        let barHeight: CGFloat = 36
        panel.subviews.first { $0.identifier?.rawValue == "bar" }?.frame =
            NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        web.frame = NSRect(x: 0, y: 0, width: width, height: height - barHeight)
    }

    /// A click on the dimmed window outside the panel closes it.
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// Keys reach here from the page when it doesn't want them: Esc closes.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return dismiss() }
        super.keyDown(with: event)
    }

    /// Open as Card: the panel moves onto the tile it came from (0.25s), where the card is about to
    /// be, and the dimming lifts; then the card takes its place. Under Reduce Motion, it fades.
    @objc private func keepIt() {
        let address = web.url?.absoluteString
        let finish = { [weak self] in
            self?.close(animated: false)
            if let address { self?.keep(address) }
        }
        guard !Motion.isReduced, let layer = panel.layer, let source, source.window === window else {
            return close(animated: true, then: { if let address { self.keep(address) } })
        }
        let target = convert(source.bounds, from: source)
        let from = panel.frame
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DIdentity
        move.toValue = Self.transform(layer, scale: CGSize(width: target.width / from.width, height: target.height / from.height),
                                      moving: CGPoint(x: target.minX - from.minX, y: target.minY - from.minY))
        move.duration = Motion.duration(0.25)
        move.timingFunction = Motion.Curve.out
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        let lift = CABasicAnimation(keyPath: "backgroundColor")
        lift.toValue = NSColor.clear.cgColor
        lift.duration = Motion.duration(0.25)
        lift.fillMode = .forwards
        lift.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        layer.add(move, forKey: "keep")
        self.layer?.add(lift, forKey: "keep")
        CATransaction.commit()
    }

    @objc private func dismiss() { close(animated: true) }

    /// Gone in one frame when replaced or kept; otherwise it fades out, quicker than it came (0.12s).
    private func close(animated: Bool = false, then: (() -> Void)? = nil) {
        web.stopLoading()
        if Self.current === self { Self.current = nil }
        guard animated else { removeFromSuperview(); then?(); return }
        closing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.Tempo.exit
            context.timingFunction = Motion.Curve.exit
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                then?()
            }
        })
    }

    /// Fading out: takes no more clicks or keys.
    private var closing = false
    override func hitTest(_ point: NSPoint) -> NSView? { closing ? nil : super.hitTest(point) }

    // MARK: The page

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        titleLabel.stringValue = [webView.title, webView.url?.host()].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " — ")
        if recordsHistory { CanvasHistory.record(webView.url, title: webView.title, profile: nil, counts: true) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
