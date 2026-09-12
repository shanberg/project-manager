import Foundation

/// How a `due:` value is read back to a person: "today", "in 2d", "3w ago".
///
/// **One implementation, here, because there were three and they disagreed.** This lived in the Mac
/// app, ported by hand from the Raycast extension's `format-relative-due.ts` with a header claiming
/// "so both surfaces read identically". They did not: the Swift copy floored its units and the
/// TypeScript copy rounded them, so **eighteen of the fifty-nine day-offsets inside a month rendered
/// differently** — a task eleven days out read "in 1w" in the menubar and "in 2w" in Raycast.
/// `CaptureParse` already refers to `RelativeDue.short` in a comment, describing a type it could not
/// see; that is what a thing living in the wrong module looks like.
///
/// `due:` values are stored as `YYYY-MM-DD`, optionally ` HH:mm`; a bare date is treated as noon local
/// time, matching the CLI, so "today" doesn't read as overdue at 00:01.
public enum RelativeDue {

    /// Parse a stored `due:` value into a `Date` (local). Returns nil for unparseable input.
    public static func parse(_ raw: String) -> Date? {
        let cleaned = stripped(raw)
        guard cleaned.count >= 10 else { return nil }
        let datePart = String(cleaned.prefix(10))
        var comps = DateComponents()
        let bits = datePart.split(separator: "-")
        guard bits.count == 3, let y = Int(bits[0]), let mo = Int(bits[1]), let d = Int(bits[2]) else { return nil }
        comps.year = y; comps.month = mo; comps.day = d

        // Optional trailing " HH:mm"; a bare date means noon.
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
    public static func isOverdue(_ raw: String, now: Date = Date()) -> Bool {
        guard let date = parse(raw) else { return false }
        return date < now
    }

    /// Whole-calendar-day delta from today (negative = past), for coarse "soon/overdue" styling.
    public static func dayDelta(_ raw: String, now: Date = Date()) -> Int? {
        guard let date = parse(raw) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                  to: cal.startOfDay(for: date)).day
    }

    /// The badge form, everywhere a due date is shown small: "today", "tomorrow", "in 2d", "3d ago",
    /// "in 2w", "in 3mo", "2y ago".
    ///
    /// Relative all the way out. This used to fall back to a bare "7/4" past a month, which is the one
    /// answer a badge can't use — a date is a fact you have to do arithmetic on, and the whole reason
    /// a badge is three characters wide is that you read it without doing any. Distant dates just get
    /// a coarser unit. The exact date is never lost: it's the tooltip, `full(_:)`.
    ///
    /// **Units are floored, not rounded**, so a badge never claims more time than there is — "in 1mo"
    /// can mean anything from 30 to 59 days away, and never fewer than it says. This is the rule the
    /// TypeScript copy broke by rounding, and it is the reason flooring is the one that survived:
    /// a deadline you read as further off than it is, is the failure that costs something.
    public static func short(_ raw: String, now: Date = Date()) -> String {
        guard let days = dayDelta(raw, now: now) else { return String(raw.prefix(10)) }
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
    public static func full(_ raw: String) -> String {
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
    public static func carriesTime(_ raw: String) -> Bool {
        let cleaned = stripped(raw)
        guard cleaned.count >= 10 else { return false }
        let rest = cleaned.dropFirst(10).trimmingCharacters(in: .whitespaces)
        return rest.count >= 4 && rest.contains(":")
    }

    /// A time of day on its own, in the locale's short style: "3:00 PM". Paired with `carriesTime` so
    /// a caller only says it when the stored value actually pinned one.
    public static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: Keeping the other surfaces honest

    /// One rendered label per day-offset, for every offset inside a month either way.
    ///
    /// **Raycast has to keep its own implementation**, and this is what stops it drifting again. The
    /// extension renders `nextDue` from a list payload that carries the raw value, so asking the
    /// contract for the label would be a subprocess per row — exactly the cost the contract was
    /// designed not to impose. A copy is therefore the right answer; a copy *nothing checks* is what
    /// went wrong last time.
    ///
    /// The range is where the two implementations actually parted company: inside a month, weeks are
    /// the coarsest unit, and flooring against rounding shows up at eighteen of these fifty-nine
    /// offsets. Emitted by `pm due-table`, checked into the extension as a fixture, and asserted
    /// against by its own test.
    public static func conformanceTable(now: Date = Date()) -> [(days: Int, label: String)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return (-29...29).map { days in
            let date = Calendar.current.date(byAdding: .day, value: days, to: now)!
            return (days: days, label: short(formatter.string(from: date), now: now))
        }
    }

    /// The stored value without its optional `due:` prefix or surrounding space. Shared by `parse` and
    /// `carriesTime`, which used to each strip it themselves.
    private static func stripped(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "due:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespaces)
    }
}
