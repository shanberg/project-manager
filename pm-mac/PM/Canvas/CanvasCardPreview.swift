import AppKit
import PmLib

/// A picture of the card a menu item names, beside the menu, while that item is highlighted.
///
/// **For the lists of cards already on the board** — Add Card from Canvas, Replace With, a strip's +.
/// A card's one-line name is often not enough to tell it from its neighbours: three pages on one site
/// share a favicon and most of a title. The picture is what you would recognise it by.
///
/// **The picture the board already has, never a new one.** A page's is the snapshot it left the last
/// time it stopped running (`CanvasPageSnapshots`); anything else is its card as drawn now. A page with
/// no snapshot gets no flyout rather than a blank one — waking a page to photograph it would cost a
/// load for a glance.
///
/// Set as the delegate of those menus by `CanvasBoardView.fillExistingCardsMenu`. A menu holds its
/// delegate weakly, so the board keeps this.
@MainActor
final class CanvasCardPreview: NSObject, NSMenuDelegate {
    /// The picture for a card id, or nil for none. Supplied by the board.
    var image: (String) -> NSImage? = { _ in nil }

    private lazy var panel = Panel()

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let id = item?.representedObject as? String, let picture = image(id),
              picture.size.width > 0, picture.size.height > 0,
              let beside = Self.menuWindow(near: NSEvent.mouseLocation) else { return hide() }
        panel.show(picture, beside: beside.frame, level: beside.level, pointerY: NSEvent.mouseLocation.y)
    }

    func menuDidClose(_ menu: NSMenu) { hide() }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The window the open menu is drawn in: the one under the pointer, else the newest menu window —
    /// highlighting by arrow keys leaves the pointer wherever it was, and the newest is the submenu the
    /// keys went into.
    ///
    /// There is no API for a menu's window or an item's rect, so this looks for it by its level, which
    /// is the one thing a menu window is sure to have.
    private static func menuWindow(near point: NSPoint) -> NSWindow? {
        let menus = NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
                                           && !($0 is Panel) }
        return menus.first { $0.frame.contains(point) } ?? menus.max { $0.windowNumber < $1.windowNumber }
    }

    /// Borderless, click-through and never key: a menu is tracking, and anything that took the
    /// keyboard or the pointer would close it.
    private final class Panel: NSPanel {
        private let imageView = NSImageView()

        /// The preview is a square this size, border included — a thumbnail, not a second window.
        private static let maxSide: CGFloat = 280
        private static let inset: CGFloat = 6
        private static let gap: CGFloat = 4

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: true)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            ignoresMouseEvents = true
            hidesOnDeactivate = true
            isReleasedWhenClosed = false
            animationBehavior = .none

            let ground = NSVisualEffectView()
            ground.material = .menu
            ground.state = .active
            ground.wantsLayer = true
            ground.layer?.cornerRadius = 10
            ground.layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 5
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            // Sized by the panel, never the other way round. An image view's intrinsic size is its
            // image's, and at the default priorities Auto Layout grows the window to hold a full-size
            // page snapshot — which is how the first version came out several times too large.
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                imageView.setContentCompressionResistancePriority(.init(1), for: axis)
                imageView.setContentHuggingPriority(.init(1), for: axis)
            }
            ground.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: Self.inset),
                imageView.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -Self.inset),
                imageView.topAnchor.constraint(equalTo: ground.topAnchor, constant: Self.inset),
                imageView.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -Self.inset),
            ])
            contentView = ground
        }

        /// The picture cropped to a square and drawn at `side`: **the top of a tall one**, which is where
        /// a page's title and a note's heading are, and the middle of a wide one.
        private static func square(_ picture: NSImage, side: CGFloat) -> NSImage {
            let full = picture.size
            let edge = min(full.width, full.height)
            // `NSImage` draws with its origin at the bottom, so the top is the highest y.
            let crop = NSRect(x: (full.width - edge) / 2, y: full.height - edge, width: edge, height: edge)
            return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                picture.draw(in: rect, from: crop, operation: .copy, fraction: 1)
                return true
            }
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        /// Beside the menu — trailing if the screen has room, else leading — centred on the pointer's
        /// height and kept on the screen. Always the same square, so moving down the list doesn't make
        /// the preview jump between shapes.
        func show(_ picture: NSImage, beside menu: NSRect, level: NSWindow.Level, pointerY: CGFloat) {
            let size = NSSize(width: Self.maxSide, height: Self.maxSide)
            let screen = (NSScreen.screens.first { $0.frame.intersects(menu) } ?? NSScreen.main)?.visibleFrame
                ?? menu
            var x = menu.maxX + Self.gap
            if x + size.width > screen.maxX { x = menu.minX - Self.gap - size.width }
            let y = min(max(pointerY - size.height / 2, screen.minY), screen.maxY - size.height)
            imageView.image = Self.square(picture, side: Self.maxSide - Self.inset * 2)
            self.level = NSWindow.Level(rawValue: level.rawValue + 1)
            setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
            orderFront(nil)
        }
    }
}

extension CanvasBoardView {
    /// The picture `CanvasCardPreview` shows for a card: a page's last snapshot at the board's shape,
    /// else at a tile's; any other card as it is drawn now, if it has a view to draw.
    func previewImage(for id: String) -> NSImage? {
        guard let node = document.node(id: id), !node.isGroup else { return nil }
        if case .link = node.content {
            let key = CanvasPageHandover.key(canvas: store.url, card: id)
            return CanvasPageSnapshots.of(key, tiled: false) ?? CanvasPageSnapshots.of(key, tiled: true)
        }
        guard let view = nodeViews[id], !view.bounds.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
