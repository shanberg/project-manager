import Foundation

/// What a project shows in place of its progress ring: an SF Symbol, an emoji, or an image of your own.
///
/// Kept in the notes file's frontmatter under `pm-icon` rather than in config, because it has to
/// survive everything that happens to a folder — a rename, archiving, a move in Finder, a restore from
/// backup — and the notes file goes wherever the folder does. A config entry keyed by folder name
/// would be orphaned by the first rename, which is the same reason a project's kind isn't stored.
///
/// One key serves both cases: a single emoji is drawn as itself, and anything else is taken as a
/// symbol name. Whether that symbol exists is the app's question, not this one's — PmLib has no
/// symbol catalogue, so an unknown name reads back fine here and falls back to the ring where it's drawn.
///
/// **An image** is named by a path relative to the notes file — the app copies a chosen SVG or PNG into
/// the `attachments/` folder beside it — with a second key, `pm-icon-recolor: true`, when it should be
/// drawn in the project's colour the way a symbol is, rather than in its own colours. Two keys rather
/// than one value, because both are things someone might edit by hand.
///
/// **Away from the file**, an icon travels as `value`: the task search, the day's sittings and the rest
/// carry it as a string beside the project's colour. There an image's path is absolute — `projectIcon
/// (rawText:notesPath:)` resolves it where the notes are read, since nothing downstream knows where they
/// were — and a recoloured one is marked with a `recolor:` prefix, which no path starts with.
public enum ProjectIcon: Equatable, Hashable, Sendable {
    case symbol(String)
    case emoji(String)
    /// Relative to the notes file's folder as read from the file; absolute once resolved.
    case image(path: String, recolor: Bool)

    public static let frontmatterKey = "pm-icon"
    public static let recolorKey = "pm-icon-recolor"
    static let recolorPrefix = "recolor:"

    /// Nil for an empty value, or for anything that is neither one emoji nor shaped like a symbol name
    /// (`leaf.fill`, `person.2`). Surrounding quotes are dropped, since YAML allows them.
    public init?(value: String) {
        let text = unquoted(value.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return nil }
        // Ahead of the symbol test, which `logo.png` would otherwise pass.
        let recolor = text.hasPrefix(Self.recolorPrefix)
        let path = recolor ? String(text.dropFirst(Self.recolorPrefix.count)) : text
        if isMarkdownImagePath(path), !path.hasPrefix("~"), !path.contains("\"") {
            self = .image(path: path, recolor: recolor)
            return
        }
        if text.count == 1, let character = text.first, character.isEmojiGrapheme {
            self = .emoji(text)
        } else if text.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil {
            self = .symbol(text)
        } else {
            return nil
        }
    }

    /// The icon as one string: what's written after `pm-icon:` for a symbol or an emoji, and what an
    /// icon travels as away from the file. See the type's note for an image.
    public var value: String {
        switch self {
        case .symbol(let name): return name
        case .emoji(let emoji): return emoji
        case .image(let path, let recolor): return recolor ? Self.recolorPrefix + path : path
        }
    }

    /// This icon with an image's path made absolute against the folder the notes file is in.
    public func resolved(notesPath: String?) -> ProjectIcon {
        guard case .image(let path, let recolor) = self, !path.hasPrefix("/"), let notesPath else { return self }
        let url = URL(fileURLWithPath: notesPath).deletingLastPathComponent().appendingPathComponent(path)
        return .image(path: url.standardizedFileURL.path, recolor: recolor)
    }
}

extension Character {
    /// Whether this grapheme is presented as an emoji. A bare digit or `#` carries the Emoji property
    /// too, but only turns into one with a variation selector or keycap after it — which makes it more
    /// than one scalar, so that's what's checked.
    public var isEmojiGrapheme: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

/// The project's icon, read from a notes file's text. An image's path is as written — relative to the
/// notes — so this is for writing back; to draw it, use `projectIcon(rawText:notesPath:)`.
public func projectIcon(rawText: String) -> ProjectIcon? {
    guard let icon = frontmatterValue(ProjectIcon.frontmatterKey, in: rawText).flatMap(ProjectIcon.init(value:))
    else { return nil }
    guard case .image(let path, _) = icon else { return icon }
    let recolor = frontmatterValue(ProjectIcon.recolorKey, in: rawText)?.lowercased() == "true"
    return .image(path: path, recolor: recolor)
}

/// The project's icon, ready to draw anywhere: an image's path made absolute against `notesPath`.
public func projectIcon(rawText: String, notesPath: String?) -> ProjectIcon? {
    projectIcon(rawText: rawText)?.resolved(notesPath: notesPath)
}

/// A notes file's text with its icon set or cleared: `pm-icon`, and `pm-icon-recolor` beside an image
/// that asks for it — removed for anything else, so a symbol chosen after an image leaves no stray line.
public func settingProjectIcon(_ icon: ProjectIcon?, in rawText: String) -> String {
    var value = icon?.value
    var recolor: String? = nil
    if case .image(let path, let wantsRecolor) = icon {
        // Quoted, since a file name can hold anything YAML would read as something else.
        value = "\"\(path)\""
        recolor = wantsRecolor ? "true" : nil
    }
    let text = settingFrontmatterValue(ProjectIcon.frontmatterKey, to: value, in: rawText)
    return settingFrontmatterValue(ProjectIcon.recolorKey, to: recolor, in: text)
}

/// Set or clear a project's icon, touching nothing in the file but its frontmatter lines.
public func setProjectIcon(project: String, to icon: ProjectIcon?) throws {
    let handle = try resolveNotesHandle(project: project)
    let raw = try handle.io.readContent(path: handle.notesPath)
    let updated = settingProjectIcon(icon, in: raw)
    guard updated != raw else { return }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

// MARK: - Frontmatter

/// The inner lines of a frontmatter block — between a `---` on the file's first line and the next
/// `---` — as indices into `lines`. Nil when the file doesn't open with one, or never closes it.
private func frontmatterBody(_ lines: [String]) -> Range<Int>? {
    func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }
    guard let first = lines.first, isFence(first),
          let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }) else { return nil }
    return 1..<close
}

private func isEntry(_ line: String, for key: String) -> Bool {
    line.hasPrefix("\(key):")
}

private func unquoted(_ text: String) -> String {
    guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first
    else { return text }
    return String(text.dropFirst().dropLast())
}

/// A top-level scalar from the frontmatter, or nil when the file has no frontmatter, no such key, or
/// an empty value. Only the frontmatter is read: a `key:` line further down the document is prose.
public func frontmatterValue(_ key: String, in rawText: String) -> String? {
    let lines = rawText.components(separatedBy: "\n")
    guard let body = frontmatterBody(lines),
          let line = body.lazy.map({ lines[$0] }).first(where: { isEntry($0, for: key) }) else { return nil }
    let value = unquoted(line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines))
    return value.isEmpty ? nil : value
}

/// `rawText` with one frontmatter key set, replaced or — given nil — removed. Every other byte stays.
///
/// A file with no frontmatter gets a block of its own when something is set. Removing the last key
/// removes the block too, so trying an icon and going back to the ring leaves the file exactly as it was.
public func settingFrontmatterValue(_ key: String, to value: String?, in rawText: String) -> String {
    var lines = rawText.components(separatedBy: "\n")
    let entry = value.map { "\(key): \($0)" }

    guard let body = frontmatterBody(lines) else {
        guard let entry else { return rawText }
        lines.insert(contentsOf: ["---", entry, "---"], at: 0)
        return lines.joined(separator: "\n")
    }

    if let index = body.first(where: { isEntry(lines[$0], for: key) }) {
        if let entry {
            lines[index] = entry
        } else {
            lines.remove(at: index)
            let close = body.upperBound - 1
            let rest = lines[1..<close]
            if rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.removeSubrange(0...close)
            }
        }
    } else if let entry {
        lines.insert(entry, at: body.upperBound)
    }
    return lines.joined(separator: "\n")
}

/// `rewritten` with `original`'s frontmatter put back on top.
///
/// For the writes that regenerate a notes file from `ProjectNotes`, which has no field for
/// frontmatter: without this, the first edit that can't be spliced would silently strip it — and with
/// it the project's icon, plus whatever Obsidian or its plugins keep there.
public func carryingFrontmatter(from original: String, into rewritten: String) -> String {
    let old = original.components(separatedBy: "\n")
    guard let body = frontmatterBody(old),
          frontmatterBody(rewritten.components(separatedBy: "\n")) == nil else { return rewritten }
    return old[0...body.upperBound].joined(separator: "\n") + "\n" + rewritten
}
