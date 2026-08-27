import Foundation

// Images in a note: which files count as one, where an `![alt](path)` embed sits in the source, how a
// note splits into the prose and the pictures a read view has to draw separately, and where an image
// pasted into a note is written to disk.
//
// The split matters because a rendered note is not one run of text. Everything else markdown does —
// emphasis, headings, links — is an attribute over characters, and an attributed string carries it. An
// image is not: it's a view of its own with a size of its own, so a renderer has to be handed the note
// in pieces and put the pieces in a stack. `markdownNoteSegments` is that cut, and it's here rather
// than in the view so it unit-tests without a window.

/// File extensions a note embeds as a picture rather than links to. Lowercased.
public let markdownImageExtensions: Set<String> =
    ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "tiff", "tif", "bmp"]

/// Whether a path names an image — the question both the drop handler ("embed or link?") and the read
/// view ("draw or ignore?") ask, answered in one place so they can't disagree.
public func isMarkdownImagePath(_ path: String) -> Bool {
    markdownImageExtensions.contains((path as NSString).pathExtension.lowercased())
}

// MARK: - Locating embeds

/// A located `![alt](destination)` embed: where the whole construct sits, and what it points at.
public struct MarkdownImage: Equatable {
    public let range: Range<String.Index>
    public let alt: String
    public let destination: String
    public init(range: Range<String.Index>, alt: String, destination: String) {
        self.range = range
        self.alt = alt
        self.destination = destination
    }
}

/// `![alt](destination)`, with an alt that's allowed to be empty — the form an image pasted by a tool
/// that had no name for it takes.
let markdownImageRE = try? NSRegularExpression(pattern: #"(!)\[([^\]\n]*)\]\(([^)\n]+)\)"#)

/// Locate the image embeds in `text`, in source order.
public func markdownImages(in text: String) -> [MarkdownImage] {
    let full = NSRange(location: 0, length: (text as NSString).length)
    var out: [MarkdownImage] = []
    markdownImageRE?.enumerateMatches(in: text, range: full) { m, _, _ in
        guard let m,
              let whole = Range(m.range, in: text),
              let alt = Range(m.range(at: 2), in: text),
              let destination = Range(m.range(at: 3), in: text) else { return }
        out.append(MarkdownImage(range: whole, alt: String(text[alt]),
                                 destination: String(text[destination])))
    }
    return out
}

// MARK: - Splitting a note for rendering

/// A piece of a note as a read view has to draw it: a run of markdown, or a picture.
public enum MarkdownNoteSegment: Equatable {
    /// Markdown to render as text. Never empty, and never contains an image embed.
    case prose(String)
    case image(destination: String, alt: String)
}

/// Cut `text` into the prose runs and the image embeds between them, in source order.
///
/// Every embed becomes a segment of its own, including one written mid-sentence: an image in a note is
/// a block, and the alternative — a picture set inline in a line of text — is a typographic problem
/// (baseline, line height, wrapping) for a gain no note has ever wanted. The prose on either side keeps
/// its own markdown and is trimmed of the blank lines the embed leaves behind, so a picture on its own
/// line doesn't open a hole above and below itself.
///
/// A note with no images comes back as a single `.prose` segment, so a caller can render everything
/// through this without asking whether it needed to.
public func markdownNoteSegments(in text: String) -> [MarkdownNoteSegment] {
    var out: [MarkdownNoteSegment] = []
    var cursor = text.startIndex

    func addProse(_ range: Range<String.Index>) {
        let run = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        if !run.isEmpty { out.append(.prose(run)) }
    }

    for image in markdownImages(in: text) {
        // An embed that points at something that isn't an image is a link written with a stray `!`,
        // not a picture. Left in the prose, where the text renderer already knows what to do with it.
        guard isMarkdownImagePath(image.destination) else { continue }
        addProse(cursor..<image.range.lowerBound)
        out.append(.image(destination: image.destination, alt: image.alt))
        cursor = image.range.upperBound
    }
    addProse(cursor..<text.endIndex)
    return out
}

// MARK: - Writing a pasted image

/// The folder a pasted image is written into, beside the note that embeds it. Named for what Obsidian
/// calls it, since these notes live in a vault that has its own opinion.
public let markdownAttachmentsFolder = "attachments"

/// The name to write a pasted image under: `Pasted image 20260827143210`, Obsidian's own convention,
/// which sorts chronologically and says where it came from without needing the note to name it.
public func pastedImageBaseName(at date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMddHHmmss"
    return "Pasted image \(f.string(from: date))"
}

/// A free name for `base.ext` in `folder`, suffixing `-1`, `-2`, … past whatever is already there.
///
/// Two images pasted inside the same second is the case this exists for, and it's not far-fetched: the
/// timestamp is the whole of the name, so without this the second paste would silently overwrite the
/// first one's file and both embeds would point at the same picture.
public func availableAttachmentURL(base: String, ext: String, in folder: URL,
                                   exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
    let first = folder.appendingPathComponent("\(base).\(ext)")
    guard exists(first) else { return first }
    for n in 1...999 {
        let next = folder.appendingPathComponent("\(base)-\(n).\(ext)")
        if !exists(next) { return next }
    }
    return first
}

/// Write image data into the attachments folder beside `note`, creating the folder if it's the first
/// one, and return where it landed. The caller turns that into an embed with `markdownImageEmbed`.
///
/// Beside the note rather than in the project's `resources/`: the link written into the note is
/// relative, and a picture one folder down from the note it belongs to stays linked wherever the vault
/// is opened and whatever the project folder is later renamed to.
@discardableResult
public func saveNoteAttachment(_ data: Data, ext: String, baseName: String = pastedImageBaseName(),
                               forNoteAt note: URL) throws -> URL {
    let folder = note.deletingLastPathComponent()
        .appendingPathComponent(markdownAttachmentsFolder, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = availableAttachmentURL(base: baseName, ext: ext, in: folder)
    try data.write(to: file, options: .atomic)
    return file
}
