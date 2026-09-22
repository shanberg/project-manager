import Foundation

/// Which question a view card answers (docs/views.md D1) — the closed set, and what each one is called.
///
/// **In PmLib so that the vocabulary has one home.** The card's settings — its period, its projects,
/// its layout — are the app's business and stay in `CanvasViewSpec`. The *kind* is not: a view is a
/// text node carrying `pmView`, and anything that reads a board has to be able to say that a node is
/// a Day rather than a text card beginning "Today, across projects". `card.list` runs with no app at
/// all, and it names a Today card a Day, with a calendar beside it, exactly as a tile's tab does.
public enum CanvasViewKind: String, CaseIterable, Equatable, Sendable {
    /// What did I sit down to? `session.list`.
    case day
    /// What am I blocked on? `task.waiting` — the Waiting window's answer, on a board.
    case waiting
    /// Where did I say *that*? `task.search`, for the words in `query`.
    case search
    /// What have I left open, and where did I write it? `task.leftovers`, from sittings before the
    /// period (D2: Leftovers reads *when* as "older than").
    case leftovers
    /// What's due, and when? `task.due`: overdue, then the days up to the period's end.
    case comingUp = "coming-up"
    /// Which projects are moving, and which have gone quiet? `project.list` with its activity.
    case projects
    /// Where did the time go? `time.spent` — how long each project had your attention, and what came
    /// of it (docs/time-tracking.md D7).
    case time

    /// What the card is called where it has to be one word: zoomed out, and to VoiceOver. A card that
    /// can say more — a Day pinned to a date, a Search with words in it — says it in
    /// `CanvasViewSpec.cardName`, which starts here.
    public var title: String {
        switch self {
        case .day: return "Day"
        case .waiting: return "Waiting"
        case .search: return "Search"
        case .leftovers: return "Leftovers"
        case .comingUp: return "Coming Up"
        case .projects: return "Projects"
        case .time: return "Time"
        }
    }

    /// The SF Symbol that stands for the card wherever it is one line — see `title`.
    public var symbol: String {
        switch self {
        case .day: return "calendar"
        case .waiting: return "clock"
        case .search: return "magnifyingglass"
        case .leftovers: return "tray.full"
        case .comingUp: return "calendar.badge.clock"
        case .projects: return "square.grid.2x2"
        // Not "clock", which Waiting has: an hourglass is time *spent*, where a clock is a time to come.
        case .time: return "hourglass"
        }
    }

    /// The key a view node carries. See `CanvasViewSpec` for the rest of them.
    public static let nodeKey = "pmView"

    /// The kind of view this node is, or nil for a node that isn't one — anything but a text node, a
    /// text node without the key, or one naming a view this build doesn't have.
    ///
    /// **Forgiving on purpose** (views.md D3): an unknown `pmView` is not a view, and whatever reads
    /// it falls back to drawing the text card it also is.
    public static func of(_ node: CanvasNode) -> CanvasViewKind? {
        guard case .text = node.content, case .string(let raw)? = node.extra[nodeKey] else { return nil }
        return CanvasViewKind(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
