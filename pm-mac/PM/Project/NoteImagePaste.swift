import AppKit
import PmLib

/// The image on a pasteboard, if there is one, as bytes worth writing to disk.
///
/// Two different things arrive under the name "an image", and a note wants opposite handling for each.
/// An image *file* — copied in the Finder, dragged out of a folder — already lives somewhere, and the
/// note should point at where it is rather than keep a second copy. An image with no file behind it —
/// a screenshot, a copy out of a browser or a design tool — exists only on the pasteboard, and unless
/// the note writes it down it's gone the next time something is copied. Only the second kind reaches
/// here; `imageFiles` answers the first.
enum NoteImagePasteboard {

    /// Image formats taken as they arrive, in the order a note would rather have them. PNG first
    /// because it's what a screenshot and most in-app copies are, and because it's lossless — a paste
    /// should be the picture that was copied, not a re-encoding of it.
    private static let verbatim: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
    ]

    /// Every type an image can arrive under, for registering a view's dragged types. Order doesn't
    /// matter to AppKit here — `imageData` decides what's preferred once something has been dropped.
    static var imageTypes: [NSPasteboard.PasteboardType] { verbatim.map(\.type) + [.tiff] }

    /// The image files on `pasteboard` — the ones that should be linked where they are, not copied.
    /// Nil rather than an empty array, so a caller can `guard let` its way to the next possibility.
    static func imageFiles(on pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let images = urls.filter { isMarkdownImagePath($0.path) }
        return images.isEmpty ? nil : images
    }

    /// The bytes to write for an image that has no file of its own, and the extension to write them
    /// under. Nil when the pasteboard holds no picture at all.
    static func imageData(on pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        // An image file's own bytes are its business — it's linked in place, not copied — and some
        // apps put a thumbnail on the pasteboard beside the file. Answering with the thumbnail would
        // write a small blurry copy of a picture that was already on disk.
        if imageFiles(on: pasteboard) != nil { return nil }
        for candidate in verbatim {
            if let data = pasteboard.data(forType: candidate.type), !data.isEmpty {
                return (data, candidate.ext)
            }
        }
        // TIFF is the lowest common denominator every Mac app can put down, and it's what a paste from
        // an app that offers nothing better comes through as. Re-encoded rather than written: a
        // screen-sized TIFF is tens of megabytes of a vault's disk for a picture PNG stores in one.
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }
}
