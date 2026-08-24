import Foundation

// MARK: - Due dates as people write them
//
// Moved here from the macOS app so every surface reads a typed line the same way. The quick bar, a
// Raycast form and a model all accept "due:friday"; three implementations of what Friday means is
// three chances for them to disagree about it.

/// `due:` values are stored and displayed as `YYYY-MM-DD`.
public enum DueFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    public static func parse(_ s: String) -> Date? { formatter.date(from: String(s.prefix(10))) }
    public static func string(_ d: Date) -> String { formatter.string(from: d) }
}

/// One of the relative answers a due-date menu offers before it offers a calendar.
public struct DuePreset: Equatable {
    public let title: String
    public let date: Date
}

/// The presets, in the order they're offered.
///
/// Deduplicated by the day they land on, which is what keeps the list honest as the week turns: on a
/// Friday "This Weekend" *is* tomorrow, and on a Saturday it's today, and offering the same date
/// twice under two names invites the reader to believe the second one means something else.
///
/// They are also the words `QuickCaptureParser` reads back, so the list a menu offers and the list a
/// typed line is matched against cannot drift apart.
public func duePresets(now: Date = Date(), calendar: Calendar = .current) -> [DuePreset] {
    let today = calendar.startOfDay(for: now)
    let weekday = calendar.component(.weekday, from: today)
    let isWeekend = weekday == 7 || weekday == 1

    let raw: [(String, Date?)] = [
        ("Today", today),
        ("Tomorrow", calendar.date(byAdding: .day, value: 1, to: today)),
        // Saturday, unless it already is the weekend — then the weekend in question is this one.
        ("This Weekend", isWeekend ? today
            : calendar.nextDate(after: today, matching: DateComponents(weekday: 7),
                                matchingPolicy: .nextTime)),
        ("Next Week", calendar.nextDate(after: today, matching: DateComponents(weekday: 2),
                                        matchingPolicy: .nextTime)),
        ("In Two Weeks", calendar.date(byAdding: .day, value: 14, to: today)),
    ]
    var seen = Set<Date>()
    return raw.compactMap { title, date -> DuePreset? in
        guard let date, seen.insert(date).inserted else { return nil }
        return DuePreset(title: title, date: date)
    }
}

/// Splits a line typed into the quick bar into task text and an optional due date/time.
///
/// The marker is `due:`, which is the notes format's own — a task line already reads
/// `- [ ] Ship it due:2026-09-01`, so the thing you type to set a date is the thing that ends up in
/// the file. Nothing else is invented syntax to learn.
///
/// What follows it is the language the badges already speak: `RelativeDue.short` writes "tomorrow"
/// and "in 2w", and `DueSuggestion` names "Next Week", so those read back in. A trailing time — "3pm",
/// "at 5:30pm", "9:30", "noon" — stacks on top of any of that ("due:friday 3pm", "due:3pm" on its own
/// meaning today) and is written into the stored `HH:mm` suffix `RelativeDue` already reads. A date
/// the parser can't make sense of is left in the text rather than dropped — silently losing
/// "due:thurdsay" to a typo is worse than a task whose title has a typo in it.
public enum QuickCaptureParser {
    public struct Result: Equatable {
        public var text: String
        /// Stored form, `YYYY-MM-DD`, or nil when no date was given.
        public var due: String?
        /// The `due:` phrase that was given and couldn't be read, when there was one.
        ///
        /// The phrase stays in `text` — dropping it silently is worse — but a line that kept its date
        /// marker as prose looks exactly like a line that never had one, and the bar has closed by the
        /// time you'd find out. This is what lets the field say so while you can still fix it.
        public var unreadableDue: String?

        public init(text: String, due: String? = nil, unreadableDue: String? = nil) {
            self.text = text
            self.due = due
            self.unreadableDue = unreadableDue
        }
    }

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: "due:", options: [.caseInsensitive, .backwards]) else {
            return Result(text: trimmed, due: nil)
        }
        // Only a `due:` that starts a word — "overdue:" isn't a date marker, and neither is a line
        // that merely contains the letters, so neither is worth warning about.
        if marker.lowerBound != trimmed.startIndex {
            let before = trimmed[trimmed.index(before: marker.lowerBound)]
            guard before == " " else { return Result(text: trimmed, due: nil) }
        }
        let phrase = trimmed[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let resolved = resolvedDue(from: phrase, now: now, calendar: calendar) else {
            // An empty phrase is a line mid-typing — you have just pressed the colon — so it is not
            // yet a mistake to report. Anything else is a date marker that won't become one.
            return Result(text: trimmed, due: nil, unreadableDue: phrase.isEmpty ? nil : phrase)
        }
        let text = trimmed[trimmed.startIndex..<marker.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: text, due: storedString(resolved, calendar: calendar))
    }

    /// Split a trailing `@…` off a capture line: the text to keep, and the project it names.
    ///
    /// The token runs to the end of the line rather than stopping at the next space, because project
    /// names have spaces in them — `@maxwell carmody` is one query, not a query and a stray word. That
    /// makes it a suffix by construction, which is also the rule to teach: the redirect goes last.
    ///
    /// Never the very first character. A leading `@` is the go-to-project sigil, and on the one line
    /// where it isn't — a task typed with a leading space so it can genuinely begin "@Dana" — treating
    /// it as a redirect would take the escape hatch away again.
    ///
    /// Whether the query names a real project isn't decided here. The caller resolves it against the
    /// project list and leaves the line alone when it matches nothing, so "email @dana" stays a task
    /// about Dana rather than becoming a task filed somewhere surprising.
    public static func splitTarget(_ input: String) -> (text: String, projectQuery: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@"), at != trimmed.startIndex,
              trimmed[trimmed.index(before: at)] == " " else { return nil }
        let query = trimmed[trimmed.index(after: at)...].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let text = trimmed[trimmed.startIndex..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, query)
    }

    /// Resolve a due phrase to a moment — a day, or a day with a time-of-day pinned to it — or nil if
    /// it isn't one.
    public static func date(from phrase: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        resolvedDue(from: phrase, now: now, calendar: calendar)?.date
    }

    /// The canonical stored form a due phrase resolves to — `YYYY-MM-DD`, or `YYYY-MM-DD HH:mm` when
    /// the phrase named a time — or nil when the phrase isn't one. What `parse(_:)` writes into a task
    /// line's `due:` marker, exposed for callers that resolve a due phrase on its own (the `/due`
    /// command) rather than as part of a whole typed line.
    public static func dueString(from phrase: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        resolvedDue(from: phrase, now: now, calendar: calendar).map { storedString($0, calendar: calendar) }
    }

    // MARK: Pieces

    /// A phrase resolved to a moment, and whether it named a specific time or just a day.
    ///
    /// The distinction only matters to the caller writing the stored string: a bare day is written as
    /// `YYYY-MM-DD` so `RelativeDue`'s noon default still applies to it, while a phrase that actually
    /// named a time gets that time appended. Baking a time into every resolution would make
    /// "due:tomorrow" silently claim a precision ("tomorrow at 12:00") nobody typed.
    private struct Resolved {
        let date: Date
        let hasTime: Bool
    }

    private static func resolvedDue(from phrase: String, now: Date, calendar: Calendar) -> Resolved? {
        let cleaned = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleaned.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)

        let (datePhrase, time) = splitTime(cleaned) ?? (cleaned, nil)
        guard let day = day(from: datePhrase, today: today, calendar: calendar) else { return nil }
        guard let time else { return Resolved(date: day, hasTime: false) }
        let moment = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
        return Resolved(date: moment, hasTime: true)
    }

    /// Resolve everything `date(from:)` used to handle on its own, minus a time-of-day: an exact date,
    /// a due-menu preset name, "yesterday", a weekday (optionally "next <weekday>"), or "in <n><unit>".
    ///
    /// An empty phrase means the time-of-day parser ate the whole thing — "due:3pm" has no day left to
    /// name, so it means today, the same as every other bare time means.
    private static func day(from phrase: String, today: Date, calendar: Calendar) -> Date? {
        guard !phrase.isEmpty else { return today }

        // A written-out date, the stored form.
        if let exact = DueFormat.parse(phrase), phrase.count >= 10 { return exact }

        // The presets the due menu offers, matched on their own names ("this weekend", "next week").
        if let preset = duePresets(now: today, calendar: calendar)
            .first(where: { $0.title.lowercased() == phrase }) {
            return preset.date
        }
        if phrase == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: today) }

        // A weekday name — bare, or written out as "next <weekday>" — means the next one of those:
        // "friday" on a Friday is a week away, not today, since a task due today would have been typed
        // as "today".
        let weekdayPhrase = phrase.hasPrefix("next ") ? String(phrase.dropFirst(5)) : phrase
        if let weekday = weekdayNumber(weekdayPhrase) {
            return calendar.nextDate(after: today, matching: DateComponents(weekday: weekday),
                                     matchingPolicy: .nextTime)
        }

        // "in 3d" / "in 2w" / "in 4mo" — the badge's own shorthand, read back.
        return offsetDate(phrase, from: today, calendar: calendar)
    }

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

    /// Splits a trailing time-of-day off a phrase: "3pm", "3 pm", "3:30pm", "9:30" (24-hour, no
    /// am/pm), "noon", "midnight" — optionally introduced by "at ". Returns the phrase with the time
    /// removed (which can come back empty, for a bare time like "due:3pm") and the time itself, or nil
    /// when the phrase doesn't end in one.
    private static func splitTime(_ phrase: String) -> (String, (hour: Int, minute: Int))? {
        var words = phrase.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        // "3pm" is one word; "3 pm" is two — try the last two joined before falling back to the last
        // word alone, so both spellings resolve to the same time.
        if words.count >= 2, let time = parseTimeToken(words[words.count - 2] + words[words.count - 1]) {
            words.removeLast(2)
            if words.last == "at" { words.removeLast() }
            return (words.joined(separator: " "), time)
        }
        guard let time = parseTimeToken(words[words.count - 1]) else { return nil }
        words.removeLast()
        if words.last == "at" { words.removeLast() }
        return (words.joined(separator: " "), time)
    }

    /// A single time-of-day token: "3pm", "3:30pm", "15:00", "noon", "midnight". A bare hour with no
    /// minutes and no am/pm ("3", "15") is rejected rather than guessed at — it's as likely to be part
    /// of something else (the digits of "in 3d", a stray number) as it is a time.
    private static func parseTimeToken(_ token: String) -> (hour: Int, minute: Int)? {
        if token == "noon" { return (12, 0) }
        if token == "midnight" { return (0, 0) }

        var rest = token
        var meridiem: String?
        if rest.hasSuffix("am") { meridiem = "am"; rest.removeLast(2) }
        else if rest.hasSuffix("pm") { meridiem = "pm"; rest.removeLast(2) }

        let hourPart: Substring
        let minutePart: Substring?
        if let colon = rest.firstIndex(of: ":") {
            hourPart = rest[rest.startIndex..<colon]
            minutePart = rest[rest.index(after: colon)...]
        } else {
            hourPart = rest[...]
            minutePart = nil
        }
        guard let hour = Int(hourPart) else { return nil }

        let minute: Int
        if let minutePart {
            guard minutePart.count == 2, let m = Int(minutePart), m < 60 else { return nil }
            minute = m
        } else {
            minute = 0
        }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm" { return (hour == 12 ? 12 : hour + 12, minute) }
            return (hour == 12 ? 0 : hour, minute)
        }
        // No am/pm: only a 24-hour reading with minutes given counts, e.g. "9:30" or "21:30" — a bare
        // "9" is too ambiguous with everything else that's just a number in a due phrase.
        guard minutePart != nil, (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }

    private static func storedString(_ resolved: Resolved, calendar: Calendar) -> String {
        guard resolved.hasTime else { return DueFormat.string(resolved.date) }
        let comps = calendar.dateComponents([.hour, .minute], from: resolved.date)
        return DueFormat.string(resolved.date) + String(format: " %02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
}
