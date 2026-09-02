import Foundation
import PmLib

/// How a surface says the date it just read off a typed line.
///
/// Shared between the quick bar's badge and the add editor's, because they answer the same question
/// about the same parse and a second wording would be a second opinion. Written in full — "Fri Sep 5",
/// not "in 4d" — where a task's own badge says how long is left: a badge on an existing task tells you
/// how much time you have, while this confirms that the "friday 3pm" you typed a second ago landed on
/// the day you meant.
extension QuickCaptureParser.Result {
    var dueLabel: String? { DueLabels.due(due) }
    var unreadableDueLabel: String? { DueLabels.unreadable(unreadableDue) }
}

enum DueLabels {
    /// A stored `due:` value spelled out — with the time when one was typed — or nil when there is
    /// none.
    static func due(_ stored: String?) -> String? {
        guard let stored, let date = RelativeDue.parse(stored) else { return nil }
        let day = day(date)
        return RelativeDue.carriesTime(stored) ? "\(day) \(RelativeDue.timeLabel(date))" : day
    }

    /// What to say about a `due:` the parser couldn't read.
    ///
    /// The phrase stays in the task text, deliberately — losing "due:thurdsay" to a typo is worse than
    /// a task with a typo in its title. But a line that kept its marker as prose looks exactly like a
    /// line that never had one, and by the time you could tell the difference the surface has closed
    /// and you're somewhere else. Said where the date would have been, so the one slot answers the one
    /// question: what date is this getting?
    static func unreadable(_ phrase: String?) -> String? {
        guard let phrase else { return nil }
        return "“\(truncate(phrase, 18))” isn't a date"
    }

    /// A due date spelled out — "Sat, Aug 22". Shared so a field's badge and a receipt written after
    /// the surface has gone say the date the same way.
    nonisolated static func day(_ date: Date) -> String { formatter.string(from: date) }

    nonisolated static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let trimmed = cut.contains(" ") ? cut[cut.startIndex..<cut.lastIndex(of: " ")!] : cut
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
    }

    nonisolated private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}
