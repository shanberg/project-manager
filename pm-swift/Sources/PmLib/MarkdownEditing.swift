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
    /// `[ ]`, `[x]`, `[X]` or `[-]` when the item is a task line, without the space that follows it.
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
       let mark = rest.dropFirst().first, TaskState(box: mark) != nil,
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

/// How far in a list item sits, for comparing nesting: a tab is as deep as two spaces, the app's
/// own indent unit (`markdownIndentUnit`), so a note indented with either nests the same way.
private func nestingWidth(_ indent: String) -> Int {
    indent.reduce(0) { $0 + ($1 == "\t" ? markdownIndentUnit.count : 1) }
}

/// Whether a line belongs to the list around it: an item, or an item's indented continuation. A blank
/// line or a line of unindented prose ends the list.
private func isInList(_ line: String) -> Bool {
    if markdownListPrefix(of: line) != nil { return true }
    guard let first = line.first, isSpace(first) else { return false }
    return !line.allSatisfy(isSpace)
}

/// Number every ordered list in `lines[range]` by its structure, returning how much each line grew.
///
/// **Each nesting level counts on its own.** An item continues the count of the item above it at the
/// same depth when both are numbered; anything else starts a new list — a numbered item under a bullet,
/// a bullet under a numbered item, a numbered run after a bulleted one at the same depth. So bullets and
/// numbers mix freely, and indenting `3.` makes it the `1.` of a list inside the item above it rather
/// than a second 3.
///
/// A list nested inside another counts from 1. One at the top counts from its lowest number, so a
/// list written to begin at 5 still does, and moving its 3 to the top doesn't make it begin at 3.
private func numberLists(_ lines: inout [String], in range: ClosedRange<Int>) -> [Int: Int] {
    // First which list each numbered item is in, then the numbers: a top-level list's start depends on
    // all of its items, so it isn't known until the last of them has been seen.
    var levels: [(width: Int, ordered: Bool, list: Int)] = []
    var lists: [(nested: Bool, items: [(line: Int, prefix: MarkdownListPrefix)])] = []
    for i in range {
        guard let p = markdownListPrefix(of: lines[i]) else { continue }   // a continuation line
        let width = nestingWidth(p.indent)
        while let top = levels.last, top.width > width { levels.removeLast() }
        if let top = levels.last, top.width == width, top.ordered == p.isOrdered {
            if p.isOrdered { lists[top.list].items.append((i, p)) }
            continue
        }
        if let top = levels.last, top.width == width { levels.removeLast() }
        levels.append((width, p.isOrdered, lists.count))
        lists.append((nested: levels.count > 1, items: p.isOrdered ? [(i, p)] : []))
    }
    var deltas: [Int: Int] = [:]
    for list in lists where !list.items.isEmpty {
        var number = list.nested ? 1 : list.items.compactMap(\.prefix.number).min() ?? 1
        for (i, p) in list.items {
            defer { number += 1 }
            guard p.number != number else { continue }
            let marker = "\(number)\(p.delimiter)"
            lines[i] = p.indent + marker + String(lines[i].dropFirst(p.indent.count + p.marker.count))
            deltas[i] = marker.count - p.marker.count
        }
    }
    return deltas
}

/// Renumber the lists that any of `touched` lines is in, keeping the selection over the same text.
///
/// Every edit that can change a list's shape ends here — Return, Tab, moving, copying, deleting and
/// opening lines — rather than each fixing up its own neighbours, because what the numbers should be is
/// a fact about the whole list and not about the line that moved. Only the lists the edit touched are
/// renumbered: a note is the user's file, and a list elsewhere in it that they numbered by hand is
/// theirs.
private func renumbered(_ r: (text: String, selection: Range<String.Index>),
                        touching touched: [Int]) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(r.text)
    let starts = lineStarts(lines)
    var deltas: [Int: Int] = [:]
    var done = IndexSet()
    for t in touched where lines.indices.contains(t) && isInList(lines[t]) && !done.contains(t) {
        var a = t, b = t
        while a > 0, isInList(lines[a - 1]) { a -= 1 }
        while b < lines.count - 1, isInList(lines[b + 1]) { b += 1 }
        done.insert(integersIn: a...b)
        deltas.merge(numberLists(&lines, in: a...b)) { $1 }
    }
    guard !deltas.isEmpty else { return r }
    let (lo, hi) = charOffsets(r.text, r.selection)
    func moved(_ offset: Int) -> Int {
        let line = lineIndex(starts, offset)
        let before = deltas.filter { $0.key < line }.values.reduce(0, +)
        guard let delta = deltas[line], let p = markdownListPrefix(of: splitLines(r.text)[line]) else {
            return offset + before
        }
        // The number is the only thing that changed, so a position past it moves with the text and one
        // inside it stays at the start of the marker.
        let markerStart = starts[line] + p.indent.count
        let markerEnd = markerStart + p.marker.count
        return offset >= markerEnd ? offset + before + delta : min(offset, markerStart) + before
    }
    return rebuilt(lines, moved(lo), moved(hi))
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
    func carry(_ prefix: String) -> (text: String, selection: Range<String.Index>) {
        var chars = Array(text)
        chars.replaceSubrange(lo..<hi, with: Array("\n" + prefix))
        let caret = lo + 1 + prefix.count
        return renumbered(result(String(chars), caret, caret), touching: [li + 1])
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
        return carry(p.next)
    }
    if let q = markdownQuotePrefix(of: line) {
        guard column >= q.count else { return nil }
        let content = String(line.dropFirst(q.count))
        if lo == hi, content.trimmingCharacters(in: .whitespaces).isEmpty { return endList() }
        return carry(q)
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
    return renumbered(rebuilt(lines, lo + unit.count, hi + unit.count * touched), touching: Array(first...last))
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
    return renumbered(rebuilt(lines, newLo, hi - removedTotal), touching: Array(first...last))
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
    // The item keeps its place in the count, not its number: a 3 moved above the 2 is the 2 now.
    return renumbered(rebuilt(lines, lo + shift, hi + shift), touching: Array((up ? first - 1 : first)...(last + 1)))
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
    return renumbered(rebuilt(lines, lo + shift, hi + shift), touching: [last + 1])
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
    let label = file.deletingPathExtension().lastPathComponent
    guard isMarkdownImagePath(file.path) else {
        return "[\(label)](\(markdownPathEscaped(markdownRelativePath(for: file, relativeTo: note))))"
    }
    return markdownImageEmbed(for: file, relativeTo: note, alt: label)
}

/// The embed to write for an image at `file`, with the alt text of the caller's choosing — the file's
/// own name when it was dropped and already had one, something like "Pasted image" when it didn't.
public func markdownImageEmbed(for file: URL, relativeTo note: URL?, alt: String) -> String {
    "![\(alt)](\(markdownPathEscaped(markdownRelativePath(for: file, relativeTo: note))))"
}

// MARK: - Line commands
//
// The editor's IDE-style keys — copy a line up or down, delete it, open a line above or below, join,
// set a heading, toggle a task, grow the selection by structure. Pure over (text, selection) like
// everything above, so the view only routes keys at them.

/// The lines a selection covers. A selection that ends exactly where a line starts — a triple-click, a
/// drag to the left margin — doesn't cover that line, which is what you see: nothing on it is selected.
private func coveredLines(_ starts: [Int], _ lo: Int, _ hi: Int) -> (first: Int, last: Int) {
    let first = lineIndex(starts, lo)
    var last = lineIndex(starts, hi)
    if hi > lo, last > first, starts[last] == hi { last -= 1 }
    return (first, last)
}

/// Rewrite each covered line and carry the selection with the text: each end moves by what changed
/// before it, and never back past the start of its own line.
private func rewriteLines(_ text: String, _ selection: Range<String.Index>,
                          _ rewrite: (_ index: Int, _ line: String) -> String) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    var deltas = Array(repeating: 0, count: lines.count)
    for i in first...last {
        let new = rewrite(i, lines[i])
        deltas[i] = new.count - lines[i].count
        lines[i] = new
    }
    func moved(_ offset: Int) -> Int {
        let line = lineIndex(starts, offset)
        let before = deltas[..<line].reduce(0, +)
        // Within its own line an edit is at the head (a marker added or removed), so the offset moves
        // with it — but not back past where the line starts.
        return max(starts[line] + before, offset + before + deltas[line])
    }
    // A selection that starts a line still starts it: it was covering whole lines, and still is.
    let start = hi > lo && starts[first] == lo ? lo + deltas[..<first].reduce(0, +) : moved(lo)
    return rebuilt(lines, start, moved(hi))
}

/// Copy the covered lines above (`up`) or below themselves. The selection goes with the copy, so a
/// second press copies again in the same direction.
public func copyLines(_ text: String, selection: Range<String.Index>, up: Bool) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let block = Array(lines[first...last])
    lines.insert(contentsOf: block, at: last + 1)
    // Up: the copy is the upper of the two, which is where the selection already is.
    let shift = up ? 0 : block.reduce(0) { $0 + $1.count + 1 }
    return renumbered(rebuilt(lines, lo + shift, hi + shift), touching: [last + 1])
}

/// Delete the covered lines, newline and all. The caret lands on the line that took their place, at
/// the column it was at, or on the last line when they were the last.
public func deleteLines(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let column = lo - starts[first]
    // A list whose first item is deleted still starts where it did: the item that takes its place
    // takes its number, where counting from the lowest one left would begin a 1-2-3 at 2.
    let head = markdownListPrefix(of: lines[first]).flatMap { $0.isOrdered ? $0 : nil }
    let headStartsList = first == 0 || !isInList(lines[first - 1])
    lines.removeSubrange(first...last)
    if lines.isEmpty { lines = [""] }
    if let head, headStartsList, first < lines.count,
       let next = markdownListPrefix(of: lines[first]), next.isOrdered, next.indent == head.indent {
        lines[first] = next.indent + "\(head.number ?? 1)\(next.delimiter)"
            + String(lines[first].dropFirst(next.indent.count + next.marker.count))
    }
    let landing = min(first, lines.count - 1)
    let caret = lineStarts(lines)[landing] + min(column, lines[landing].count)
    return renumbered(rebuilt(lines, caret, caret), touching: [landing])
}

/// Open an empty line below the covered lines, or above them, without splitting the one you're on. In
/// a list the new line is the list's next item (above: an item like this one); in a quote, more quote;
/// otherwise it keeps the line's indent.
public func insertLine(_ text: String, selection: Range<String.Index>, above: Bool) -> (text: String, selection: Range<String.Index>) {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let line = lines[above ? first : last]
    let prefix: String
    if let list = markdownListPrefix(of: line) {
        prefix = above ? list.indent + list.marker + list.spacing + (list.checkbox != nil ? "[ ] " : "")
                       : list.next
    } else if let quote = markdownQuotePrefix(of: line) {
        prefix = quote
    } else {
        prefix = String(line.prefix { isSpace($0) })
    }
    let at = above ? first : last + 1
    lines.insert(prefix, at: at)
    let caret = lineStarts(lines)[at] + prefix.count
    return renumbered(rebuilt(lines, caret, caret), touching: [at])
}

/// Make the covered lines headings at `level`, or plain paragraphs at 0. Asking for the level they
/// already all have takes it away again, so the key toggles.
public func setHeading(_ text: String, selection: Range<String.Index>, level: Int) -> (text: String, selection: Range<String.Index>) {
    let level = max(0, min(6, level))
    func split(_ line: String) -> (hashes: Int, content: Substring) {
        let hashes = line.prefix { $0 == "#" }.count
        let after = line.dropFirst(hashes)
        guard (1...6).contains(hashes), after.isEmpty || isSpace(after.first!) else { return (0, Substring(line)) }
        return (hashes, after.drop { isSpace($0) })
    }
    let lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let many = last > first
    let covered = lines[first...last].filter { !many || !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let target = level > 0 && !covered.isEmpty && covered.allSatisfy({ split($0).hashes == level }) ? 0 : level
    return rewriteLines(text, selection) { _, line in
        if many, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
        let content = split(line).content
        return target == 0 ? String(content) : String(repeating: "#", count: target) + " " + content
    }
}

/// Toggle the covered lines as tasks: a task is ticked or unticked — all of them one way, decided by
/// the first, so a mixed run comes out uniform — a list item gains a box, and a plain line becomes a
/// task item.
public func toggleTask(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>) {
    let lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let many = last > first
    let firstBox = lines[first...last].lazy.compactMap { markdownListPrefix(of: $0)?.checkbox }.first
    let ticking = firstBox == "[ ]"
    return rewriteLines(text, selection) { _, line in
        if many, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
        if let list = markdownListPrefix(of: line) {
            let head = list.indent + list.marker + list.spacing
            let rest = line.dropFirst(list.text.count)
            if list.checkbox != nil { return head + (ticking ? "[x] " : "[ ] ") + rest }
            return head + "[ ] " + line.dropFirst(head.count)
        }
        let indent = line.prefix { isSpace($0) }
        return indent + "- [ ] " + line.dropFirst(indent.count)
    }
}

/// Join the covered lines into one — or, with only one covered, join it with the next. The next line's
/// indent goes; one space goes between, unless either side is empty. Nil when there is no next line.
public func joinLines(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>)? {
    var lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    var (first, last) = coveredLines(starts, lo, hi)
    if first == last { last += 1 }
    guard last < lines.count else { return nil }
    var joined = lines[first]
    var caret = 0
    for line in lines[(first + 1)...last] {
        let next = line.drop { isSpace($0) }
        joined = joined.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        caret = joined.count
        if !joined.isEmpty, !next.isEmpty { joined += " "; caret += 1 }
        joined += next
    }
    lines.replaceSubrange(first...last, with: [joined])
    let at = starts[first] + caret
    // A caret lands at the last join, where you'd type next; a selection keeps covering what it did.
    return hi > lo ? rebuilt(lines, starts[first], starts[first] + joined.count) : rebuilt(lines, at, at)
}

/// The next larger structure around the selection: the word, the line, the block of lines between blank
/// ones, the section under the nearest heading, the whole note. Nil when it is already the whole note.
public func expandedSelection(in text: String, from selection: Range<String.Index>) -> Range<String.Index>? {
    let lines = splitLines(text)
    let starts = lineStarts(lines)
    let (lo, hi) = charOffsets(text, selection)
    let (first, last) = coveredLines(starts, lo, hi)
    let chars = Array(text)
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "'" }
    func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
    func headingLevel(_ i: Int) -> Int? {
        let hashes = lines[i].prefix { $0 == "#" }.count
        let after = lines[i].dropFirst(hashes)
        return (1...6).contains(hashes) && (after.isEmpty || isSpace(after.first!)) ? hashes : nil
    }
    func end(of i: Int) -> Int { starts[i] + lines[i].count }

    var candidates: [(Int, Int)] = []
    // Word.
    var a = lo, b = hi
    while a > 0, isWord(chars[a - 1]) { a -= 1 }
    while b < chars.count, isWord(chars[b]) { b += 1 }
    if a < b { candidates.append((a, b)) }
    // Line, without its indent or marker first, then whole.
    let content = starts[first] + (markdownListPrefix(of: lines[first])?.text.count
                                   ?? markdownQuotePrefix(of: lines[first])?.count
                                   ?? lines[first].prefix { isSpace($0) }.count)
    candidates.append((content, end(of: last)))
    candidates.append((starts[first], end(of: last)))
    // Block.
    if !blank(first) {
        var top = first, bottom = last
        while top > 0, !blank(top - 1), headingLevel(top - 1) == nil, headingLevel(top) == nil { top -= 1 }
        while bottom < lines.count - 1, !blank(bottom + 1), headingLevel(bottom + 1) == nil { bottom += 1 }
        candidates.append((starts[top], end(of: bottom)))
    }
    // Section: from the nearest heading at or above, to before the next heading as high or higher.
    var h = first
    while h >= 0, headingLevel(h) == nil { h -= 1 }
    var level = h >= 0 ? headingLevel(h)! : 7
    while h >= 0 {
        var stop = max(h + 1, last + 1)
        while stop < lines.count, (headingLevel(stop) ?? 7) > level { stop += 1 }
        candidates.append((starts[h], end(of: stop - 1)))
        // Then the section this one sits in.
        var up = h - 1
        while up >= 0, (headingLevel(up) ?? 7) >= level { up -= 1 }
        h = up
        level = h >= 0 ? headingLevel(h)! : 0
    }
    candidates.append((0, chars.count))

    guard let next = candidates.filter({ $0.0 <= lo && $0.1 >= hi && ($0.0 < lo || $0.1 > hi) })
        .min(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }) else { return nil }
    return result(text, next.0, next.1).selection
}
