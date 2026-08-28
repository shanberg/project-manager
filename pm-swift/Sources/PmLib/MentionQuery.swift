import Foundation

/// An `@…` being typed: the span it occupies and what's been typed after the sigil.
///
/// `@` is what you *type*; `[[…]]` is what gets *stored*. The sigil is an input affordance and the
/// wikilink is the file format, and keeping them separate is what lets PM offer the mention interaction
/// its own editors should have without inventing a syntax the vault can't read.
public struct MentionQuery: Equatable, Sendable {
    /// The whole `@…` span, from the sigil to the caret — what accepting a mention replaces.
    public let range: Range<String.Index>
    /// What's been typed after the `@`.
    public let query: String

    public init(range: Range<String.Index>, query: String) {
        self.range = range
        self.query = query
    }
}

/// The `@…` being typed at `caret`, if there is one.
///
/// A pure transform over (text, caret): it says where a mention *is*, never whether a popover should
/// be showing. Whether one is showing depends on whether the reader dismissed it, which is view state
/// and stays in the view — the same division `ShortcutTextView` already keeps, where the class decides
/// when and PmLib decides what.
///
/// Four rules, and the last one is load-bearing:
///
/// 1. The `@` starts a word — at the start of a line, or after whitespace. `me@example.com` isn't a
///    mention, the same test `QuickCaptureParser.splitTarget` makes.
/// 2. The query can't cross a newline.
/// 3. It's capped, so a stray `@` earlier in a paragraph doesn't keep claiming everything typed after
///    it. Spaces are allowed inside it because project titles have them.
/// 4. **It needs at least one character after the sigil.** A bare `@` at the end of a task line is the
///    focus marker — the notes format's own syntax, written by every focus command in the app — so a
///    mention that triggered on the sigil alone would put a popover up every time a task took focus.
///    Requiring a character costs nothing (there is nothing to search for yet) and removes the
///    collision entirely.
public func mentionQuery(in text: String, caret: String.Index, maxQueryLength: Int = 48) -> MentionQuery? {
    completionQuery(in: text, caret: caret, sigil: "@", requiresCharacter: true,
                    maxQueryLength: maxQueryLength)
}

/// The `/…` being typed at `caret`, if there is one.
///
/// Unlike a mention, a bare `/` is a complete request — it means "show me everything", which is what
/// a slash menu does in every app that has one, and there's no format token it collides with.
public func commandQuery(in text: String, caret: String.Index, maxQueryLength: Int = 48) -> MentionQuery? {
    completionQuery(in: text, caret: caret, sigil: "/", requiresCharacter: false,
                    maxQueryLength: maxQueryLength)
}

/// The shared scan behind both. A sigil that starts a word, a query that can't cross a newline or run
/// past a cap, and — for `@` only — a requirement that something has been typed after it.
public func completionQuery(in text: String, caret: String.Index, sigil: Character,
                            requiresCharacter: Bool, maxQueryLength: Int = 48) -> MentionQuery? {
    guard caret <= text.endIndex else { return nil }
    var index = caret
    var typed = 0
    while index > text.startIndex {
        let previous = text.index(before: index)
        let character = text[previous]
        if character == "\n" { return nil }
        if character == sigil {
            // Rule 1: the sigil has to start a word.
            if previous > text.startIndex {
                let beforeSigil = text[text.index(before: previous)]
                guard beforeSigil.isWhitespace else { return nil }
            }
            // Rule 4: nothing typed yet is the focus marker, not a mention.
            guard !requiresCharacter || typed > 0 else { return nil }
            return MentionQuery(range: previous..<caret, query: String(text[index..<caret]))
        }
        typed += 1
        if typed > maxQueryLength { return nil }
        index = previous
    }
    return nil
}

/// Replace a mention span with a wikilink to `target`, returning the new text and where the caret goes.
///
/// A trailing space, because a mention is nearly always mid-sentence and the alternative is every
/// accept being followed by the same keystroke. `TaskContent.render` trims a task line's ends, so one
/// on a task line costs nothing.
public func applyMention(_ text: String, range: Range<String.Index>,
                         target: String) -> (text: String, selection: Range<String.Index>) {
    let replacement = "[[\(target)]] "
    var out = text
    out.replaceSubrange(range, with: replacement)
    let caret = out.index(range.lowerBound, offsetBy: replacement.count)
    return (out, caret..<caret)
}

/// One thing an `@` can name.
///
/// Domain data rather than view state: it's a project or area described the way a search ranks and a
/// row draws it, and both the picker and the wait resolver read the same folder scan to build it.
public struct MentionCandidate: Equatable, Sendable, Identifiable {
    /// The folder name — what gets written, because it carries the `CODE-NNN` a rename keeps.
    public let name: String
    /// The name without its `CODE-NNN ` prefix — what the row shows and what a person calls it.
    public let shortName: String
    /// The domain code, empty for an area.
    public let code: String
    public let kind: ProjectKind
    public let isArchived: Bool
    public var id: String { name }

    public init(name: String, shortName: String, code: String, kind: ProjectKind, isArchived: Bool) {
        self.name = name
        self.shortName = shortName
        self.code = code
        self.kind = kind
        self.isArchived = isArchived
    }
}

// MARK: - Wikilink spans
//
// An editor that presents `[[…]]` as one thing needs to know where each one starts and ends. This is
// the pure half of that — the ranges — leaving the view to decide what a caret, an arrow key or a
// backspace does when it meets one.

/// Every `[[…]]` span in `text`, in document order. Ranges cover the brackets too, because the
/// brackets are part of the token: deleting the name and leaving `[[]]` behind is the failure this
/// exists to prevent.
public func wikilinkSpans(in text: String) -> [Range<String.Index>] {
    guard let pattern = try? NSRegularExpression(pattern: #"!?\[\[[^\]\n]*\]\]"#) else { return [] }
    let full = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
}

/// The span strictly containing `index` — inside the token, not at either edge.
///
/// The edges are deliberately excluded. A caret sitting just before or just after a token is *beside*
/// it, which is a legitimate place to be; only a caret between the brackets is somewhere the reader
/// never asked to be and should never be left.
public func wikilinkSpan(in text: String, strictlyContaining index: String.Index) -> Range<String.Index>? {
    wikilinkSpans(in: text).first { $0.lowerBound < index && index < $0.upperBound }
}

/// Where a caret proposed at `index` should actually land, given tokens are atomic.
///
/// Nearest edge, which is what a click in the middle of a chip means everywhere else. Direction-aware
/// stepping is the arrow keys' job, not this one's — a rule that always snapped back the way you came
/// would make ← from just after a token do nothing at all.
public func snapCaret(in text: String, to index: String.Index) -> String.Index {
    guard let span = wikilinkSpan(in: text, strictlyContaining: index) else { return index }
    let before = text.distance(from: span.lowerBound, to: index)
    let after = text.distance(from: index, to: span.upperBound)
    return before <= after ? span.lowerBound : span.upperBound
}

/// A selection widened to cover any token it partly overlaps.
///
/// Half a token is never a useful selection: copying it yields `[[W-1 Web`, and typing over it leaves
/// the rest of the brackets behind as litter.
public func snapSelection(in text: String, to range: Range<String.Index>) -> Range<String.Index> {
    guard range.lowerBound < range.upperBound else {
        let caret = snapCaret(in: text, to: range.lowerBound)
        return caret..<caret
    }
    var lower = range.lowerBound
    var upper = range.upperBound
    for span in wikilinkSpans(in: text) where span.lowerBound < upper && range.lowerBound < span.upperBound {
        lower = Swift.min(lower, span.lowerBound)
        upper = Swift.max(upper, span.upperBound)
    }
    return lower..<upper
}

/// Where the caret goes when it steps one place from `index`, stepping over a whole token rather than
/// into it. Returns nil at the ends of the text, where the caller should do nothing.
public func stepCaret(in text: String, from index: String.Index, forward: Bool) -> String.Index? {
    if forward {
        guard index < text.endIndex else { return nil }
        if let span = wikilinkSpans(in: text).first(where: { $0.lowerBound == index }) {
            return span.upperBound
        }
        return text.index(after: index)
    }
    guard index > text.startIndex else { return nil }
    if let span = wikilinkSpans(in: text).first(where: { $0.upperBound == index }) {
        return span.lowerBound
    }
    return text.index(before: index)
}

/// Delete the whole token immediately before `index`, if there is one. nil when there isn't, so the
/// caller falls through to ordinary backspace.
public func deleteWikilinkBefore(_ text: String,
                                 index: String.Index) -> (text: String, selection: Range<String.Index>)? {
    guard let span = wikilinkSpans(in: text).first(where: { $0.upperBound == index }) else { return nil }
    var out = text
    out.replaceSubrange(span, with: "")
    let caret = out.index(out.startIndex, offsetBy: text.distance(from: text.startIndex, to: span.lowerBound))
    return (out, caret..<caret)
}

/// Text as it reads rather than as it's stored: `[[W-3 Vendor Contract]]` becomes
/// `W-3 Vendor Contract`, and `[[target|alias]]` becomes `alias`.
///
/// The editors hide the brackets by laying them out at zero width, which needs a layout manager. A
/// row, a menu item and a sidebar line have no layout manager to teach — they have a `String` — so the
/// same result is reached by rewriting. Both are presentation; neither touches the file.
///
/// Embeds are left alone. `![[shot.png]]` names a picture, and a reader that turned it into the bare
/// word `shot.png` would be claiming a file is a sentence.
public func displayingWikilinks(_ text: String) -> String {
    var out = ""
    var index = text.startIndex
    for span in wikilinkSpans(in: text) where !text[span].hasPrefix("!") {
        out += text[index..<span.lowerBound]
        out += wikilinkDisplayName(String(text[span]))
        index = span.upperBound
    }
    out += text[index...]
    return out
}

/// What a `[[…]]` reads as: the alias when it has one, else the target.
///
/// The alias rule is the vault's — `[[note|shown as this]]` — and the same one `MarkdownHighlight`
/// applies when it decides which half of a wikilink to colour.
public func wikilinkDisplayName(_ token: String) -> String {
    let inner = token.trimmingCharacters(in: CharacterSet(charactersIn: "![]"))
    guard let pipe = inner.firstIndex(of: "|") else { return inner }
    return String(inner[inner.index(after: pipe)...])
}

/// The spans of `text` that are wikilinks, paired with what each reads as — everything a caller needs
/// to draw the tokens as tokens without re-deriving the grammar.
///
/// Returned as (range, displayName) rather than as a rewritten string, because a row that wants to
/// *style* the names needs to know where they are, and one that only wants to read them has
/// `displayingWikilinks` above.
public func wikilinkDisplaySpans(in text: String) -> [(range: Range<String.Index>, name: String)] {
    wikilinkSpans(in: text)
        .filter { !text[$0].hasPrefix("!") }
        .map { ($0, wikilinkDisplayName(String(text[$0]))) }
}

/// Where each token's name lands in `displayingWikilinks(text)`, as character offsets into the
/// *display* string.
///
/// The arithmetic lives here rather than at the drawing site because it is the part that's easy to get
/// wrong and impossible to see when it is: every token rewritten shortens the string, so each one
/// after it shifts left by the total removed so far. A row that got this wrong would tint a few
/// characters beside the name rather than the name, which reads as a rendering glitch rather than as a
/// bug in an offset.
public func wikilinkDisplayRanges(in text: String) -> [(offset: Int, length: Int, name: String)] {
    var out: [(offset: Int, length: Int, name: String)] = []
    var removed = 0
    for span in wikilinkDisplaySpans(in: text) {
        let source = text.distance(from: text.startIndex, to: span.range.lowerBound)
        let sourceLength = text.distance(from: span.range.lowerBound, to: span.range.upperBound)
        out.append((offset: source - removed, length: span.name.count, name: span.name))
        removed += sourceLength - span.name.count
    }
    return out
}
