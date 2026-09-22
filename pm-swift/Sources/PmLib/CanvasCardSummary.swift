import Foundation

// The words a card is reduced to when there is room for one line of it: on the board zoomed out, in a
// tile's tab, in Add Card from Canvas, and in every item lens (docs/items.md D2). Moved here from the
// app so that `CanvasItem` — and therefore `card.list`, which runs with no app at all — names a card
// exactly as the board does. `CanvasDetail`, which is about zoom, stayed behind.

/// The one line that stands for a card when it's too small to read.
///
/// Markdown's markers are all noise here — `# ` in front of a heading tells you it's a heading, which
/// at this size you can neither see nor use — so they come off, and what's left is the words. An embed
/// is skipped rather than shown as its filename: a card whose first line is a screenshot is a card
/// about whatever the *next* line says, and `![[CleanShot 2025-02-24 at 20.36.04@2x.png]]` is the
/// least useful thing that card could be called.
public func canvasCardSummary(_ text: String) -> String {
    for line in text.components(separatedBy: .newlines) {
        let cleaned = strippedOfMarkdown(line)
        if !cleaned.isEmpty { return cleaned }
    }
    // Nothing but embeds and blank lines. The card is a picture, and saying so beats saying nothing.
    return text.contains("![") || text.contains("![[") ? "Image" : ""
}

private func strippedOfMarkdown(_ line: String) -> String {
    var text = line.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return "" }

    // Block markers, in the order they can stack: `> - # something`.
    var changed = true
    while changed {
        changed = false
        for marker in [">", "-", "*", "+"] where text.hasPrefix(marker + " ") {
            text = String(text.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
            changed = true
        }
        if text.hasPrefix("#") {
            let hashes = text.prefix(while: { $0 == "#" })
            let rest = text.dropFirst(hashes.count)
            if rest.hasPrefix(" ") {
                text = String(rest).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        // A numbered list marker: `1. `, `12) `.
        if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }),
           text.distance(from: text.startIndex, to: dot) <= 3,
           text[text.startIndex..<dot].allSatisfy(\.isNumber),
           text.index(after: dot) < text.endIndex,
           text[text.index(after: dot)] == " " {
            text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            changed = true
        }
        // A task's checkbox, which is a list marker's passenger.
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            changed = true
        }
    }

    text = withoutEmbeds(text)
    // Inline emphasis, and the brackets around a vault reference — the words inside them are the
    // point, and `[[Vallaki]]` reads as `Vallaki`.
    for marker in ["**", "__", "*", "_", "`", "==", "~~", "[[", "]]"] {
        text = text.replacingOccurrences(of: marker, with: "")
    }
    // A horizontal rule is a line with nothing to say.
    if text.allSatisfy({ $0 == "-" || $0 == "=" }) { return "" }
    return text.trimmingCharacters(in: .whitespaces)
}

/// Remove `![[…]]` and `![](…)` embeds, leaving anything written beside them.
private func withoutEmbeds(_ text: String) -> String {
    var out = text
    for pattern in [#"!\[\[[^\]]*\]\]"#, #"!\[[^\]]*\]\([^)]*\)"#] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                             withTemplate: "")
    }
    return out.trimmingCharacters(in: .whitespaces)
}