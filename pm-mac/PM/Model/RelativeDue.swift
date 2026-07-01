import Foundation

/// Relative due-date formatting shared by the menubar and the panel, ported from the Raycast
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

    /// Compact menubar form: "today", "tomorrow", "in 2d", "3d ago", "in 2w", "7/4". Mirrors
    /// `formatDueForMenubar`/`formatRelativeDueShort` (day-granularity variant).
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
        default:
            guard let date = parse(raw) else { return String(raw.prefix(10)) }
            let c = Calendar.current.dateComponents([.month, .day], from: date)
            return "\(c.month ?? 0)/\(c.day ?? 0)"
        }
    }
}
