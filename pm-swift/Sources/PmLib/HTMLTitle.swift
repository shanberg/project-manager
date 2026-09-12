import Foundation

/// The name a page gives itself, read out of its HTML.
///
/// A link added to a project is a URL and, if you typed one, a label. Nine times out of ten you didn't
/// — typing out "Q3 Migration Runbook" when you have just pasted the URL of a page called exactly that
/// is work the page could have done — so the page is asked, and the answer becomes the label.
///
/// **Hand-parsed rather than run through a parser.** One tag is wanted out of a document this app has
/// no other interest in; bringing in an HTML parser to find it, or standing up a web view to render a
/// page nobody will look at, are both larger than the question. What this is asked of, in practice, is
/// the first few kilobytes of a response — see `LinkTitleLoader`, which stops reading at the head.
///
/// **`<title>` first and `og:title` only as a fallback.** They are usually the same sentence and the
/// Open Graph one is often the tidier of the two, with the " | Company Name" tail left off. Preferring
/// it anyway would mean a label that differs depending on whether the page happens to be built for
/// sharing, and `<title>` is what the browser tab says — which is what somebody who fetched the page
/// themselves would have copied.
public enum HTMLTitle {

    /// What this page calls itself, or nil if it doesn't say.
    public static func read(_ html: String) -> String? {
        if let title = element(named: "title", in: html) { return title }
        return metaContent(property: "og:title", in: html)
    }

    // MARK: Finding it

    /// The text of the first `<name>…</name>`, with its attributes skipped.
    private static func element(named name: String, in html: String) -> String? {
        var cursor = html.startIndex
        while let open = html.range(of: "<" + name, options: .caseInsensitive,
                                    range: cursor..<html.endIndex) {
            cursor = open.upperBound
            // `<titlebar>` starts with `<title`. The tag has ended here only if what follows the name
            // is the end of the tag or the whitespace before an attribute.
            guard let next = html[open.upperBound...].first,
                  next == ">" || next.isWhitespace || next == "/" else { continue }
            guard let gt = html[open.upperBound...].firstIndex(of: ">") else { return nil }
            let start = html.index(after: gt)
            guard let close = html.range(of: "</" + name, options: .caseInsensitive,
                                         range: start..<html.endIndex) else { return nil }
            let text = clean(String(html[start..<close.lowerBound]))
            if !text.isEmpty { return text }
            cursor = close.upperBound
        }
        return nil
    }

    /// The `content` of the first `<meta>` carrying `property`.
    ///
    /// Matched against the whole tag rather than against a `property="…"` spelling, because the same
    /// meta is written as `property`, as `name`, and with either quote — and a tag that merely mentions
    /// `og:title` somewhere else is not a thing that happens.
    private static func metaContent(property: String, in html: String) -> String? {
        var cursor = html.startIndex
        while let open = html.range(of: "<meta", options: .caseInsensitive,
                                    range: cursor..<html.endIndex) {
            guard let gt = html[open.upperBound...].firstIndex(of: ">") else { return nil }
            let tag = String(html[open.upperBound..<gt])
            cursor = html.index(after: gt)
            guard tag.range(of: property, options: .caseInsensitive) != nil,
                  let value = attribute("content", in: tag) else { continue }
            let text = clean(value)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The value of `name=…` inside one tag's attributes, quoted either way or not at all.
    private static func attribute(_ name: String, in tag: String) -> String? {
        var cursor = tag.startIndex
        while let found = tag.range(of: name, options: .caseInsensitive, range: cursor..<tag.endIndex) {
            cursor = found.upperBound
            // `data-content=` ends in `content` too, so the character before has to be a boundary.
            if found.lowerBound > tag.startIndex {
                let before = tag[tag.index(before: found.lowerBound)]
                guard before.isWhitespace else { continue }
            }
            var index = found.upperBound
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] == "=" else { continue }
            index = tag.index(after: index)
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex else { return nil }
            let quote = tag[index]
            if quote == "\"" || quote == "'" {
                let start = tag.index(after: index)
                guard let end = tag[start...].firstIndex(of: quote) else { return nil }
                return String(tag[start..<end])
            }
            let end = tag[index...].firstIndex(where: \.isWhitespace) ?? tag.endIndex
            return String(tag[index..<end])
        }
        return nil
    }

    // MARK: Reading it as a line

    /// Entities resolved and every run of whitespace closed up to one space.
    ///
    /// A `<title>` is routinely written across three indented lines of source and means one line; a
    /// label carrying the indentation would be the page's formatting showing up in somebody's notes.
    static func clean(_ raw: String) -> String {
        let text = decodeEntities(raw)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The handful of entities that turn up in real titles: the five XML ones, the non-breaking space,
    /// the punctuation a site puts between its page and its name, and any numeric escape.
    ///
    /// Not the full HTML entity table, which is about two thousand names and would be a data file
    /// carried for the sake of a label. An entity this doesn't know is left as it was written, which
    /// reads as slightly wrong rather than as nothing. The named list is short because the *numeric*
    /// branch below is what most of the rest arrive as.
    private static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var out = ""
        var rest = Substring(raw)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            // An entity is short; a bare `&` in a title is not the start of one and shouldn't eat the
            // rest of the line looking for a semicolon.
            guard let end = rest.prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = rest.dropFirst()
                continue
            }
            let name = String(rest[rest.index(after: rest.startIndex)..<end])
            out += resolve(name) ?? String(rest[rest.startIndex...end])
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    private static func resolve(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        // The separators a site puts between the page's name and its own, which is the one place a
        // named entity beyond the five reliably turns up.
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "hellip": return "\u{2026}"
        case "middot": return "\u{00B7}"
        case "lsquo": return "\u{2018}"
        case "rsquo": return "\u{2019}"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value = digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits)
        return value.flatMap(UnicodeScalar.init).map(String.init)
    }
}
