import Foundation

// Line-wise editing operations for the session-note markdown editor: the behaviours every markdown
// editor has and a plain `NSTextView` doesn't — Return continuing a list, Tab indenting one, ⌥↑/⌥↓
// moving a line, typing a marker over a selection wrapping it, and pasting a URL over a selection
// turning it into a link.
//
// Every function here is pure over (text, selection) and Foundation-only, so the AppKit layer is left
// with nothing but key routing and these all unit-test without a text view. They return the new text
// plus the selection to restore; the ones that only sometimes apply return nil to mean "let the text
// view do its normal thing".

// MARK: - Line plumbing

private func splitLines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

/// Character offset of each line's first character.
private func lineStarts(_ lines: [String]) -> [Int] {
    var out: [Int] = []
    var n = 0
    for line in lines {
        out.append(n)
        n += line.count + 1   // + the newline that follows it
    }
    return out
}

/// The index of the line holding `offset`. A caret sitting exactly on a line break belongs to the line
/// it starts, which is what makes Return at the head of a line behave.
private func lineIndex(_ starts: [Int], _ offset: Int) -> Int {
    var idx = 0
    for (i, start) in starts.enumerated() where start <= offset { idx = i }
    return idx
}

private func charOffsets(_ text: String, _ selection: Range<String.Index>) -> (lo: Int, hi: Int) {
    (text.distance(from: text.startIndex, to: selection.lowerBound),
     text.distance(from: text.startIndex, to: selection.upperBound))
}

/// Rebuild the text from lines and turn a pair of character offsets back into a selection.
private func rebuilt(_ lines: [String], _ lo: Int, _ hi: Int) -> (text: String, selection: Range<String.Index>) {
    result(lines.joined(separator: "\n"), lo, hi)
}

private func result(_ s: String, _ lo: Int, _ hi: Int) -> (text: String, selection: Range<String.Index>) {
    let low = min(max(0, lo), s.count)
    let high = min(max(low, hi), s.count)
    let a = s.index(s.startIndex, offsetBy: low)
    let b = s.index(s.startIndex, offsetBy: high)
    return (s, a..<b)
}

private func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }

// MARK: - List and quote prefixes

/// The head of a markdown list item: its indentation, its marker, the spacing after the marker, and a
/// task checkbox when it carries one. Parsed rather than regexed so continuation can rebuild it exactly
/// — same bullet character, same spacing, same nesting.
public struct MarkdownListPrefix: Equatable {
    public let indent: String
    /// `-`, `*`, `+`, or an ordered marker like `3.` / `3)`.
    public let marker: String
    public let spacing: String
    /// `[ ]`, `[x]` or `[X]` when the item is a task line, without the space that follows it.
    public let checkbox: String?

    public init(indent: String, marker: String, spacing: String, checkbox: String?) {
        self.indent = indent
        self.marker = marker
        self.spacing = spacing
        self.checkbox = checkbox
    }

    public var isOrdered: Bool { marker.count > 1 }
    public var number: Int? { isOrdered ? Int(marker.dropLast()) : nil }
    public var delimiter: Character { marker.last ?? "." }
    /// The prefix as it appears at the head of the line, checkbox and its trailing space included.
    public var text: String { indent + marker + spacing + (checkbox.map { $0 + " " } ?? "") }
    /// The same prefix for the *next* item: ordered markers advance, everything else repeats, and a
    /// checked box comes back unchecked (you're writing a new task, not a done one).
    public var next: String {
        let marker = isOrdered ? "\((number ?? 0) + 1)\(delimiter)" : self.marker
        return indent + marker + spacing + (checkbox != nil ? "[ ] " : "")
    }
}

/// Parse a line's list prefix, or nil when the line isn't a list item.
public func markdownListPrefix(of line: String) -> MarkdownListPrefix? {
    var i = line.startIndex
    while i < line.endIndex, isSpace(line[i]) { i = line.index(after: i) }
    let indent = String(line[line.startIndex..<i])
    guard i < line.endIndex else { return nil }

    var marker = ""
    if "-*+".contains(line[i]) {
        marker = String(line[i])
        i = line.index(after: i)
    } else if line[i].isNumber {
        var digits = ""
        var j = i
        while j < line.endIndex, line[j].isNumber, digits.count < 9 {
            digits.append(line[j])
            j = line.index(after: j)
        }
        guard j < line.endIndex, line[j] == "." || line[j] == ")" else { return nil }
        marker = digits + String(line[j])
        i = line.index(after: j)
    } else {
        return nil
    }

    var spacing = ""
    while i < line.endIndex, isSpace(line[i]) {
        spacing.append(line[i])
        i = line.index(after: i)
    }
    guard !spacing.isEmpty else { return nil }   // `-word` is prose, not a bullet

    var checkbox: String? = nil
    let rest = line[i...]
    if rest.count >= 3, rest.first == "[", rest.dropFirst(2).first == "]",
       let mark = rest.dropFirst().first, mark == " " || mark == "x" || mark == "X",
       rest.count == 3 || rest.dropFirst(3).first == " " {
        checkbox = String(rest.prefix(3))
    }
    return MarkdownListPrefix(indent: indent, marker: marker, spacing: spacing, checkbox: checkbox)
}

/// Parse a line's blockquote prefix (`> `, `>> `, indented or not), or nil when there isn't one.
public func markdownQuotePrefix(of line: String) -> String? {
    var i = line.startIndex
    var prefix = ""
    while i < line.endIndex, isSpace(line[i]) {
        prefix.append(line[i])
        i = line.index(after: i)
    }
    guard i < line.endIndex, line[i] == ">" else { return nil }
    while i < line.endIndex, line[i] == ">" {
        prefix.append(line[i])
        i = line.index(after: i)
        if i < line.endIndex, line[i] == " " {
            prefix.append(" ")
            i = line.index(after: i)
        }
    }
    return prefix
}

// MARK: - Return: continue the list

/// Renumber the ordered items that follow `after` at the same indent, starting from `number`, so an
/// item inserted in the middle of a numbered list doesn't leave two 3s behind it. Deeper-indented lines
/// belong to a sublist and are stepped over; anything else ends the run.
private func renumber(_ lines: inout [String], after: Int, indent: String, from number: Int) {
    var n = number
    var i = after + 1
    while i < lines.count {
        guard let p = markdownListPrefix(of: lines[i]) else { return }
        if p.indent.count > indent.count { i += 1; continue }   // a nested sublist of this item
        guard p.indent == indent, p.isOrdered else { return }
        n += 1
        lines[i] = p.indent + "\(n)\(p.delimiter)" + p.spacing + (p.checkbox.map { $0 + " " } ?? "")
            + String(lines[i].dropFirst(p.text.count))
        i += 1
    }
}

/// Return inside a list item or blockquote: carry the marker onto the next line, advancing the number
/// for an ordered list and renumbering what follows. Return on an *empty* item ends the list instead —
/// the marker is cleared and the line left blank, the standard way out without reaching for Delete.
/// Returns nil when the caret isn't in a list or quote (or sits inside the marker itself), meaning the
/// text view should insert its ordinary newline.
public func continueList(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>)? {
    let lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let li = lineIndex(starts, lo)
    let line = lines[li]
    let column = lo - starts[li]

    /// Split the line at the selection, carrying `prefix` onto the new line below.
    func carry(_ prefix: String, ordered: (indent: String, number: Int)?) ->
        (text: String, selection: Range<String.Index>) {
        var chars = Array(text)
        chars.replaceSubrange(lo..<hi, with: Array("\n" + prefix))
        let caret = lo + 1 + prefix.count
        var out = splitLines(String(chars))
        if let ordered {
            renumber(&out, after: li + 1, indent: ordered.indent, from: ordered.number)
        }
        return rebuilt(out, caret, caret)
    }

    /// Return on an item with no content: drop the marker, leave the (now blank) line.
    func endList() -> (text: String, selection: Range<String.Index>) {
        var out = lines
        out[li] = ""
        return rebuilt(out, starts[li], starts[li])
    }

    if let p = markdownListPrefix(of: line) {
        let prefixLength = p.text.count
        guard column >= prefixLength else { return nil }
        let content = String(line.dropFirst(prefixLength))
        if lo == hi, content.trimmingCharacters(in: .whitespaces).isEmpty { return endList() }
        let ordered = p.isOrdered ? (p.indent, (p.number ?? 0) + 1) : nil
        return carry(p.next, ordered: ordered)
    }
    if let q = markdownQuotePrefix(of: line) {
        guard column >= q.count else { return nil }
        let content = String(line.dropFirst(q.count))
        if lo == hi, content.trimmingCharacters(in: .whitespaces).isEmpty { return endList() }
        return carry(q, ordered: nil)
    }
    return nil
}

// MARK: - Tab: indent and outdent

/// The app writes nesting as two spaces per level (see `NotesTodos`), so the editor indents by two.
public let markdownIndentUnit = "  "

/// Indent every line the selection touches by one level.
public func indentLines(_ text: String, selection: Range<String.Index>,
                        unit: String = markdownIndentUnit) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let first = lineIndex(starts, lo)
    let last = lineIndex(starts, hi)
    for i in first...last { lines[i] = unit + lines[i] }
    let touched = last - first + 1
    return rebuilt(lines, lo + unit.count, hi + unit.count * touched)
}

/// Outdent every line the selection touches by one level, taking a tab or up to `unit.count` spaces off
/// the front. Lines with no indentation left are untouched rather than eating into their text.
public func outdentLines(_ text: String, selection: Range<String.Index>,
                         unit: String = markdownIndentUnit) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let first = lineIndex(starts, lo)
    let last = lineIndex(starts, hi)
    var removedFromFirst = 0
    var removedTotal = 0
    for i in first...last {
        var removed = 0
        if lines[i].first == "\t" {
            removed = 1
        } else {
            removed = min(unit.count, lines[i].prefix(unit.count).prefix { $0 == " " }.count)
        }
        guard removed > 0 else { continue }
        lines[i] = String(lines[i].dropFirst(removed))
        if i == first { removedFromFirst = removed }
        removedTotal += removed
    }
    // Keep the caret over the same character, but never before its line's new start.
    let newLo = max(starts[first], lo - removedFromFirst)
    return rebuilt(lines, newLo, hi - removedTotal)
}

/// Whether Tab should indent rather than do its usual thing: the caret is in a list item, or the
/// selection spans more than one line. Prose gets Tab's ordinary meaning — a tab in a note is at best
/// invisible and at worst a code block.
public func tabShouldIndent(_ text: String, selection: Range<String.Index>) -> Bool {
    let lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let first = lineIndex(starts, lo)
    if lineIndex(starts, hi) != first { return true }
    return markdownListPrefix(of: lines[first]) != nil
}

// MARK: - Moving and duplicating lines

/// Move the lines the selection touches up or down one line, carrying the selection with them. Returns
/// nil at the ends of the text, where there's nothing to swap with.
public func moveLines(_ text: String, selection: Range<String.Index>, up: Bool) -> (text: String, selection: Range<String.Index>)? {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let first = lineIndex(starts, lo)
    let last = lineIndex(starts, hi)
    guard up ? first > 0 : last < lines.count - 1 else { return nil }

    let block = Array(lines[first...last])
    var shift = 0
    if up {
        let above = lines[first - 1]
        lines.replaceSubrange((first - 1)...last, with: block + [above])
        shift = -(above.count + 1)
    } else {
        let below = lines[last + 1]
        lines.replaceSubrange(first...(last + 1), with: [below] + block)
        shift = below.count + 1
    }
    return rebuilt(lines, lo + shift, hi + shift)
}

/// Duplicate the lines the selection touches, inserting the copy below and selecting it — so a repeated
/// press stacks copies instead of drifting away from them.
public func duplicateLines(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let first = lineIndex(starts, lo)
    let last = lineIndex(starts, hi)
    let block = Array(lines[first...last])
    lines.insert(contentsOf: block, at: last + 1)
    let shift = block.reduce(0) { $0 + $1.count + 1 }
    return rebuilt(lines, lo + shift, hi + shift)
}

// MARK: - Typing and pasting

/// Wrap the selection in `open`…`close` and keep the inner content selected, which is what typing a
/// marker over a selection means in a markdown editor: `*` makes it italic rather than replacing it.
/// With an empty selection there is nothing to wrap — the caller inserts the character normally.
public func wrapSelection(_ text: String, selection: Range<String.Index>,
                          open: String, close: String) -> (text: String, selection: Range<String.Index>) {
    var chars = Array(text)
    let (lo, hi) = charOffsets(text, selection)
    chars.insert(contentsOf: Array(close), at: hi)
    chars.insert(contentsOf: Array(open), at: lo)
    return result(String(chars), lo + open.count, hi + open.count)
}

/// The closing half of a marker typed over a selection, or nil for a character that shouldn't wrap.
public func markdownWrapPair(for character: Character) -> (open: String, close: String)? {
    switch character {
    case "*", "_", "`", "\"": return (String(character), String(character))
    case "(": return ("(", ")")
    case "[": return ("[", "]")
    case "{": return ("{", "}")
    default: return nil
    }
}

/// Whether a pasted string is a URL worth turning into a link — a single unbroken token with a scheme.
public func isPastableURL(_ string: String) -> Bool {
    let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
    guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
    if scheme == "mailto" { return !s.dropFirst("mailto:".count).isEmpty }
    return s.contains("://") && !(url.host ?? "").isEmpty
}

/// Paste a URL over a selection as `[selection](url)`, leaving the caret after the link. The label is
/// what was already there, which is the whole point: you select the words, paste, and they're linked.
public func pasteLink(_ text: String, selection: Range<String.Index>, url: String) -> (text: String, selection: Range<String.Index>) {
    var chars = Array(text)
    let (lo, hi) = charOffsets(text, selection)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = String(chars[lo..<hi])
    let link = "[\(label)](\(url))"
    chars.replaceSubrange(lo..<hi, with: Array(link))
    let end = lo + link.count
    return result(String(chars), end, end)
}

// MARK: - Dropped files

private let markdownImageExtensions: Set<String> =
    ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "tiff", "tif", "bmp"]

/// Percent-encode a path for the inside of a markdown link — spaces and parentheses are what actually
/// break `](…)`.
private func markdownPathEscaped(_ path: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "()")
    return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
}

/// The path to write for `file` in a note stored at `note`: relative when the two are near enough to
/// each other that the link survives being read anywhere the vault is (in the note's own folder, or a
/// short hop up and over into something like `attachments/`), absolute otherwise.
public func markdownRelativePath(for file: URL, relativeTo note: URL?, maxUpwardSteps: Int = 2) -> String {
    guard let note else { return file.standardizedFileURL.path }
    let target = file.standardizedFileURL.pathComponents
    let base = note.standardizedFileURL.deletingLastPathComponent().pathComponents
    var shared = 0
    while shared < min(target.count, base.count), target[shared] == base[shared] { shared += 1 }
    let up = base.count - shared
    guard shared > 1, up <= maxUpwardSteps else { return file.standardizedFileURL.path }
    let steps = Array(repeating: "..", count: up) + target[shared...]
    return steps.joined(separator: "/")
}

/// The markdown to insert for a file dropped into a note: an embed for an image, a link for anything
/// else, labelled with the file's name.
public func markdownFileLink(for file: URL, relativeTo note: URL?) -> String {
    let path = markdownPathEscaped(markdownRelativePath(for: file, relativeTo: note))
    let label = file.deletingPathExtension().lastPathComponent
    let isImage = markdownImageExtensions.contains(file.pathExtension.lowercased())
    return "\(isImage ? "!" : "")[\(label)](\(path))"
}
