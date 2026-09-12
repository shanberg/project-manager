import AppKit

/// Whether a picture of a page has a page on it.
///
/// **This is how a card finds out that WebKit has painted something, which is the one thing the API
/// will not tell it.** The milestone a card wants is the first visually-non-empty layout, and it is
/// private (`_WKRenderingProgressEvent`). Its *effect* is not: a snapshot taken before it comes back
/// as one flat colour and a snapshot taken after comes back as a page. So the card asks for a very
/// small snapshot every so often and looks at it, which is a poll standing in for a notification and
/// reads the same fact off the other side.
///
/// **Measured, because the obvious shortcut is not one.** `suppressesIncrementalRendering` reads like
/// this milestone made public, and it is not: against a page that paints its shell and then holds a
/// request open for three seconds, a suppressed view's snapshots were blank for every one of ten
/// probes and came back only at `didFinish` — the property means what its documentation says, fully
/// loaded, which is the event this whole mechanism exists to stop waiting for. With incremental
/// rendering allowed the first probe after the shell painted saw it, 2.7 seconds earlier. That is why
/// `CanvasLinkNodeView` no longer suppresses.
///
/// Flat against the *first pixel* rather than against white, because "blank" is not a colour. An
/// unpainted view comes back as whatever WebKit will use as the page's ground: white for a page that
/// never mentions `color-scheme`, its dark canvas for one that opts in, and the card's own surface for
/// the moment before either is decided. All three are uniform, which is the property worth testing.
///
/// **Two per cent, and it has to be that low.** An app shell on a wide card is a bar across the top
/// and a spinner: at the size this is asked at, a handful of pixels. Anything stricter waits for the
/// content the shell is going to fetch, which is the whole complaint this was written for. The cost of
/// being too generous is a card revealed a frame early, under a cross-fade; the cost of being too
/// strict is the placeholder sitting over a page you could have been reading.
///
/// A tolerance of 8 over 255 on any channel, so a gradient or a subpixel-antialiased edge on an
/// otherwise empty page doesn't read as content.
enum CanvasPagePaint {
    static func hasSomethingOnIt(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return hasSomethingOnIt(cg)
    }

    static func hasSomethingOnIt(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 1, height > 1 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let layout = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: layout)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let ground = (pixels[0], pixels[1], pixels[2])
        var unlike = 0
        for start in stride(from: 0, to: pixels.count, by: 4) {
            let off = max(abs(Int(pixels[start]) - Int(ground.0)),
                          max(abs(Int(pixels[start + 1]) - Int(ground.1)),
                              abs(Int(pixels[start + 2]) - Int(ground.2))))
            if off > tolerance { unlike += 1 }
        }
        return Double(unlike) / Double(width * height) > share
    }

    /// How far off the ground a pixel has to be to count as drawn on.
    private static let tolerance = 8
    /// And how much of the picture has to be, before it is a page rather than a ground.
    private static let share = 0.02
}
