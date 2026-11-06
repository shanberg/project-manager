import AppKit
import WebKit

/// A picture of one of Folio's own windows, for the overview. docs/spaces.md § Overview.
///
/// - Taken in the app, not from the window server: capturing a window from outside needs Screen
///   Recording permission, and `CGWindowListCreateImage` is gone from the SDK.
/// - `cacheDisplay` draws the views but not WebKit's pages, which live in another process, so each
///   page showing is asked for its own picture (`takeSnapshot`) and laid over its place. The picture
///   comes back first without pages, then again with them.
/// - Kept per dock group for this session, so a closed space shows how it was left.
@MainActor
enum WindowSnapshot {
    private static var kept: [String: NSImage] = [:]

    /// The last picture of a group's window.
    static func last(_ key: String) -> NSImage? { kept[key] }

    /// A window going away: its last picture kept for its group.
    static func remember(_ window: NSWindow, key: String) {
        take(window) { kept[key] = $0 }
    }

    /// The window's picture now, kept for its group as well as handed to `update`.
    static func refresh(_ window: NSWindow, key: String, update: @escaping (NSImage) -> Void) {
        take(window) { image in
            kept[key] = image
            update(image)
        }
    }

    /// The window as it looks, `update` called once without its pages and once with them (or once,
    /// when it shows none). The first call is made before this returns.
    static func take(_ window: NSWindow, maxWidth: CGFloat = 1280, update: @escaping (NSImage) -> Void) {
        guard let root = window.contentView, root.bounds.width > 1, root.bounds.height > 1,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let size = root.bounds.size
        let scale = min(1, maxWidth / size.width)
        let out = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let background = window.backgroundColor ?? .windowBackgroundColor

        let density = window.backingScaleFactor
        // Drawn now into pixels, not as a drawing handler: a handler would run again in Core Animation's
        // commit each time the picture is shown.
        func compose(_ pages: [(NSImage, NSRect)]) -> NSImage {
            let image = NSImage(size: out)
            guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(out.width * density),
                                                pixelsHigh: Int(out.height * density), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                  else { return image }
            // Sized in points before the context is made, or the context draws a point per pixel: the
            // window in the bottom-left quarter on a Retina screen.
            pixels.size = out
            guard let context = NSGraphicsContext(bitmapImageRep: pixels) else { return image }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let bounds = NSRect(origin: .zero, size: out)
            background.setFill()
            bounds.fill()
            rep.draw(in: bounds)
            for (page, rect) in pages {
                page.draw(in: NSRect(x: rect.minX * scale, y: rect.minY * scale,
                                     width: rect.width * scale, height: rect.height * scale))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(pixels)
            return image
        }
        update(compose([]))

        let webs = pages(in: root)
        guard !webs.isEmpty else { return }
        var got: [(NSImage, NSRect)] = []
        var waiting = webs.count
        for web in webs {
            var rect = root.convert(web.bounds, from: web)
            if root.isFlipped { rect.origin.y = size.height - rect.maxY }
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    if let image { got.append((image, rect)) }
                    waiting -= 1
                    if waiting == 0, !got.isEmpty { update(compose(got)) }
                }
            }
        }
    }

    /// The pages on screen in a window: not hidden, and not scrolled wholly out of sight.
    private static func pages(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue == 0 { return }
            if let web = view as? WKWebView {
                if !web.visibleRect.isEmpty { found.append(web) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}
