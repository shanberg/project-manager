import Foundation

/// What a project shows in place of its progress ring: an SF Symbol or an emoji.
///
/// Kept in the notes file's frontmatter under `pm-icon` rather than in config, because it has to
/// survive everything that happens to a folder — a rename, archiving, a move in Finder, a restore from
/// backup — and the notes file goes wherever the folder does. A config entry keyed by folder name
/// would be orphaned by the first rename, which is the same reason a project's kind isn't stored.
///
/// One key serves both cases: a single emoji is drawn as itself, and anything else is taken as a
/// symbol name. Whether that symbol exists is the app's question, not this one's — PmLib has no
/// symbol catalogue, so an unknown name reads back fine here and falls back to the ring where it's drawn.
public enum ProjectIcon: Equatable, Hashable, Sendable {
    case symbol(String)
    case emoji(String)

    public static let frontmatterKey = "pm-icon"

    /// Nil for an empty value, or for anything that is neither one emoji nor shaped like a symbol name
    /// (`leaf.fill`, `person.2`). Surrounding quotes are dropped, since YAML allows them.
    public init?(value: String) {
        let text = unquoted(value.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return nil }
        if text.count == 1, let character = text.first, character.isEmojiGrapheme {
            self = .emoji(text)
        } else if text.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil {
            self = .symbol(text)
        } else {
            return nil
        }
    }

    /// What's written after `pm-icon:`.
    public var value: String {
        switch self {
        case .symbol(let name): return name
        case .emoji(let emoji): return emoji
        }
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

/// The project's icon, read from a notes file's text.
public func projectIcon(rawText: String) -> ProjectIcon? {
    frontmatterValue(ProjectIcon.frontmatterKey, in: rawText).flatMap(ProjectIcon.init(value:))
}

/// Set or clear a project's icon, touching nothing in the file but the one frontmatter line.
public func setProjectIcon(project: String, to icon: ProjectIcon?) throws {
    let handle = try resolveNotesHandle(project: project)
    let raw = try handle.io.readContent(path: handle.notesPath)
    let updated = settingFrontmatterValue(ProjectIcon.frontmatterKey, to: icon?.value, in: raw)
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
