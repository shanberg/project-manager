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
    static let link = try? NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^)\n]+)(\))"#)
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
