import Foundation

/// Relative due-date formatting shared by the menubar and the task views, ported from the Raycast
/// extension's `format-relative-due.ts` so both surfaces read identically. `due:` values are stored
/// as `YYYY-MM-DD` (optionally ` HH:mm`); a bare date is treated as noon local time, matching the CLI.
enum RelativeDue {
    /// Parse a stored `due:` value into a `Date` (local). Returns nil for unparseable input.
    static func parse(_ raw: String) -> Date? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "due:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 10 else { return nil }
        let datePart = String(cleaned.prefix(10))
        var comps = DateComponents()
        let bits = datePart.split(separator: "-")
        guard bits.count == 3, let y = Int(bits[0]), let mo = Int(bits[1]), let d = Int(bits[2]) else { return nil }
        comps.year = y; comps.month = mo; comps.day = d

        // Optional trailing " HH:mm"; a bare date means noon (so "today" doesn't read as overdue at 00:01).
        let rest = cleaned.dropFirst(10).trimmingCharacters(in: .whitespaces)
        if rest.count >= 4, let colon = rest.firstIndex(of: ":") {
            let h = Int(rest[rest.startIndex..<colon])
            let m = Int(rest[rest.index(after: colon)...].prefix(2))
            comps.hour = h ?? 12; comps.minute = m ?? 0
        } else {
            comps.hour = 12; comps.minute = 0
        }
        return Calendar.current.date(from: comps)
    }

    /// True when the due date is in the past. Unparseable dates are never overdue.
    static func isOverdue(_ raw: String) -> Bool {
        guard let date = parse(raw) else { return false }
        return date < Date()
    }

    /// Whole-calendar-day delta from today (negative = past), for coarse "soon/overdue" styling.
    static func dayDelta(_ raw: String) -> Int? {
        guard let date = parse(raw) else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: from, to: to).day
    }

    /// The badge form, everywhere a due date is shown small: "today", "tomorrow", "in 2d", "3d ago",
    /// "in 2w", "in 3mo", "2y ago".
    ///
    /// Relative all the way out. This used to fall back to a bare "7/4" past a month, which is the one
    /// answer a badge can't use — a date is a fact you have to do arithmetic on, and the whole reason
    /// a badge is three characters wide is that you read it without doing any. Distant dates just get
    /// a coarser unit. The exact date is never lost: it's the tooltip, `full(_:)`.
    ///
    /// Units are floored, not rounded, so a badge never claims more time than there is — "in 1mo" can
    /// mean anything from 30 to 59 days away, and never fewer than it says.
    static func short(_ raw: String) -> String {
        guard let days = dayDelta(raw) else { return String(raw.prefix(10)) }
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2..<7: return "in \(days)d"
        case -6 ..< 0: return "\(-days)d ago"
        case 7..<30: return "in \(days / 7)w"
        case -29 ... -7: return "\(-days / 7)w ago"
        case 30..<365: return "in \(days / 30)mo"
        case -364 ... -30: return "\(-days / 30)mo ago"
        case 365...: return "in \(days / 365)y"
        default: return "\(-days / 365)y ago"
        }
    }

    /// The unabbreviated date behind a badge, for its tooltip: "Tuesday, August 25, 2026", with the
    /// time appended when the stored value carried one.
    ///
    /// This is the other half of `short(_:)`. A relative badge is quicker to read and worse to act on —
    /// "in 3mo" doesn't tell you whether that clears a deadline — so the precise date has to stay one
    /// hover away rather than being dropped. Localized, because unlike the stored `YYYY-MM-DD` this is
    /// prose the user reads.
    ///
    /// Unparseable input returns itself: a tooltip showing the raw stored text is the most useful
    /// thing to say about a date the app couldn't read, and it's what makes the bad value visible.
    static func full(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw.trimmingCharacters(in: .whitespaces) }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = carriesTime(raw) ? .short : .none
        return formatter.string(from: date)
    }

    /// Whether a stored value pins a time of day, rather than being a bare date that `parse` defaults
    /// to noon. Not just the tooltip's concern — the quick bar's preview and confirmation lines use it
    /// too, to say the time back rather than showing "12:00 PM" on every dateless date, which would be
    /// inventing a precision the user never set.
    static func carriesTime(_ raw: String) -> Bool {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "due:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 10 else { return false }
        let rest = cleaned.dropFirst(10).trimmingCharacters(in: .whitespaces)
        return rest.count >= 4 && rest.contains(":")
    }

    /// A time of day on its own, in the locale's short style: "3:00 PM". Paired with `carriesTime` so
    /// a caller only says it when the stored value actually pinned one.
    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
