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
        preview.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(0.15); preview.animator().alphaValue = 1 }
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

    @objc private func keepIt() {
        let address = web.url?.absoluteString
        close()
        if let address { keep(address) }
    }

    @objc private func dismiss() { close() }

    private func close() {
        web.stopLoading()
        removeFromSuperview()
    }

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
