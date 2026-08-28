import SwiftUI
import AppKit
import PmLib

/// A note as it reads rather than as it's typed: its markdown rendered with the markers gone, and its
/// `![alt](path)` embeds drawn as the pictures they name.
///
/// It exists because a rendered note is not one run of text. Everything else markdown does — emphasis,
/// headings, links — is an attribute over characters, and `renderedMarkdown` puts it all in a single
/// `AttributedString` that one `Text` can draw. An image can't go in there: it has a size of its own
/// and a frame of its own. So the note is cut into pieces by `markdownNoteSegments` and the pieces are
/// stacked, with each prose run still rendered by `renderedMarkdown` — the images are the only thing
/// this adds, and a note without any lays out exactly as it did before.
///
/// No gestures of its own. This is a read view inside a selectable row, and the row owns the click:
/// one selects the session, two open the note. The editor is where an image is replaced or removed,
/// which is the same place its markdown was written.
///
/// Pictures are clipped to a rounded rectangle and given no border, which is what Messages does with
/// an image in the chat stream: the shape and the space around it do the separating, and a line drawn
/// round the edge would be one more thing in a list that is mostly text. A picture is a picture.
struct RenderedNote: View {
    let prose: String
    let font: NSFont
    var color: NSColor = .labelColor
    /// The note's own file, for resolving a relative embed or link against the folder it lives in.
    let noteURL: URL?
    /// The tallest a picture is drawn in the list. A note is read beside its tasks, and a screenshot
    /// allowed its natural height would push them off the screen — the note is the subject here, and
    /// the picture illustrates it. The editor's takeover is where a picture gets the whole column.
    var maxImageHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // By index: two identical embeds of the same picture are two segments, and dropping one of
            // them because they're equal would silently lose a line of the note.
            ForEach(Array(markdownNoteSegments(in: prose).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(renderedMarkdown(text, base: font, baseColor: color, note: noteURL))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let destination, let alt, let width):
                    NoteImage(destination: destination, alt: alt, width: width, noteURL: noteURL,
                              font: font, maxHeight: maxImageHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One embedded picture, or — when the file it names isn't there — a line saying so.
///
/// The missing case is drawn rather than skipped, and it says which file is missing. A note that
/// silently rendered nothing would be a note with a hole in it: the markdown is still in the file, the
/// picture is still referenced, and the only thing that changed is that something moved or renamed it.
private struct NoteImage: View {
    let destination: String
    let alt: String
    /// The width the note asked for, from an Obsidian embed's `![[shot.png|300]]`.
    let width: Double?
    let noteURL: URL?
    let font: NSFont
    let maxHeight: CGFloat

    private var url: URL? { markdownDestinationURL(destination, relativeTo: noteURL) }

    var body: some View {
        if let url, let image = NoteImageCache.shared.image(at: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                // One axis, never two. An aspect-fitting picture inside a frame bounded on *both*
                // sides is fitted into that box and left there — the leftover is empty frame, not
                // picture, and it's the frame that anything drawn around the edge follows. A portrait
                // screenshot under a 220pt height cap came out 66pt wide in a 300pt-wide box.
                //
                // So the height cap is restated as the width that produces it, and only the width is
                // constrained; the height then follows from the picture's own proportions and the box
                // is the picture. See `drawnWidth`.
                .frame(maxWidth: drawnWidth(image), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                .help(url.lastPathComponent)
        } else {
            missing
        }
    }

    /// The widest this picture is drawn: never blown up past what it is, never so wide that it breaks
    /// the height cap, and never wider than the note asked for.
    ///
    /// The height cap arrives here as a width because that's the only way to hold both without
    /// bounding both — at a fixed aspect ratio, "no taller than 220pt" and "no wider than 220pt times
    /// the aspect" are the same sentence, and the second one can be said on the axis the layout is
    /// already using. A note that named a width (`![[shot.png|300]]`) is someone saying the picture is
    /// a detail rather than the subject, and that beats the default.
    private func drawnWidth(_ image: NSImage) -> CGFloat {
        let aspect = image.size.width / image.size.height
        let asked = width.map { CGFloat($0) } ?? .greatestFiniteMagnitude
        return min(image.size.width, asked, maxHeight * aspect)
    }

    private var missing: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
            Text(alt.isEmpty ? (destination as NSString).lastPathComponent : alt)
        }
        .font(Font(font).italic())
        .foregroundStyle(.tertiary)
        .help("Missing image: \(destination)")
    }
}

/// Decoded note images, so a session row that redraws on every store change doesn't read the disk each
/// time it does.
///
/// Keyed by the file's modification date as well as its path, which is what makes it safe to hold
/// these at all: a picture replaced under the same name is a different key and reloads, and the entry
/// it replaced ages out. `NSCache` evicts under memory pressure on its own, and the count limit keeps
/// a note full of screenshots from being the thing that causes the pressure.
private final class NoteImageCache {
    static let shared = NoteImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 48 }

    func image(at url: URL) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else { return nil }
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)\t\(stamp)\t\(attributes[.size] as? Int ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Not `isValid`: an NSImage made from a file it can't decode reports a zero size and draws
        // nothing, which is the missing case wearing the wrong clothes.
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
