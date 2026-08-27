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

/// A located embed: where the whole construct sits, what it points at, and how big the note asked for
/// it to be drawn.
public struct MarkdownImage: Equatable {
    public let range: Range<String.Index>
    public let alt: String
    public let destination: String
    /// The width in points the note asked for, from an Obsidian embed's `![[shot.png|300]]`. Nil is
    /// "however big it is", which is every markdown embed — the syntax has nowhere to say otherwise.
    public let width: Double?
    public init(range: Range<String.Index>, alt: String, destination: String, width: Double? = nil) {
        self.range = range
        self.alt = alt
        self.destination = destination
        self.width = width
    }
}

/// `![alt](destination)`, with an alt that's allowed to be empty — the form an image pasted by a tool
/// that had no name for it takes.
let markdownImageRE = try? NSRegularExpression(pattern: #"(!)\[([^\]\n]*)\]\(([^)\n]+)\)"#)

/// `![[target]]` or `![[target|300]]` — how Obsidian writes an embed, and the default on a fresh
/// install. The part after the pipe is a *display size*, not an alias: in a link `[[note|shown]]` names
/// what reads, but in an embed there is no text to name, and Obsidian reads it as a width (or `WxH`).
/// Getting that wrong is visible — it made `![[shot.png|300]]` read as the number 300.
let markdownWikiImageRE = try? NSRegularExpression(pattern: #"(!)\[\[([^\]\n|]+)(?:\|([^\]\n]*))?\]\]"#)

/// The width from an embed's size spec: `300` or `300x200`, and nothing from anything else.
private func embedWidth(_ spec: String?) -> Double? {
    guard let spec else { return nil }
    let digits = spec.prefix { $0.isNumber }
    guard !digits.isEmpty, let width = Double(digits), width > 0 else { return nil }
    return width
}

/// Locate the image embeds in `text` — both syntaxes — in source order.
///
/// Both, because a note in a vault is written by two hands. PM writes markdown embeds, and Obsidian
/// writes wikilink ones; the same note holds whichever the last editor used, and a reader shouldn't be
/// able to tell which that was.
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
    markdownWikiImageRE?.enumerateMatches(in: text, range: full) { m, _, _ in
        guard let m,
              let whole = Range(m.range, in: text),
              let target = Range(m.range(at: 2), in: text) else { return }
        let destination = String(text[target])
        let size = Range(m.range(at: 3), in: text).map { String(text[$0]) }
        // A wikilink embed carries no alt text at all, so the file's own name is the best thing to say
        // when the picture can't be found — which is the only time the alt is ever read.
        out.append(MarkdownImage(range: whole,
                                 alt: (destination as NSString).lastPathComponent,
                                 destination: destination, width: embedWidth(size)))
    }
    return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
}

// MARK: - Splitting a note for rendering

/// A piece of a note as a read view has to draw it: a run of markdown, or a picture.
public enum MarkdownNoteSegment: Equatable {
    /// Markdown to render as text. Never empty, and never contains an image embed.
    case prose(String)
    /// A picture. `width` is the size the note asked for, when it asked.
    case image(destination: String, alt: String, width: Double? = nil)
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
        // Two regexes over one string can both claim a stretch of it (a malformed embed is the way in),
        // and a segment that ran backwards would duplicate prose.
        guard image.range.lowerBound >= cursor else { continue }
        addProse(cursor..<image.range.lowerBound)
        out.append(.image(destination: image.destination, alt: image.alt, width: image.width))
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
