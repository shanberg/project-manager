import AppKit
import WebKit

/// Where the link under the pointer goes, along the card's bottom-left edge — Safari's status bar.
///
/// **More needed here than in a browser.** A click in a browser costs a Back; ⌘-click on a card puts
/// a card on the board, which is written into the `.canvas` file. So the line says the address, and
/// with ⌘ held it says what ⌘-click is about to do.
///
/// **Fed by WebKit's private hover callback**, `_webView:mouseDidMoveOverElement:withFlags:userInfo:`
/// on the UI delegate (`WKUIDelegatePrivate`), which hands over a `_WKHitTestResult`. Read through
/// `value(forKey:)` so a WebKit that stops sending it leaves a card with no status line rather than
/// one that doesn't build.
final class CanvasLinkStatus: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hiding: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        alphaValue = 0
        isHidden = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// The pointer never lands on this line; it is about the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Put the line along the bottom-leading corner of `container`, above everything already in it.
    static func install(in container: NSView) -> CanvasLinkStatus {
        let status = CanvasLinkStatus()
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
        ])
        return status
    }

    /// What the line says for a hover, or nil for no line: not a link, or not one that goes anywhere.
    static func text(for link: URL?, flags: NSEvent.ModifierFlags) -> String? {
        guard let link, let scheme = link.scheme?.lowercased() else { return nil }
        if scheme == "javascript" { return nil }
        let address = ["http", "https"].contains(scheme)
            ? link.absoluteString.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            : link.absoluteString
        guard !address.isEmpty else { return nil }
        return flags.contains(.command) ? "Open as a new card: " + address : address
    }

    func show(_ text: String?) {
        hiding?.cancel()
        hiding = nil
        guard let text else {
            // Safari's pause: moving between two links shouldn't blink the line out and back.
            let work = DispatchWorkItem { [weak self] in self?.fade(in: false) }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }
        label.stringValue = text
        fade(in: true)
    }

    func hideNow() {
        hiding?.cancel()
        hiding = nil
        alphaValue = 0
        isHidden = true
    }

    private func fade(in shown: Bool) {
        if shown { isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(0.12)
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !shown, self.alphaValue == 0 else { return }
            self.isHidden = true
        }
    }
}
