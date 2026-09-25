import Foundation
import PmLib

/// What a project card draws of the project it is showing.
///
/// **A board is the one surface that shows several projects at once, and it was showing all of each of
/// them.** A project card rendered the whole notes document — the brief, every session, every task —
/// so six projects on a board was six of everything, when what you wanted from five of them was the
/// current state and the open work.
///
/// The setting exists for a second reason that turned out to matter more: it is what makes two
/// workspaces different. "The project and Jira" beside "its tasks and Figma" are two cards on the same
/// project, and without this they are the same card twice. `StoreRegistry` refcounts, so both hold one
/// store and stay in step with each other and with the window.
///
/// **Four cards, not five flags.** This was five independent switches — brief, notes, tasks, completed,
/// latest-only — and the arithmetic on that is unkind: three parts give seven legal combinations, times
/// two filters that only sometimes apply, is twenty-one distinct renderings reachable from a six-item
/// menu. Two of those items did nothing at all on some cards; most of the twenty-one were reachable
/// only by accident. What people actually build with a card is a much shorter list, and it is this one.
///
/// The presets are not a smaller menu over the same switches — they answer *different questions*, and
/// the pair in the middle is the point:
///
/// - `current` is **time**-scoped. "What happened last time I sat down, and everything still open."
/// - `tasks` is **state**-scoped. "Everything still open, whenever I wrote it."
///
/// `current` is the six-projects-on-a-board card: the latest sitting's prose, and the open work from
/// every sitting, because a task left behind three sessions ago is exactly the one you have forgotten.
///
/// **What a card shows is not what a card can do.** A card set to tasks can still start a session,
/// write its note, and edit the brief — the brief simply appears while you are editing it and goes back
/// to being hidden when you leave. This is a lens on one document, not a smaller version of the
/// surface: a tasks-only card in the workspace you work through tasks in is exactly where you most need
/// to be able to write down what you did.
///
/// **Kept on the node, in the file**, which is the bargain `CanvasCardZoom`, `CanvasCardSession` and
/// `CanvasCardMedia` all made before it, in the same words: this is something you *set*, and a card
/// that forgot it every time the window closed would be worse than not offering the choice. It is a
/// fact about a card rather than about a machine, it is one word rather than anything private, and a
/// board opened in Obsidian carrying it is a feature.
enum CanvasCardShows: String, CaseIterable, Equatable {
    /// The whole document — brief, every session, every task, finished ones included. What every
    /// project card drew before any of this existed, and what a new one still draws.
    case everything
    /// Where this is now: the latest sitting's prose, and the open tasks from every sitting.
    case current
    /// What is left, whenever it was written. No brief, no prose, nothing ticked.
    case tasks
    /// The reference card: the brief alone, parked beside something else, changing only when the
    /// project's shape does.
    case brief
    /// One sitting, named by `pmSitting` — last week's 1:1 pinned beside this week's (docs/views.md D7).
    /// Made by dragging a sitting off a view rather than chosen from the menu, since it needs a sitting
    /// to name. A card whose sitting can't be found draws the project, as a typo in `pmShows` does.
    case sitting

    /// The menu's line under a title that can't say it alone: Current and Tasks read alike.
    var menuSubtitle: String? {
        switch self {
        case .current: return "Latest session\u{2019}s note, then all open tasks"
        case .tasks: return "All open tasks, no notes"
        default: return nil
        }
    }

    /// What the Shows menu offers: the four you can choose without naming a sitting.
    static let menuCases: [CanvasCardShows] = [.everything, .current, .tasks, .brief]

    /// What the menu calls it. Here rather than in the menu, so the word a card is set by and the word
    /// written into the file cannot drift apart.
    var title: String {
        switch self {
        case .everything: return "Everything"
        case .current: return "Current"
        case .tasks: return "Tasks"
        case .brief: return "Brief"
        case .sitting: return "One Sitting"
        }
    }

    /// A card nobody has narrowed.
    static let `default` = CanvasCardShows.everything

    // MARK: What that means to draw

    /// How much of the session prose a card draws.
    ///
    /// `latest` is the whole reason this is a scope rather than a flag: it narrows the *prose* without
    /// narrowing the tasks, which the old `latestOnly` could not do — it truncated the session list, so
    /// hiding the older sittings' words also hid the work they left open.
    enum ProseScope { case none, latest, all }

    /// Which tasks a card draws. Not a scope over sessions: every sitting's tasks are drawn under their
    /// own caption, and this says only whether the finished ones come with them.
    enum TaskScope { case none, open, all }

    /// Whether the summary, problem, goals, approach, links and learnings are drawn.
    var brief: Bool {
        switch self {
        case .everything, .brief: return true
        case .current, .tasks, .sitting: return false
        }
    }

    var prose: ProseScope {
        switch self {
        case .everything, .sitting: return .all
        case .current: return .latest
        case .tasks, .brief: return .none
        }
    }

    var tasks: TaskScope {
        switch self {
        case .everything, .sitting: return .all
        case .current, .tasks: return .open
        case .brief: return .none
        }
    }

    /// How the sittings are laid out.
    ///
    /// `sittings` is each sitting under its own caption, the tasks it picked up drawn after its own.
    /// `pile` is docs/sessions.md D5's *today and the pile*: the latest sitting drawn whole (when
    /// `withLatest`), then every other open task in one **Still open** group, each carrying the chip
    /// that says where it came from. One caption in place of a dozen, which is what a card that exists
    /// to say "where is this now" was drowning in.
    enum Layout: Equatable { case sittings, pile(withLatest: Bool) }

    var layout: Layout {
        switch self {
        case .everything, .brief, .sitting: return .sittings
        case .current: return .pile(withLatest: true)
        case .tasks: return .pile(withLatest: false)
        }
    }

    /// Whether this card draws the prose of the sitting at `index`, where 0 is the most recent —
    /// `addSession` inserts at the front, so the newest sitting is the first one.
    func showsProse(ofSessionAt index: Int) -> Bool {
        switch prose {
        case .none: return false
        case .latest: return index == 0
        case .all: return true
        }
    }

    /// Whether this card draws `checked`.
    func showsTask(checked: Bool) -> Bool {
        switch tasks {
        case .none: return false
        case .open: return !checked
        case .all: return true
        }
    }

    // MARK: On the node

    /// The key PM writes. Prefixed, because a `.canvas` is a shared document.
    static let key = "pmShows"

    /// What this card shows, as the file says — or everything, which is both the default and what a
    /// value PM cannot make sense of falls back to.
    ///
    /// The fallback is deliberate and it is not "trust the file": a `.canvas` is hand-editable and
    /// syncs between machines, so `pmShows: "currnet"` is a typo somebody will make, and the honest
    /// recovery from "this names nothing" is to show the project rather than a blank rectangle nobody
    /// can work out how to fix.
    static func of(_ node: CanvasNode) -> CanvasCardShows {
        guard case .string(let raw)? = node.extra[key] else { return .default }
        return parse(raw)
    }

    static func parse(_ raw: String) -> CanvasCardShows {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let preset = CanvasCardShows(rawValue: trimmed) { return preset }
        return nearest(toLegacy: trimmed)
    }

    /// A card written by the five-flag version of this setting, snapped to the preset that answers the
    /// nearest question.
    ///
    /// **Cards in the wild outlive the code that wrote them.** A `.canvas` is a file on somebody's
    /// disk and in somebody's sync folder, and one narrowed a year ago should keep meaning roughly what
    /// it meant rather than silently springing back to the whole document — so the old comma-separated
    /// token lists are still read, just no longer written.
    ///
    /// The order of these tests is the mapping: anything scoped to the latest sitting was asking "where
    /// is this now", whatever else it said, and that is `current`. `brief` and `tasks` are the two
    /// single-part cards. Everything else — including the brief-plus-tasks card, which has no preset —
    /// widens to the whole project, on the same principle as the typo above: showing more than you
    /// asked for is recoverable in one click, and showing less looks like the card is broken.
    private static func nearest(toLegacy raw: String) -> CanvasCardShows {
        let tokens = Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !tokens.isEmpty else { return .default }
        if tokens.contains("latest") { return .current }
        let hasBrief = tokens.contains("brief")
        let hasNotes = tokens.contains("notes")
        let hasTasks = tokens.contains("tasks")
        if hasBrief, !hasNotes, !hasTasks { return .brief }
        if hasTasks, !hasBrief, !hasNotes { return .tasks }
        return .default
    }

    /// Put this on a card — as the absence of the key when it is showing everything, so a card narrowed
    /// and widened again leaves the file exactly as it found it.
    ///
    /// Any lens but `sitting` takes `pmSitting` off with it: a card set back to Current has stopped
    /// being about that sitting, and a stale key would come back to life if somebody typed `sitting`.
    static func set(_ shows: CanvasCardShows, on node: inout CanvasNode) {
        node.extra[key] = shows == .default ? nil : .string(shows.rawValue)
        if shows != .sitting { node.extra[CanvasSittingPin.key] = nil }
    }
}

/// The sitting a `sitting` card draws, as the node keeps it: `pmSitting`, a `SessionRef` spelled as
/// the contract spells one — `{"date": "2026-09-17", "ordinal": 0, "digest": "…"}`.
///
/// Not `pmSession`, which already names a web card's browser session (`CanvasCardSession`).
enum CanvasSittingPin {
    static let key = "pmSitting"

    static func of(_ node: CanvasNode) -> SessionRef? {
        guard case .object(let object)? = node.extra[key],
              case .string(let date)? = object["date"] else { return nil }
        var ordinal = 0
        if case .number(let n)? = object["ordinal"] { ordinal = max(0, Int(n)) }
        var digest: String?
        if case .string(let d)? = object["digest"], !d.isEmpty { digest = d }
        return SessionRef(date: date, ordinal: ordinal, digest: digest)
    }

    /// Make `node` a card of this one sitting.
    static func pin(_ ref: SessionRef, on node: inout CanvasNode) {
        guard let date = ref.date else { return }
        var object: [String: JSONValue] = ["date": .string(date), "ordinal": .number(Double(ref.ordinal))]
        if let digest = ref.digest { object["digest"] = .string(digest) }
        node.extra[key] = .object(object)
        CanvasCardShows.set(.sitting, on: &node)
    }

    /// A project card for the project `sitting` is in, pinned to it — what a sitting dragged off a view
    /// becomes (D7). Stored as every project card is, from the vault root; nil when the project's notes
    /// can't be found.
    @MainActor
    static func card(for sitting: SittingEntry, resolver: CanvasFileResolver) -> CanvasDocument? {
        card(project: sitting.projectFolder,
             session: SessionRef(date: sitting.session, ordinal: sitting.sessionOrdinal,
                                 digest: sitting.sessionDigest.isEmpty ? nil : sitting.sessionDigest),
             resolver: resolver)
    }

    /// The same, for a sitting named by its project's folder and its ref — a Leftovers heading's. With no
    /// sitting, the project's card as it comes: a Projects row dragged off.
    @MainActor
    static func card(project folder: String, session: SessionRef?, resolver: CanvasFileResolver) -> CanvasDocument? {
        guard let projectPath = try? resolveProjectPath(nameOrPrefix: folder),
              let notes = (try? resolveNotesPath(projectPath: projectPath)) ?? nil else { return nil }
        var node = CanvasProjectNoteCard.node(for: URL(fileURLWithPath: notes), at: CanvasPoint(x: 0, y: 0),
                                              resolver: resolver)
        if let session { pin(session, on: &node) }
        return CanvasDocument(nodes: [node], edges: [])
    }

    /// Which session in `notes` the pin names, or nil when none does.
    ///
    /// By its label first, which finds it among a day's sittings even if they've been reordered; then
    /// by date and position alone, so renaming a sitting doesn't turn its card into the whole project.
    static func index(of ref: SessionRef, in notes: ProjectNotes) -> Int? {
        if let hit = try? resolveSessionRef(ref, notes: notes) { return hit.index }
        var loose = ref
        loose.digest = nil
        return (try? resolveSessionRef(loose, notes: notes))?.index
    }
}
