import Foundation

/// How much of a card is worth drawing at the zoom you're at.
enum CanvasDetail {
    /// Below this magnification a card stops rendering its content and draws a summary instead.
    ///
    /// The number is where a 13pt body font falls under about 6pt on screen — the point at which the
    /// text is a grey texture rather than words. Everything spent rendering it below that is spent on
    /// something nobody can read: a markdown layout, a PDF page, a web renderer, per card, on a board
    /// that at this zoom is showing you fifty of them at once.
    ///
    /// What replaces it is not less information but differently chosen information — one line, drawn
    /// large enough to actually read. Zoomed out is when you are looking for a card rather than
    /// reading one, and a card you can identify beats a card you can't.
    static let simplifiedBelow: Double = 0.5

    /// Above this magnification a link card embeds the live page.
    ///
    /// Lower than `simplifiedBelow`, and deliberately: the argument that retires a note at 0.5 doesn't
    /// apply to a page. A note below that zoom is a texture because a note *is* its words. A rendered
    /// page is a shape — a masthead, a column, a hero image, a colour — and it stays recognisable long
    /// after its body text has stopped being legible. It is the same exemption pictures already get.
    ///
    /// 0.2 because that is the zoom real boards are actually read at. The one board in this vault with
    /// link cards on it spans 4460×2435, which fits a full-screen window at 0.33 and a default one at
    /// 0.24 — so at 0.5 every card on it was a favicon and a hostname, at every zoom that showed more
    /// than a corner. The feature worked exactly as written and was invisible.
    ///
    /// The cost is real and is the reason for a floor at all: below this a board of link cards is a
    /// screenful of live renderers. A favicon and a host is the right answer *somewhere*, just much
    /// further out than a note's threshold.
    static let pagesLoadAbove: Double = 0.2
}

/// The one line that stands for a card when it's too small to read.
///
/// Markdown's markers are all noise here — `# ` in front of a heading tells you it's a heading, which
/// at this size you can neither see nor use — so they come off, and what's left is the words. An embed
/// is skipped rather than shown as its filename: a card whose first line is a screenshot is a card
/// about whatever the *next* line says, and `![[CleanShot 2025-02-24 at 20.36.04@2x.png]]` is the
/// least useful thing that card could be called.
func canvasCardSummary(_ text: String) -> String {
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

/// What the pill on a web card says: how old the thing you are looking at is.
///
/// A dashboard's whole claim is that it is showing you the current state of something, and a card has
/// two ways of quietly breaking that claim — it can be a page loaded when you opened the board an hour
/// ago and never refreshed since, or it can be a picture of a page that has been paused. Neither looks
/// any different from a live one. So every card that is showing a page says when what it is showing
/// arrived, and the answer is the same sentence in both cases, because from where you are sitting it
/// is the same fact.
///
/// Clock time rather than "42 minutes ago" for anything past the first minute. A dashboard is read
/// against your own day — you know when standup was, and when you last looked — and "as of 09:12"
/// answers that directly where an elapsed count makes you do the subtraction.
func canvasFreshnessLabel(for loaded: Date, now: Date = Date(),
                          calendar: Calendar = .current, locale: Locale = .current) -> String {
    let age = now.timeIntervalSince(loaded)
    // Under a minute there is no useful clock answer — the time it shows would be the time it is.
    if age < 60 { return "just now" }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone

    if calendar.isDate(loaded, inSameDayAs: now) {
        formatter.setLocalizedDateFormatFromTemplate("jmm")
    } else if age < 6 * 24 * 60 * 60 {
        // Within the week, the day of the week is what you actually think in.
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
    } else {
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
    }
    return "as of \(formatter.string(from: loaded))"
}
