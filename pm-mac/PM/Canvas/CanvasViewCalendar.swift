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
            // The horizon is the period's (D9): the grid asks for exactly what the list would
            // (`dueCutoff`), so switching Layout never changes what Period already decided — only how
            // it's drawn. `need` is a floor, not the answer: a grid never draws shorter than its own
            // shape even if a stored period and layout disagree (an old or hand-edited file).
            let cutoff = try dueCutoff(until: period.value, now: now, calendar: calendar)
            let start = layout == .week ? today : calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let need = layout == .week ? 7 : 35
            let days = max(need, calendar.dateComponents([.day], from: start, to: cutoff).day ?? need)
            let title = layout == .week ? "Next 7 Days" : "Next 5 Weeks"
            return try Self.span(from: start, days: days, month: nil, title: title, calendar: calendar)
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
    /// Nothing is scaled by how long a sitting ran. The attention log can say (docs/time-tracking.md),
    /// and the rail still doesn't ask: a block's height is what it holds, and a rail of bars sized by
    /// duration is a timesheet (D5).
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

    /// Side by side, for spans in one column that overlap: each span's lane and how many lanes its
    /// cluster — the spans that overlap it, and those that overlap them — needs. A span ending as the next
    /// begins doesn't overlap it. In the order given.
    static func lanes(_ spans: [(start: Int, end: Int)]) -> [(lane: Int, of: Int)] {
        let order = spans.indices.sorted { spans[$0].start != spans[$1].start ? spans[$0].start < spans[$1].start : $0 < $1 }
        var result = Array(repeating: (lane: 0, of: 1), count: spans.count)
        var cluster: [Int] = []
        var laneEnds: [Int] = []
        var clusterEnd = Int.min
        func close() {
            for index in cluster { result[index].of = max(1, laneEnds.count) }
            cluster = []
            laneEnds = []
        }
        for index in order {
            let span = spans[index]
            if span.start >= clusterEnd { close() }
            let lane = laneEnds.firstIndex { $0 <= span.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(span.end) } else { laneEnds[lane] = span.end }
            result[index].lane = lane
            cluster.append(index)
            clusterEnd = cluster.count == 1 ? span.end : max(clusterEnd, span.end)
        }
        close()
        return result
    }

    /// Something on the rail: a sitting, a completion that fell in none, or a calendar event.
    struct RailEntry: Identifiable {
        enum Kind {
            case sitting(SittingEntry)
            case done(DoneItem)
            case event(ProjectEvent)
        }
        let id: String
        let minute: Int?
        let kind: Kind
    }

    /// The day's sittings, its stray completions and its events, in the order the day went: a sitting
    /// with no time first, as the list has it ("Earlier"), and an all-day event with them. An event that
    /// began the day before is on the rail from midnight. A sitting and an event at the same minute: the
    /// event first, since it was on the calendar before the sitting began.
    static func railEntries(_ list: SittingList, events: [ProjectEvent] = [], day: String? = nil,
                            calendar: Calendar = .current) -> [RailEntry] {
        var entries = day.map { day in
            events.on(day, calendar: calendar).map {
                RailEntry(id: "event/\($0.id)", minute: $0.startMinute(on: day, calendar: calendar), kind: .event($0))
            }
        } ?? []
        entries += list.sittings.map {
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

// MARK: - How much a calendar says

/// How much a week's block or a month's day says, from the room it has — a card made larger shows more,
/// rather than the same few words in bigger boxes — and from how large its type is on screen: zoomed out
/// far enough that the small print is a grey texture, it gives way to colour, which still reads.
///
/// Sizes here are the card's own units, before its zoom: what fits at 1×.
enum CanvasCalendarDetail {
    /// Whether a calendar's smallest type, 9.5pt at 1×, is at least 7pt on screen. Below it a day is its
    /// colours. `CanvasDetail.simplifiedBelow` is further out still, where the card is one label.
    static func finePrintReadable(zoom: Double, scale: Double) -> Bool { 9.5 * zoom * scale >= 7 }

    /// How a month's day on a Day card draws its sittings.
    enum MonthCell: Equatable {
        /// A dot each, in its project's colour.
        case dots
        /// A line each — its project — the last saying how many more when they don't all fit.
        case names(shown: Int)
        /// Two lines each: its project, then what it was about.
        case ledes
    }

    /// A line each when there's width for a name and lines for more than a count; two lines each when
    /// every sitting has room for its lede.
    static func monthCell(sittings count: Int, width: CGFloat, lines: Int, readable: Bool) -> MonthCell {
        guard readable, count > 0, width >= 64, lines >= 1 else { return .dots }
        if width >= 100, count * 2 <= lines { return .ledes }
        if count <= lines { return .names(shown: count) }
        // The last line is "+N more"; one line is no room for a name and a count.
        return lines >= 2 ? .names(shown: lines - 1) : .dots
    }

    /// What a week's block has room for beyond its project: lines of lede, whether it says what came of
    /// the sitting ("3 done · 1 dropped"), and how many of the tasks it finished are listed.
    struct Block: Equatable {
        var time = true
        /// Whether the duration fits beside the time it began (docs/time-tracking.md D6). The narrow
        /// columns say only when: the time is what places the block on the grid, and the duration is
        /// the first thing to go when there's no room for both.
        var duration = false
        var lede = 0
        var counts = false
        var tasks = 0
    }

    /// `lines` is how many lines of 12.5pt fit below the project's name. The first goes to the lede, as
    /// it always has; then what came of it, then the tasks it finished, and what's left lengthens the
    /// lede to three. A column too narrow for words — or type too small to read — is a block of colour
    /// and a name.
    static func weekBlock(lines: Int, width: CGFloat, finished: Int, readable: Bool) -> Block {
        guard readable, width >= 64 else { return Block(time: false) }
        var block = Block()
        // "9:10 AM · 2h 10m" needs about twice the room "9:10 AM" does.
        block.duration = width >= 120
        var left = max(0, lines)
        guard left > 0 else { return block }
        block.lede = 1
        left -= 1
        if left > 0, finished > 0 || lines > 1 { block.counts = true; left -= 1 }
        block.tasks = min(finished, left)
        left -= block.tasks
        block.lede += min(2, left)
        return block
    }

    /// How a Coming up week's column draws its rows.
    enum Column: Equatable {
        /// A size down, with the project's mark.
        case compact
        /// Full size, with the mark.
        case regular
        /// Full size, with the project's name after its mark, as the list has it.
        case named
    }

    static func column(width: CGFloat) -> Column {
        width >= 240 ? .named : width >= 150 ? .regular : .compact
    }

    /// How tall an hour is in a week's grid: at least `minimum`, and more when the card has height
    /// to spare, so the working day fills it rather than stopping halfway down.
    static func perHour(available: CGFloat, hours: Int, minimum: CGFloat) -> CGFloat {
        guard hours > 0 else { return minimum }
        return max(minimum, (available / CGFloat(hours)).rounded(.down))
    }
}
