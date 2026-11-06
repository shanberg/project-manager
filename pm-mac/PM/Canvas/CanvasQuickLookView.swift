import AppKit
import Quartz
import QuickLookThumbnailing

/// A file card's body for any file the card has no viewer of its own for: Quick Look's (CSV, Office,
/// iWork, audio, video, code, fonts, 3D, and whatever Quick Look extensions are installed).
///
/// - At rest: Quick Look's thumbnail, a still picture. Cheap; a board of them costs nothing per frame.
/// - Live (`isLive`: stepped into, or a tile): `QLPreviewView`, the Finder's Space preview, scrolling
///   and playing. Its work runs out of process, so only live cards hold one.
/// - No thumbnail (Quick Look has only an icon): the file's icon and name.
@MainActor
final class CanvasQuickLookView: NSView {
    let url: URL

    /// Whether the live preview is up rather than the still.
    var isLive = false {
        didSet { if isLive != oldValue { showLiveOrStill() } }
    }

    private var live: QLPreviewView?
    private let still = NSImageView()
    private let name = NSTextField(labelWithString: "")
    /// The size the still was last asked for, so a resize only asks again when it grew.
    private var askedFor: CGSize = .zero
    private var thumbnailTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        still.imageScaling = .scaleProportionallyUpOrDown
        still.image = NSWorkspace.shared.icon(forFile: url.path)
        name.stringValue = url.lastPathComponent
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        addSubview(still)
        addSubview(name)
        setAccessibilityLabel(url.lastPathComponent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        live?.frame = bounds
        if hasThumbnail {
            still.frame = bounds.insetBy(dx: 8, dy: 8)
            name.isHidden = true
        } else {
            // The icon, middling, with the name under it.
            let side = min(64, bounds.width - 16, bounds.height - 40)
            still.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 - 10, width: max(side, 0), height: max(side, 0))
            name.isHidden = false
            name.frame = NSRect(x: 8, y: still.frame.maxY + 6, width: max(bounds.width - 16, 0), height: 18)
        }
        askForThumbnail()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { close() } else { showLiveOrStill() }
    }

    /// Lets go of the live preview. Also called when the card goes.
    func close() {
        thumbnailTask?.cancel()
        live?.close()
        live?.removeFromSuperview()
        live = nil
        askedFor = .zero
    }

    private var hasThumbnail = false

    private func showLiveOrStill() {
        guard window != nil else { return }
        if isLive, live == nil {
            guard let view = QLPreviewView(frame: bounds, style: .compact) else { return }
            view.shouldCloseWithWindow = false
            view.autostarts = false
            view.previewItem = url as NSURL
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            live = view
            Log.write("quick look live: \(url.pathExtension)")
        } else if !isLive, let view = live {
            view.close()
            view.removeFromSuperview()
            live = nil
        }
        still.isHidden = live != nil
        name.isHidden = live != nil || hasThumbnail
    }

    /// Quick Look's still at the card's size, asked again only when the card has grown past it.
    private func askForThumbnail() {
        let size = bounds.size
        guard window != nil, size.width > 20, size.height > 20,
              size.width > askedFor.width * 1.25 || size.height > askedFor.height * 1.25 else { return }
        askedFor = size
        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self, url] in
            let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard let self, !Task.isCancelled, self.url == url, let made else { return }
            // A CGImage already decoded, so drawing it decodes nothing on main.
            self.still.image = NSImage(cgImage: made.cgImage, size: .zero)
            self.hasThumbnail = true
            self.needsLayout = true
            self.showLiveOrStill()
        }
    }
}
