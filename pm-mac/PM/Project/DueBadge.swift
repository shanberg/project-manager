import SwiftUI
import PmLib

/// When a task is due, drawn.
///
/// Its own file because two surfaces draw it now: the task row in the project window, where it is a
/// menu you click to change the date, and a task on a canvas card, where it is a badge and nothing
/// more. The severity scale — what counts as overdue, what a soon date looks like, whose date a dashed
/// border means — is the part that must not differ between them, so it lives in one place and both read
/// it. A canvas that disagreed with the window about which deadlines are red would be worse than a
/// canvas with no dates on it.
enum DueBadge {
    /// The badge itself, at the size and weight its state calls for.
    static func chip(_ text: String, style: DueChipStyle) -> some View {
        Text(text)
            .font(.caption2.weight(style.weight))
            // A relative badge rewrites itself as the days tick down, and "in 2d" → "in 3d" shouldn't
            // shift the row's layout to do it.
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style.stroke,
                                  style: StrokeStyle(lineWidth: 1, dash: style.dashed ? [3] : []))
            )
            .foregroundStyle(style.text)
    }

    /// The read-only form: a task's date as it stands, or nothing at all.
    ///
    /// No "＋date" affordance and no menu — a card is a clipping, and an empty control offering to set
    /// something the card cannot set is worse than a quiet row. A task with no date simply has no badge.
    @ViewBuilder static func reading(_ todo: Todo) -> some View {
        if let shown = todo.dueDate.map({ (raw: $0, own: true) })
            ?? todo.effectiveDueDate.map({ (raw: $0, own: false) }) {
            chip(RelativeDue.short(shown.raw),
                 style: DueChipStyle(due: shown.raw, own: shown.own, done: todo.checked))
                .help("Due " + RelativeDue.full(shown.raw))
        }
    }
}

struct DueChipStyle {
    var text: Color
    var stroke: Color
    var fill: Color
    var weight: Font.Weight
    var dashed: Bool

    init(due: String, own: Bool, done: Bool) {
        // A completed task's date is a record rather than a deadline, so it reads at the quietest step
        // of the scale — no tint, no fill, no extra weight — while keeping the dashed border that says
        // whose date it is.
        let state: DueState = done ? .later : DueState(due: due, own: own)
        let tint: Color
        switch state {
        case .overdue: tint = Color(nsColor: .systemRed)
        case .soon: tint = Color(nsColor: .systemOrange)
        case .later, .inherited: tint = .secondary
        }
        text = tint
        stroke = tint
        dashed = !own
        if own, state == .overdue {
            fill = tint.opacity(0.16)
            weight = .semibold
        } else if own, state == .soon {
            fill = tint.opacity(0.10)
            weight = .medium
        } else {
            fill = .clear
            weight = .regular
        }
    }

    private init(text: Color, stroke: Color, fill: Color, weight: Font.Weight, dashed: Bool) {
        self.text = text; self.stroke = stroke; self.fill = fill
        self.weight = weight; self.dashed = dashed
    }

    /// The "＋date" affordance on a task with no date at all — a control, so it stays quiet.
    static let empty = DueChipStyle(text: .secondary, stroke: .secondary, fill: .clear,
                                    weight: .regular, dashed: true)
}

