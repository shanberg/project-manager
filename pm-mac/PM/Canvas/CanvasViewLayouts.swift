import AppKit
import PmLib
import SwiftUI

// MARK: - On screen

/// What a view card draws that depends on the board's zoom rather than its own: whether its small print
/// is large enough on screen to read (`CanvasCalendarDetail.finePrintReadable`). Set by the node view as
/// the board zooms — only when it changes, so a zoom's flight redraws a card once, at the crossing.
@Observable final class CanvasOnScreen {
    var finePrintReadable = true
}

// MARK: - The rail

/// One day down a time gutter (docs/views.md D9): each block placed at least as far below the one before
/// as the time between them says, so the shape of the day shows — a morning of sittings back to back, an
/// afternoon of empty rail. Blocks are measured, not sized by time: a block's height says what it holds.
/// (How long a sitting ran is knowable — docs/time-tracking.md — and still doesn't size anything here.)
/// See `CanvasTimeGrid.railTops`.
struct CanvasRailLayout: Layout {
    /// How far a minute between two starts carries the second one down.
    var perMinute: CGFloat
    var gap: CGFloat

    /// When the block began, in minutes past midnight; nil follows the block before.
    struct Minute: LayoutValueKey { static let defaultValue: Int? = nil }

    private func measure(_ width: CGFloat, _ subviews: Subviews) -> (tops: [CGFloat], heights: [CGFloat]) {
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let tops = CanvasTimeGrid.railTops(heights: heights, minutes: subviews.map { $0[Minute.self] },
                                           perMinute: perMinute, gap: gap)
        return (tops, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let (tops, heights) = measure(width, subviews)
        return CGSize(width: width, height: (tops.last ?? 0) + (heights.last ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (tops, _) = measure(bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + tops[index]), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

// MARK: - A Day's week

/// Seven columns, each sitting a block at the time it began (D9): the week as a calendar draws one, so
/// a Tuesday of meetings and a Thursday of one long sitting look like what they were. A sitting with no
/// time sits in a strip above the grid. A block is its project and what the sitting was about; clicking
/// goes to the project, dragging makes a card of the sitting (D7), and a day's heading opens that day as
/// a Day card.
///
/// **The card's size is room to say more.** The hours stretch to fill the card's height, and a block
/// takes what it needs of the room before the next one begins — more of its lede, what came of it, the
/// tasks it finished — without ever running into it. The height it's drawn is what it says, not how
/// long the sitting ran, which no heading records (D5). See `CanvasCalendarDetail.weekBlock`.
struct CanvasDayWeek: View {
    let span: CanvasCalendarSpan
    let list: SittingList
    var zoom: Double = 1
    var onScreen = CanvasOnScreen()
    var today: String = CanvasTaskLists.todayISO()
    var onOpenProject: (String) -> Void = { _ in }
    var onOpenDay: ((String) -> Void)?
    var sittingCard: ((SittingEntry) -> NSItemProvider?)?

    private var gutter: CGFloat { 40 * zoom }
    private var blockHeight: CGFloat { 44 * zoom }
    private var lineHeight: CGFloat { 12.5 * zoom }

    var body: some View {
        let timed = list.sittings.compactMap { CanvasTimeGrid.minutes(of: $0.startTime) }
        let hours = CanvasTimeGrid.hours(for: timed)
        let untimed = span.days.map { day in list.sittings.filter { $0.session == day && CanvasTimeGrid.minutes(of: $0.startTime) == nil } }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(span.days, id: \.self) { day in dayHeading(day).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 4)
            Divider()
            GeometryReader { geometry in
                let strip = untimed.contains(where: { !$0.isEmpty }) ? blockHeight + 7 : 0
                let perHour = CanvasCalendarDetail.perHour(available: geometry.size.height - strip - 16,
                                                           hours: hours.count - 1, minimum: 46 * zoom)
                let columnWidth = (geometry.size.width - gutter) / CGFloat(max(1, span.days.count)) - 4
                let columns = span.days.map { day in column(day, firstHour: hours.lowerBound, perHour: perHour) }
                let gridHeight = max(CGFloat(hours.count - 1) * perHour,
                                     columns.map { ($0.last?.top ?? 0) + blockHeight }.max() ?? 0)
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if strip > 0 {
                            HStack(alignment: .top, spacing: 0) {
                                Text("Earlier")
                                    .font(.system(size: 9.5 * zoom))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: gutter - 4, alignment: .trailing)
                                    .padding(.trailing, 4)
                                ForEach(Array(span.days.enumerated()), id: \.offset) { index, _ in
                                    VStack(spacing: 2) {
                                        ForEach(untimed[index], id: \.id) {
                                            block($0, room: blockHeight, width: columnWidth).frame(height: blockHeight)
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                    .frame(maxWidth: .infinity, alignment: .top)
                                }
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                        HStack(alignment: .top, spacing: 0) {
                            hourLabels(hours, perHour: perHour).frame(width: gutter, height: gridHeight, alignment: .topTrailing)
                            ForEach(Array(span.days.enumerated()), id: \.offset) { index, _ in
                                let placed = columns[index]
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array(placed.enumerated()), id: \.element.sitting.id) { at, block in
                                        // Up to where the next one begins, or the grid's foot.
                                        let next = at + 1 < placed.count ? placed[at + 1].top : gridHeight
                                        self.block(block.sitting, room: next - block.top - 2, width: columnWidth)
                                            .offset(y: block.top)
                                    }
                                }
                                .padding(.horizontal, 2)
                                .frame(maxWidth: .infinity, minHeight: gridHeight, maxHeight: gridHeight, alignment: .topLeading)
                                .background(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
                            }
                        }
                        .background(alignment: .topLeading) { hourLines(hours, perHour: perHour) }
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    /// A day's timed sittings in order, each where it lands.
    private func column(_ day: String, firstHour: Int, perHour: CGFloat) -> [(sitting: SittingEntry, top: CGFloat)] {
        let sittings = list.sittings
            .compactMap { sitting in CanvasTimeGrid.minutes(of: sitting.startTime).map { (sitting, $0) } }
            .filter { $0.0.session == day }
            .sorted { $0.1 < $1.1 }
        let tops = CanvasTimeGrid.columnTops(minutes: sittings.map(\.1), firstHour: firstHour,
                                             perHour: perHour, blockHeight: blockHeight)
        return zip(sittings, tops).map { ($0.0, $1) }
    }

    @ViewBuilder private func dayHeading(_ day: String) -> some View {
        let isToday = day == today
        let label = VStack(spacing: 0) {
            Text(CanvasCalendarCells.weekday(day))
                .font(.system(size: 9.5 * zoom))
                .foregroundStyle(.secondary)
            Text(CanvasCalendarCells.dayNumber(day))
                .font(.system(size: 13 * zoom, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        if let onOpenDay {
            Button { onOpenDay(day) } label: { label }
                .buttonStyle(.plain)
                .help("Open \(CanvasDayCard.dayCaption(day)) as a Day card")
        } else {
            label
        }
    }

    private func hourLabels(_ hours: ClosedRange<Int>, perHour: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(hours), id: \.self) { hour in
                Text(CanvasCalendarCells.hour(hour))
                    .font(.system(size: 9 * zoom).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
                    .offset(y: CGFloat(hour - hours.lowerBound) * perHour - 5 * zoom)
            }
        }
    }

    private func hourLines(_ hours: ClosedRange<Int>, perHour: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(hours), id: \.self) { hour in
                Rectangle().fill(.quaternary).frame(height: 0.5)
                    .offset(y: CGFloat(hour - hours.lowerBound) * perHour)
            }
        }
        .padding(.leading, gutter)
    }

    /// A sitting's block, saying as much as `room` — its height to the next block, on screen — has
    /// lines for, and never less than the time, the project and a line of what it was about.
    private func block(_ sitting: SittingEntry, room: CGFloat, width: CGFloat) -> some View {
        let tint = CanvasCalendarCells.tint(sitting.projectColor)
        let lede = sittingLede(name: sitting.name, prose: sitting.prose)
        let finished = sitting.finished.filter { $0.depth == 0 }
        let extra = max(0, Int((room - blockHeight) / lineHeight))
        let says = CanvasCalendarDetail.weekBlock(lines: 1 + extra, width: width / zoom, finished: finished.count,
                                                  readable: onScreen.finePrintReadable)
        let counts = CanvasDayRows.counts(sitting)
        return Button { onOpenProject(sitting.projectFolder) } label: {
            VStack(alignment: .leading, spacing: 0) {
                // In the strip above the grid, the gutter already says "Earlier".
                if says.time, let time = sitting.startTime {
                    // How long it ran after when it began, on one line — the week has no gutter to put
                    // it under the way the list does (docs/time-tracking.md D6).
                    Text(says.duration ? sitting.seconds.map { "\(time) · \(durationLabel($0))" } ?? time : time)
                        .font(.system(size: 9 * zoom).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(sitting.projectName)
                    .font(.system(size: 10.5 * zoom, weight: .semibold))
                    .lineLimit(1)
                if says.lede > 0, !lede.isEmpty {
                    Text(lede)
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.secondary)
                        .lineLimit(says.lede)
                }
                if says.counts, !counts.isEmpty {
                    Text(counts)
                        .font(.system(size: 9 * zoom))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
                ForEach(Array(finished.prefix(says.tasks).enumerated()), id: \.offset) { _, task in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5 * zoom, weight: .bold))
                            .foregroundStyle(tint)
                        Text(task.text)
                            .font(.system(size: 9.5 * zoom))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 5 * zoom)
            .padding(.trailing, 3)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: blockHeight, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(tint.opacity(0.14))
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2 * zoom) }
            .overlay {
                if sitting.isCurrent {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CanvasCalendarCells.help(sitting))
        .ifCondition(sittingCard != nil) { view in view.onDrag { sittingCard?(sitting) ?? NSItemProvider() } }
    }
}

// MARK: - A month

/// The room in a month's day under its number, in the card's units before its zoom — what fits at 1×.
struct CanvasMonthRoom: Equatable {
    /// Lines of 13pt.
    var lines: Int
    var width: CGFloat
}

/// A grid of days, whole weeks (D9): each day's number, and what `cell` draws in it. Quiet days — the
/// ones either side of the month, or already past on Coming up — are drawn fainter. The cells share the
/// card's height between them, down to a floor where the grid scrolls instead.
struct CanvasMonthGrid<Cell: View>: View {
    let span: CanvasCalendarSpan
    var zoom: Double = 1
    var today: String = CanvasTaskLists.todayISO()
    /// Whether a day is drawn fainter.
    var isQuiet: (String) -> Bool = { _ in false }
    /// Opens a day as a Day card, when clicking one does.
    var onOpenDay: ((String) -> Void)?
    /// What a day holds, given the room under its number.
    @ViewBuilder var cell: (_ day: String, _ room: CanvasMonthRoom) -> Cell

    var body: some View {
        let rows = max(1, span.days.count / 7)
        GeometryReader { geometry in
            let header = 18 * zoom
            let height = max(52 * zoom, (geometry.size.height - header) / CGFloat(rows))
            let room = CanvasMonthRoom(lines: max(0, Int((height - 20 * zoom) / (13 * zoom))),
                            width: (geometry.size.width / 7 - 8 * zoom) / zoom)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(span.days.prefix(7), id: \.self) { day in
                            Text(CanvasCalendarCells.weekday(day))
                                .font(.system(size: 9.5 * zoom))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: header)
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(span.days[(row * 7)..<min(span.days.count, row * 7 + 7)], id: \.self) { day in
                                dayCell(day, height: height, room: room)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: String, height: CGFloat, room: CanvasMonthRoom) -> some View {
        let isToday = day == today
        let face = VStack(alignment: .leading, spacing: 2) {
            Text(CanvasCalendarCells.dayNumber(day))
                .font(.system(size: 10.5 * zoom, weight: isToday ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : .secondary)
                .padding(.horizontal, isToday ? 4 : 0)
                .background { if isToday { Capsule().fill(Color.accentColor) } }
            cell(day, room)
        }
        .padding(4 * zoom)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .opacity(isQuiet(day) ? 0.4 : 1)
        .overlay { Rectangle().strokeBorder(.quaternary, lineWidth: 0.5) }
        .contentShape(Rectangle())
        if let onOpenDay {
            Button { onOpenDay(day) } label: { face }
                .buttonStyle(.plain)
                .help("Open \(CanvasDayCard.dayCaption(day)) as a Day card")
        } else {
            face
        }
    }
}

/// A month's day on a Day card, saying as much as its room has lines for (D9): a line per sitting —
/// its project, and when the cell is wide enough, its time — and with room to spare, what each was
/// about beneath it. Cramped, or too small on screen to read, it's a dot per sitting in its project's
/// colour, in the order the day went: the shape of a month of work at a glance, which is the journal's
/// calendar. See `CanvasCalendarDetail.monthCell`.
struct CanvasDayMonthCell: View {
    let sittings: [SittingEntry]
    var room = CanvasMonthRoom(lines: 0, width: 0)
    var zoom: Double = 1
    var readable = true

    var body: some View {
        let detail = CanvasCalendarDetail.monthCell(sittings: sittings.count, width: room.width, lines: room.lines,
                                                    readable: readable)
        Group {
            switch detail {
            case .dots:
                CanvasDotsCell(colors: sittings.map(\.projectColor), zoom: zoom, large: !readable)
            case .names(let shown):
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sittings.prefix(shown), id: \.id) { line($0, lede: false) }
                    if sittings.count > shown {
                        Text("+\(sittings.count - shown) more")
                            .font(.system(size: 9 * zoom))
                            .foregroundStyle(.secondary)
                    }
                }
            case .ledes:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sittings, id: \.id) { line($0, lede: true) }
                }
            }
        }
        .help(sittings.map(CanvasCalendarCells.help).joined(separator: "\n"))
    }

    /// A sitting's line: a bar in its project's colour, then its project, and the time where the cell is
    /// wide enough for both.
    private func line(_ sitting: SittingEntry, lede: Bool) -> some View {
        let tint = CanvasCalendarCells.tint(sitting.projectColor)
        let about = sittingLede(name: sitting.name, prose: sitting.prose)
        return HStack(alignment: .top, spacing: 3 * zoom) {
            RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2.5 * zoom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if room.width >= 130, let time = sitting.startTime {
                        Text(time)
                            .font(.system(size: 9 * zoom).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(sitting.projectName)
                        .font(.system(size: 9.5 * zoom, weight: .medium))
                        .lineLimit(1)
                }
                if lede, !about.isEmpty {
                    Text(about)
                        .font(.system(size: 9 * zoom))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A dot per thing in a day, in its project's colour, in rows of six so a busy day wraps rather than
/// running out of its cell — what a month's day is when it has no room for words.
struct CanvasDotsCell: View {
    let colors: [String?]
    var zoom: Double = 1
    /// Drawn larger, for a board zoomed out past reading, where a 7pt dot is a speck.
    var large = false

    var body: some View {
        let shown = Array(colors.prefix(12))
        let size = (large ? 12 : 7) * zoom
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(stride(from: 0, to: shown.count, by: 6)), id: \.self) { start in
                HStack(spacing: 3 * zoom) {
                    ForEach(start..<min(shown.count, start + 6), id: \.self) { index in
                        Circle()
                            .fill(CanvasCalendarCells.tint(shown[index]))
                            .frame(width: size, height: size)
                    }
                }
            }
            if colors.count > shown.count {
                Text("+\(colors.count - shown.count)")
                    .font(.system(size: 9 * zoom))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Pieces

enum CanvasCalendarCells {
    /// A project's `pm-color`, or a quiet grey for one without.
    static func tint(_ color: String?) -> Color {
        color.flatMap(ProjectColor.init(value:)).map { Color(nsColor: $0.nsColor) } ?? Color.secondary.opacity(0.6)
    }

    /// What a sitting says on hover: when, where, what about.
    static func help(_ sitting: SittingEntry) -> String {
        var parts = [sitting.startTime ?? "Earlier", sitting.projectName]
        let lede = sittingLede(name: sitting.name, prose: sitting.prose)
        if !lede.isEmpty { parts.append(lede) }
        let counts = CanvasDayRows.counts(sitting)
        return parts.joined(separator: " · ") + (counts.isEmpty ? "" : " (\(counts))")
    }

    static func weekday(_ iso: String) -> String { formatted(iso, "EEE") }
    static func dayNumber(_ iso: String) -> String { formatted(iso, "d") }

    /// "9 AM", "12 PM".
    static func hour(_ hour: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(hour < 12 || hour == 24 ? "AM" : "PM")"
    }

    private static func formatted(_ iso: String, _ pattern: String) -> String {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "yyyy-MM-dd"
        guard let date = reader.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
