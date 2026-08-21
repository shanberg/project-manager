import Foundation

/// Splits a line typed into the quick bar into task text and an optional due date.
///
/// The marker is `due:`, which is the notes format's own — a task line already reads
/// `- [ ] Ship it due:2026-09-01`, so the thing you type to set a date is the thing that ends up in
/// the file. Nothing else is invented syntax to learn.
///
/// What follows it is the language the badges already speak: `RelativeDue.short` writes "tomorrow"
/// and "in 2w", and `DueSuggestion` names "Next Week", so those read back in. A date the parser
/// can't make sense of is left in the text rather than dropped — silently losing "due:thurdsay" to a
/// typo is worse than a task whose title has a typo in it.
enum QuickCaptureParser {
    struct Result: Equatable {
        var text: String
        /// Stored form, `YYYY-MM-DD`, or nil when no date was given.
        var due: String?
    }

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: "due:", options: [.caseInsensitive, .backwards]) else {
            return Result(text: trimmed, due: nil)
        }
        // Only a `due:` that starts a word — "overdue:" isn't a date marker.
        if marker.lowerBound != trimmed.startIndex {
            let before = trimmed[trimmed.index(before: marker.lowerBound)]
            guard before == " " else { return Result(text: trimmed, due: nil) }
        }
        let phrase = trimmed[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let date = date(from: phrase, now: now, calendar: calendar) else {
            return Result(text: trimmed, due: nil)
        }
        let text = trimmed[trimmed.startIndex..<marker.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: text, due: DueFormat.string(date))
    }

    /// Resolve a due phrase to a day, or nil if it isn't one.
    static func date(from phrase: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let cleaned = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleaned.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)

        // A written-out date, the stored form.
        if let exact = DueFormat.parse(cleaned), cleaned.count >= 10 { return exact }

        // The presets the due menu offers, matched on their own names ("this weekend", "next week").
        if let option = DueSuggestion.options(now: now, calendar: calendar)
            .first(where: { $0.title.lowercased() == cleaned }) {
            return option.date
        }
        if cleaned == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: today) }

        // A weekday name means the next one of those — "friday" on a Friday is a week away, not today,
        // since a task due today would have been typed as "today".
        if let weekday = weekdayNumber(cleaned) {
            return calendar.nextDate(after: today, matching: DateComponents(weekday: weekday),
                                     matchingPolicy: .nextTime)
        }

        // "in 3d" / "in 2w" / "in 4mo" — the badge's own shorthand, read back.
        return offsetDate(cleaned, from: today, calendar: calendar)
    }

    // MARK: Pieces

    private static func weekdayNumber(_ name: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let full = formatter.weekdaySymbols.map { $0.lowercased() }
        let short = formatter.shortWeekdaySymbols.map { $0.lowercased() }
        if let index = full.firstIndex(of: name) { return index + 1 }
        if let index = short.firstIndex(of: name) { return index + 1 }
        return nil
    }

    /// "in <n><unit>", with or without the space: d(ay), w(eek), mo(nth), y(ear).
    private static func offsetDate(_ phrase: String, from today: Date, calendar: Calendar) -> Date? {
        guard phrase.hasPrefix("in ") else { return nil }
        let rest = phrase.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber }
        guard let amount = Int(digits), amount > 0 else { return nil }
        let unit = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "d", "day", "days": return calendar.date(byAdding: .day, value: amount, to: today)
        case "w", "week", "weeks": return calendar.date(byAdding: .day, value: amount * 7, to: today)
        case "mo", "month", "months": return calendar.date(byAdding: .month, value: amount, to: today)
        case "y", "year", "years": return calendar.date(byAdding: .year, value: amount, to: today)
        default: return nil
        }
    }
}
