import Foundation
import PmLib

// MARK: - Time, laid out
//
// The arithmetic behind the rail, week and month layouts (docs/views.md D9), kept apart from the drawing
// so what a layout covers and where a block lands can be tested without drawing anything.

/// The days a week or month layout draws, and the span its query is asked for.
struct CanvasCalendarSpan: Equatable {
    /// Each day drawn, in order, as a local `YYYY-MM-DD`. A week is seven; a month is whole weeks.
    let days: [String]
    /// The month a Day's month grid is of, `YYYY-MM`, so the days either side of it are drawn quieter.
    /// Nil where every day is in play: a week, and Coming up's five weeks.
    let month: String?
    /// What the query is asked about: the first day drawn to the day after the last.
    let range: DoneRange
    /// What the card's header calls it: "This Week · Sep 13–19", "September 2026", "Next 5 Weeks".
    let title: String
}

extension CanvasViewSpec {
    /// What a week or month layout covers, or nil for the list and the rail, which draw the period.
    ///
    /// **A Day's week and month are the calendar's**, found around the period's first day — so a Today
    /// card laid out as a month is this month, and a card pinned to Jun 3 is June: a page of the
    /// journal. **Coming up's roll**, as its period does: its week is the next seven days, and its month
    /// is five weeks from the start of this one, because a deadline on the 2nd matters on the 30th and
    /// a calendar month would hide it.
    func calendarSpan(now: Date = Date(), calendar: Calendar = .current) throws -> CanvasCalendarSpan? {
        let layout = shownLayout
        guard layout == .week || layout == .month else { return nil }
        let today = calendar.startOfDay(for: now)
        if kind == .comingUp {
            if layout == .week {
                return try Self.span(from: today, days: 7, month: nil, title: "Next 7 Days", calendar: calendar)
            }
            let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            return try Self.span(from: start, days: 35, month: nil, title: "Next 5 Weeks", calendar: calendar)
        }
        let anchor = try period.range(now: now, calendar: calendar).start
        if layout == .week {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return nil }
            let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
            // "Sep 13–19", and "Sep 27–Oct 3" across a month's end.
            let sameMonth = calendar.isDate(week.start, equalTo: last, toGranularity: .month)
            let dates = "\(Self.format(week.start, "MMM d", calendar))–\(Self.format(last, sameMonth ? "d" : "MMM d", calendar))"
            let title = week.contains(now) ? "This Week · \(dates)"
                : calendar.component(.year, from: week.start) == calendar.component(.year, from: now)
                    ? "Week of \(Self.format(week.start, "MMM d", calendar))"
                    : "Week of \(Self.format(week.start, "MMM d, yyyy", calendar))"
            return try Self.span(from: week.start, days: 7, month: nil, title: title, calendar: calendar)
        }
        guard let month = calendar.dateInterval(of: .month, for: anchor),
              let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end),
              let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end else { return nil }
        let days = calendar.dateComponents([.day], from: first, to: end).day ?? 35
        return try Self.span(from: first, days: days, month: Self.format(month.start, "yyyy-MM", calendar),
                         title: Self.format(month.start, "LLLL yyyy", calendar), calendar: calendar)
    }

    /// The period one week or month on (`by` +1) or back (-1) from this one's, for a Day laid out as a
    /// week or a month — pinned to that span's first day, or back to Today when the span is the one
    /// today is in, so paging back to now is following the clock again. Nil where there's nothing to
    /// page: a list, a rail, and Coming up, whose horizon starts today.
    func stepped(by step: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Period? {
        let layout = shownLayout
        guard kind == .day, layout == .week || layout == .month else { return nil }
        let component: Calendar.Component = layout == .week ? .weekOfYear : .month
        let anchor = try period.range(now: now, calendar: calendar).start
        guard let moved = calendar.date(byAdding: component, value: step, to: anchor),
              let span = calendar.dateInterval(of: component, for: moved) else { return nil }
        return span.contains(now) ? .today : .day(Self.format(span.start, "yyyy-MM-dd", calendar))
    }

    /// Whether this is laid out on the span today is in — which Today, in the header, would bring back.
    func showsToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let span = try? calendarSpan(now: now, calendar: calendar) else { return true }
        return span.range.contains(now)
    }

    private static func span(from start: Date, days count: Int, month: String?, title: String,
                             calendar: Calendar) throws -> CanvasCalendarSpan {
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { format($0, "yyyy-MM-dd", calendar) }
        // First day to the last, inclusive, as a report's since and until are.
        let range = try DoneRange.resolve(period: nil, since: days.first, until: days.last, calendar: calendar)
        return CanvasCalendarSpan(days: days, month: month, range: range, title: title)
    }

    static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Where things land on the rail and in a week's columns.
enum CanvasTimeGrid {
    /// Minutes past midnight in a heading's time, "9:10 AM" or "2:15 PM". Nil for a sitting with no time,
    /// which is drawn as "Earlier".
    static func minutes(of startTime: String?) -> Int? {
        guard let startTime,
              let match = startTime.firstMatch(of: /^\s*(\d{1,2}):(\d{2})\s*([AaPp])[Mm]\s*$/),
              var hour = Int(match.1), let minute = Int(match.2), (1...12).contains(hour), minute < 60
        else { return nil }
        let pm = match.3.lowercased() == "p"
        if hour == 12 { hour = 0 }
        return (hour + (pm ? 12 : 0)) * 60 + minute
    }

    /// Minutes past local midnight of an instant, for a completion with a clock time but no sitting.
    static func minutes(ofInstant instant: String, calendar: Calendar = .current) -> Int? {
        guard let date = DoneLog.date(instant) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return hour * 60 + minute
    }

    /// Where each of a rail's blocks begins, from the top: at least `gap` below the one before, and
    /// further by the time between their starts at `perMinute` — so a quiet afternoon is empty rail,
    /// and a busy morning is blocks one after another. A block with no time follows its neighbour.
    /// Nothing is scaled by how long a sitting ran: the heading doesn't say, and the rail isn't a
    /// timesheet (D5).
    static func railTops(heights: [CGFloat], minutes: [Int?], perMinute: CGFloat, gap: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        var last: (top: CGFloat, minute: Int)?
        for index in heights.indices {
            var top: CGFloat = 0
            if let previous = tops.last { top = previous + heights[index - 1] + gap }
            if let minute = minutes[index], let last, minute > last.minute {
                top = max(top, last.top + CGFloat(minute - last.minute) * perMinute)
            }
            tops.append(top)
            if let minute = minutes[index] { last = (top, minute) }
        }
        return tops
    }

    /// The hours a week's grid spans: the working day, widened to take in every timed sitting — an
    /// early start, a late one — with room for the last one's block.
    static func hours(for minutes: [Int], workday: ClosedRange<Int> = 9...17) -> ClosedRange<Int> {
        guard let first = minutes.min(), let last = minutes.max() else { return workday }
        return min(workday.lowerBound, first / 60)...max(workday.upperBound, min(24, last / 60 + 1))
    }

    /// Where each block in one column lands: at its start on the grid, or just below the block before
    /// when two sittings began too close together to both fit. `minutes` in order.
    static func columnTops(minutes: [Int], firstHour: Int, perHour: CGFloat, blockHeight: CGFloat,
                           gap: CGFloat = 2) -> [CGFloat] {
        var tops: [CGFloat] = []
        for minute in minutes {
            var top = CGFloat(minute - firstHour * 60) / 60 * perHour
            if let previous = tops.last { top = max(top, previous + blockHeight + gap) }
            tops.append(top)
        }
        return tops
    }

    /// Something on the rail: a sitting, or a completion that fell in none.
    struct RailEntry: Identifiable {
        enum Kind {
            case sitting(SittingEntry)
            case done(DoneItem)
        }
        let id: String
        let minute: Int?
        let kind: Kind
    }

    /// The day's sittings and its stray completions, in the order the day went: a sitting with no time
    /// first, as the list has it ("Earlier").
    static func railEntries(_ list: SittingList, calendar: Calendar = .current) -> [RailEntry] {
        var entries = list.sittings.map {
            RailEntry(id: $0.id, minute: CanvasTimeGrid.minutes(of: $0.startTime), kind: .sitting($0))
        }
        entries += list.elsewhere.enumerated().map { index, item in
            RailEntry(id: "done/\(index)/\(item.at)", minute: CanvasTimeGrid.minutes(ofInstant: item.at, calendar: calendar),
                      kind: .done(item))
        }
        return entries.enumerated().sorted { a, b in
            switch (a.element.minute, b.element.minute) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): return x != y ? x < y : a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Sittings in the order a day went: untimed first, then by start.
    static func ordered(_ sittings: [SittingEntry]) -> [SittingEntry] {
        sittings.enumerated().sorted { a, b in
            let (x, y) = (CanvasTimeGrid.minutes(of: a.element.startTime), CanvasTimeGrid.minutes(of: b.element.startTime))
            if x == y { return a.offset < b.offset }
            guard let x else { return true }
            guard let y else { return false }
            return x < y
        }.map(\.element)
    }
}

extension SittingEntry {
    /// Which sitting this is, across projects.
    var id: String { "\(projectFolder)/\(session)/\(sessionOrdinal)/\(sessionDigest)" }
}
