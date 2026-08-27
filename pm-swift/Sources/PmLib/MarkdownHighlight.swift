import Foundation

// Lightweight markdown tokenizing for the panel's session-note editor. This is *source* highlighting:
// it locates markdown constructs in raw text so an editor can style them (headings larger, emphasis
// bold/italic, markers dimmed) while keeping every character as typed. It deliberately isn't a full
// CommonMark parser — just the inline/line constructs worth styling — and it's pure and Foundation-
// light (ranges are `Range<String.Index>`) so it unit-tests without any AppKit.

/// A styled region of markdown source. `.syntax` marks the literal markers (e.g. the `**`, the `#`,
/// the brackets) so the editor can dim them; the other kinds mark the styled content.
public enum MarkdownSpanKind: Equatable {
    case heading(level: Int)
    case bold
    case italic
    case code
    case link
    /// An Obsidian-style `[[note]]` reference. These notes live in a vault, where this is how one note
    /// points at another; styled like a link, because that's what it is.
    case wikilink
    case listMarker
    case blockquote
    case strikethrough
    case syntax
}

/// A markdown construct located in the source, as a half-open character range plus its kind.
public struct MarkdownSpan: Equatable {
    public let range: Range<String.Index>
    public let kind: MarkdownSpanKind
    public init(range: Range<String.Index>, kind: MarkdownSpanKind) {
        self.range = range
        self.kind = kind
    }
}

private enum MarkdownRE {
    static let heading = try? NSRegularExpression(pattern: #"(?m)^(#{1,6}[ \t]+)(.*)$"#)
    static let blockquote = try? NSRegularExpression(pattern: #"(?m)^([ \t]*>[ \t]?)(.*)$"#)
    static let list = try? NSRegularExpression(pattern: #"(?m)^([ \t]*(?:[-*+]|\d{1,9}\.)[ \t]+)"#)
    static let code = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    // The label is allowed to be empty so `![](shot.png)` — an image pasted by something that had no
    // name for it — is still a construct rather than four stray characters of prose.
    static let link = try? NSRegularExpression(pattern: #"(\[)([^\]\n]*)(\]\()([^)\n]+)(\))"#)
    // `[[note]]` or `[[note|shown as this]]` — the alias, when there is one, is what reads.
    static let wikilink = try? NSRegularExpression(pattern: #"(\[\[)([^\]\n|]+)(?:(\|)([^\]\n]*))?(\]\])"#)
    static let image = markdownImageRE
    static let bold = try? NSRegularExpression(pattern: #"(\*\*|__)(.+?)\1"#)
    static let strike = try? NSRegularExpression(pattern: #"(~~)(.+?)(~~)"#)
    static let italicStar = try? NSRegularExpression(pattern: #"(?<![\*\w])\*(?!\*)([^*\n]+?)\*(?![\*\w])"#)
    static let italicUnderscore = try? NSRegularExpression(pattern: #"(?<![_\w])_(?!_)([^_\n]+?)_(?![_\w])"#)
}

/// Locate the styleable markdown constructs in `text`. Content spans (heading/bold/…) come first, then
/// `.syntax` marker spans — but every span's range is disjoint from same-purpose spans, so an editor
/// can apply them in any order. Overlaps across constructs (e.g. bold inside a heading) are allowed and
/// simply compose.
public func markdownSpans(in text: String) -> [MarkdownSpan] {
    let full = NSRange(location: 0, length: (text as NSString).length)
    var content: [MarkdownSpan] = []
    var syntax: [MarkdownSpan] = []

    func addContent(_ r: NSRange, _ kind: MarkdownSpanKind) {
        if let rr = Range(r, in: text), !rr.isEmpty { content.append(MarkdownSpan(range: rr, kind: kind)) }
    }
    func addSyntax(_ r: NSRange) {
        if let rr = Range(r, in: text), !rr.isEmpty { syntax.append(MarkdownSpan(range: rr, kind: .syntax)) }
    }
    func each(_ re: NSRegularExpression?, _ body: (NSTextCheckingResult) -> Void) {
        re?.enumerateMatches(in: text, range: full) { m, _, _ in if let m { body(m) } }
    }

    // Headings: dim the `#### ` prefix, style the rest by level.
    each(MarkdownRE.heading) { m in
        let hashes = m.range(at: 1)
        let level = (text as NSString).substring(with: hashes).filter { $0 == "#" }.count
        addContent(m.range(at: 2), .heading(level: max(1, min(6, level))))
        addSyntax(hashes)
    }
    // Blockquotes: style the quoted content, dim the `> ` marker.
    each(MarkdownRE.blockquote) { m in
        addContent(m.range(at: 2), .blockquote)
        addSyntax(m.range(at: 1))
    }
    // List markers: the leading bullet / number.
    each(MarkdownRE.list) { m in
        if let rr = Range(m.range(at: 1), in: text), !rr.isEmpty {
            content.append(MarkdownSpan(range: rr, kind: .listMarker))
        }
    }
    // Inline code: mono content, dim backticks.
    each(MarkdownRE.code) { m in
        let whole = m.range, inner = m.range(at: 1)
        addContent(inner, .code)
        addSyntax(NSRange(location: whole.location, length: inner.location - whole.location))
        addSyntax(NSRange(location: inner.location + inner.length,
                          length: whole.location + whole.length - (inner.location + inner.length)))
    }
    // Links: [label](url) — color the label, dim the brackets/parens and the URL.
    each(MarkdownRE.link) { m in
        addContent(m.range(at: 2), .link)
        addSyntax(m.range(at: 1))   // [
        addSyntax(m.range(at: 3))   // ](
        addSyntax(m.range(at: 4))   // url
        addSyntax(m.range(at: 5))   // )
    }
    // Image embeds: the `!` in `![alt](path)`. The `[alt](path)` half is a link and was styled as one
    // above, so the bang is all that's left — and it's a marker like any other, so it dims with them
    // and the read view drops it. Deliberately the only span added here: a second one over characters
    // the link rule already claimed would be deleted twice when the read view strips its markers.
    each(MarkdownRE.image) { m in addSyntax(m.range(at: 1)) }
    // Wikilinks: [[note]] or [[note|alias]] — the alias (or the target, when there's no alias) is what
    // reads; the brackets, the pipe and the target it hides are dimmable syntax.
    each(MarkdownRE.wikilink) { m in
        let alias = m.range(at: 4)
        addContent(alias.location == NSNotFound ? m.range(at: 2) : alias, .wikilink)
        addSyntax(m.range(at: 1))   // [[
        if alias.location != NSNotFound {
            addSyntax(m.range(at: 2))   // the target
            addSyntax(m.range(at: 3))   // |
        }
        addSyntax(m.range(at: 5))   // ]]
    }
    // Emphasis: bold and strikethrough carry paired markers; italic is a single char each side.
    func paired(_ re: NSRegularExpression?, _ kind: MarkdownSpanKind) {
        each(re) { m in
            let whole = m.range, inner = m.range(at: 2)
            addContent(inner, kind)
            addSyntax(NSRange(location: whole.location, length: inner.location - whole.location))
            addSyntax(NSRange(location: inner.location + inner.length,
                              length: whole.location + whole.length - (inner.location + inner.length)))
        }
    }
    paired(MarkdownRE.bold, .bold)
    paired(MarkdownRE.strike, .strikethrough)
    func italic(_ re: NSRegularExpression?) {
        each(re) { m in
            let whole = m.range, inner = m.range(at: 1)
            addContent(inner, .italic)
            addSyntax(NSRange(location: whole.location, length: inner.location - whole.location))
            addSyntax(NSRange(location: inner.location + inner.length,
                              length: whole.location + whole.length - (inner.location + inner.length)))
        }
    }
    italic(MarkdownRE.italicStar)
    italic(MarkdownRE.italicUnderscore)

    return content + syntax
}

/// A resolved `[label](destination)` link: where the whole construct sits, where its label sits, and
/// what it points at. `markdownSpans` treats the destination as dimmable syntax and says nothing about
/// what it is, so anything that needs to *follow* a link — ⌘-click in the editor, a real link in the
/// rendered read view — asks here instead.
public struct MarkdownLink: Equatable {
    public let range: Range<String.Index>
    public let labelRange: Range<String.Index>
    public let destination: String
    public init(range: Range<String.Index>, labelRange: Range<String.Index>, destination: String) {
        self.range = range
        self.labelRange = labelRange
        self.destination = destination
    }
}

/// Locate the markdown links in `text`, in source order.
public func markdownLinks(in text: String) -> [MarkdownLink] {
    let full = NSRange(location: 0, length: (text as NSString).length)
    var out: [MarkdownLink] = []
    MarkdownRE.link?.enumerateMatches(in: text, range: full) { m, _, _ in
        guard let m,
              let whole = Range(m.range, in: text),
              let label = Range(m.range(at: 2), in: text),
              let url = Range(m.range(at: 4), in: text) else { return }
        out.append(MarkdownLink(range: whole, labelRange: label, destination: String(text[url])))
    }
    return out
}

// MARK: - Formatting shortcuts (pure, testable)

/// Toggle a symmetric inline marker (e.g. `**` for bold, `*` for italic) around `selection`. Removes the
/// marker when the selection is already wrapped — either the markers sit just outside the selection, or
/// the selection includes them — otherwise wraps the selection. Returns the new text and the selection
/// to reselect (the inner content, or the caret between markers for an empty selection).
public func toggleWrap(_ text: String, selection: Range<String.Index>, marker: String) -> (text: String, selection: Range<String.Index>) {
    var chars = Array(text)
    let m = Array(marker)
    let mlen = m.count
    let lo = text.distance(from: text.startIndex, to: selection.lowerBound)
    let hi = text.distance(from: text.startIndex, to: selection.upperBound)

    func result(_ newChars: [Character], _ selLo: Int, _ selHi: Int) -> (String, Range<String.Index>) {
        let s = String(newChars)
        let a = s.index(s.startIndex, offsetBy: selLo)
        let b = s.index(s.startIndex, offsetBy: selHi)
        return (s, a..<b)
    }

    // Markers immediately outside the selection → unwrap.
    if lo - mlen >= 0, hi + mlen <= chars.count,
       Array(chars[(lo - mlen)..<lo]) == m, Array(chars[hi..<(hi + mlen)]) == m {
        chars.removeSubrange(hi..<(hi + mlen))
        chars.removeSubrange((lo - mlen)..<lo)
        return result(chars, lo - mlen, hi - mlen)
    }
    // Markers inside the selection → unwrap.
    let sel = Array(chars[lo..<hi])
    if sel.count >= 2 * mlen, Array(sel.prefix(mlen)) == m, Array(sel.suffix(mlen)) == m {
        chars.removeSubrange((hi - mlen)..<hi)
        chars.removeSubrange(lo..<(lo + mlen))
        return result(chars, lo, hi - 2 * mlen)
    }
    // Otherwise wrap; reselect the inner content (or the caret between markers).
    chars.insert(contentsOf: m, at: hi)
    chars.insert(contentsOf: m, at: lo)
    return result(chars, lo + mlen, hi + mlen)
}

/// Wrap `selection` as a markdown link `[label](url)`, leaving the `url` placeholder selected to type
/// over. The label is the current selection (possibly empty).
public func wrapLink(_ text: String, selection: Range<String.Index>) -> (text: String, selection: Range<String.Index>) {
    var chars = Array(text)
    let lo = text.distance(from: text.startIndex, to: selection.lowerBound)
    let hi = text.distance(from: text.startIndex, to: selection.upperBound)
    let label = Array(chars[lo..<hi])
    let placeholder = Array("url")

    var insert: [Character] = ["["]
    insert.append(contentsOf: label)
    insert.append(contentsOf: Array("]("))
    let urlStart = lo + insert.count
    insert.append(contentsOf: placeholder)
    insert.append(")")
    chars.replaceSubrange(lo..<hi, with: insert)

    let s = String(chars)
    let a = s.index(s.startIndex, offsetBy: urlStart)
    let b = s.index(s.startIndex, offsetBy: urlStart + placeholder.count)
    return (s, a..<b)
}

// MARK: - Block structure (for paragraph styling)

/// What a single source line is, block-wise. `markdownSpans` answers "what should this run of
/// characters look like"; this answers "what shape is this line", which is the question an
/// `NSParagraphStyle` is the answer to — indent, hang and wrap alignment are per-paragraph, and no
/// amount of per-span styling can express them.
public enum MarkdownBlockKind: Equatable {
    case paragraph
    case heading(level: Int)
    case list
    case blockquote
}

/// One source line, split into the three parts that decide how it lays out: the whitespace it's
/// indented by, the marker that names it, and the content that reads.
///
/// The split is what lets a marker *hang*. Given a content column X, a line laid out with
/// `firstLineHeadIndent = X - width(marker)` and `headIndent = X + width(indent)` puts its marker in
/// the margin, its content on the column, and its wrapped lines under the content rather than back
/// under the marker. Because `indent` and `marker` are separated, that arithmetic is the same at every
/// nesting depth: the content column steps right by exactly the whitespace that was typed, and the
/// marker always hangs its own width to the left of it — whether the note nests by two spaces, by
/// four, or by tabs.
public struct MarkdownBlock: Equatable {
    /// The whole line, newline excluded.
    public let range: Range<String.Index>
    /// The line *including* its terminating newline — the range a paragraph style has to cover.
    ///
    /// A line and the paragraph it forms are not the same characters, and styling only the former
    /// leaves the newline carrying whatever paragraph style was underneath. AppKit then has one
    /// paragraph with two conflicting styles in it and lays the fragment out to suit the terminator,
    /// which shows up as a line that is mysteriously taller or indented differently than its
    /// neighbours. Callers applying `.paragraphStyle` want this range, not `range`.
    public let paragraph: Range<String.Index>
    public let kind: MarkdownBlockKind
    /// The leading whitespace, if any. Empty for an unindented line.
    public let indent: Range<String.Index>
    /// The marker itself with its trailing space — `- `, `## `, `> `, `1. ` — and *not* the indent in
    /// front of it. Empty for a plain paragraph.
    public let marker: Range<String.Index>

    public init(range: Range<String.Index>, paragraph: Range<String.Index>, kind: MarkdownBlockKind,
                indent: Range<String.Index>, marker: Range<String.Index>) {
        self.range = range
        self.paragraph = paragraph
        self.kind = kind
        self.indent = indent
        self.marker = marker
    }
}

/// Walk `text` line by line and classify each one. Every line comes back, in source order and covering
/// the text exactly once — a blank line and a plain line are both `.paragraph` with empty marker — so a
/// caller can style the whole document by iterating this alone.
public func markdownBlocks(in text: String) -> [MarkdownBlock] {
    var out: [MarkdownBlock] = []
    var lineStart = text.startIndex

    while true {
        let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
        let after = lineEnd == text.endIndex ? lineEnd : text.index(after: lineEnd)
        out.append(classifyBlock(text, lineStart..<lineEnd, paragraph: lineStart..<after))
        if lineEnd == text.endIndex { break }
        lineStart = after
    }
    return out
}

/// Classify one line. Ordered as the block grammars actually compete: a `>` claims the line before a
/// list marker inside it does, and a `#` claims it before either — which matches `markdownSpans`, so
/// the shape a line is given and the styling it gets can't disagree.
private func classifyBlock(_ text: String, _ line: Range<String.Index>,
                           paragraph: Range<String.Index>) -> MarkdownBlock {
    let indentEnd = text[line].firstIndex { $0 != " " && $0 != "\t" } ?? line.upperBound
    let indent = line.lowerBound..<indentEnd
    let rest = text[indentEnd..<line.upperBound]

    func block(_ kind: MarkdownBlockKind, markerLength: Int) -> MarkdownBlock {
        let end = text.index(indentEnd, offsetBy: markerLength, limitedBy: line.upperBound) ?? line.upperBound
        return MarkdownBlock(range: line, paragraph: paragraph, kind: kind,
                             indent: indent, marker: indentEnd..<end)
    }
    func plain(markerLength: Int = 0) -> MarkdownBlock {
        let end = text.index(indentEnd, offsetBy: markerLength, limitedBy: line.upperBound) ?? line.upperBound
        return MarkdownBlock(range: line, paragraph: paragraph, kind: .paragraph,
                             indent: indent, marker: indentEnd..<end)
    }

    // `#{1,6}` plus at least one space is a heading.
    //
    // Without the space the *kind* is still a paragraph — `#tag` is not a heading and must not be
    // styled as one — but the hashes are still returned as the marker, so they still hang. That split
    // is deliberate, and it's what makes converting a line into a heading free of movement: the run of
    // hashes grows leftward into the gutter as you type it, and the words you're promoting never leave
    // the column they were already on. Recognising the marker only once the space arrived meant the
    // text jumped one column right per hash and then snapped back — twice the movement, for a change
    // that should have looked like none.
    let hashes = rest.prefix { $0 == "#" }.count
    if hashes >= 1, hashes <= 6 {
        let after = rest.dropFirst(hashes)
        if let first = after.first, first == " " || first == "\t" {
            let spaces = after.prefix { $0 == " " || $0 == "\t" }.count
            return block(.heading(level: hashes), markerLength: hashes + spaces)
        }
        return plain(markerLength: hashes)
    }
    // `>` with at most one space after it, matching the blockquote span regex.
    if rest.first == ">" {
        let after = rest.dropFirst()
        let space = (after.first == " " || after.first == "\t") ? 1 : 0
        return block(.blockquote, markerLength: 1 + space)
    }
    // `-`/`*`/`+` or `1.`, then at least one space.
    var markerLength = 0
    if let first = rest.first, first == "-" || first == "*" || first == "+" {
        markerLength = 1
    } else {
        let digits = rest.prefix { $0.isNumber }.count
        if digits >= 1, digits <= 9, rest.dropFirst(digits).first == "." { markerLength = digits + 1 }
    }
    if markerLength > 0 {
        let after = rest.dropFirst(markerLength)
        let spaces = after.prefix { $0 == " " || $0 == "\t" }.count
        if spaces > 0 { return block(.list, markerLength: markerLength + spaces) }
        // A bullet alone on the line — the first keystroke of a new item. It hangs, so the text you're
        // about to type starts on the column rather than one place right of it and jumping left when
        // the space lands. Not extended to a bullet with a word already jammed against it the way the
        // hashes are: `*emphasis*` opening a line is ordinary prose, and hanging its asterisk would
        // misread a common thing to protect a rare one.
        if after.isEmpty { return plain(markerLength: markerLength) }
    }
    return plain()
}
